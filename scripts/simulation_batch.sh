#!/usr/bin/env bash
source ${SLURM_SIMULATION_TOOLKIT_HOME}/config/simulation_toolkit.rc
source ${SLURM_SIMULATION_TOOLKIT_JOB_RC_PATH} # time, nodes, cpus, gpus, memory to request by cluster

#######################################################################################################################
########################################### HELPER VARIABLES AND FUNCTIONS ############################################
#######################################################################################################################
simulation_executable="simulation.sh"

function showHelp {

echo "NAME
  $me -
     1) Launches the same job in parallel many times. (Randomization is done by the base script.)
     2) Wraps simulation.sh script

SYNOPSIS
  $me [OPTIONS] [-- OPTIONS_FOR_BASE_SCRIPT]

OPTIONS
  -h, --help
                          Show this description
  --account ACCOUNT
                          ACCOUNT is the slurm account to use for every job (def-yymao or rrg-yymao).
                          Default is rrg-mao on Cedar, def-yymao otherwise.

  --base_script BASE_SCRIPT
                          BASE_SCRIPT is the is the path to base script that the user wishes to execute on a SLURM
                          compute node.

  --blocking_job_manifest MANIFEST
                          MANIFEST is a file containing a list of IDs of job that must complete before the current jobs
                          are started. MANIFEST must contain exactly (SIMS/PROCS) job IDs separated by newlines.

                          Blocking happens on a one-to-one basis. For example, if (SIMS/PROCS) is N, then the first job
                          launched by $me will wait until the first ID in MANIFEST has completed. The second job
                          launched by $me will wait until the second ID in MANIFEST has completed. And so on until N.

  --hold
                          Jobs are submitted in held state. Can be used by parent script to impose a launch order
                          before releasing jobs.

  --job_name JOB_NAME
                          JOB_NAME is the name of the SLURM job. This will be used in the autogenerated regression
                          summary directory name.

                          Default is 'dat' as of writing this, but should be changed on a per-project basis.

  --mail EMAIL
                          Send user e-mail when jobs ends. Sends e-mail to EMAIL

  --mem MEM
                          MEM is the amount of memory (eg 500m, 7g) to request.

  --nodes NODES
                          NODES is the number of compute nodes to request.

  --num_cpus CPUS
                          CPUS is the number of CPUs to be allocated to the job.

  --num_gpus NUM_GPUS
                          NUM_GPUS is the number of GPUs to be allocated to the job.

  --num_proc_per_gpu PROCS
                          PROCS is the number of processes, aka simulations, to run on the requested compute resource.

                          If for example you are running the command 'train.py --epochs 200' on a GPU resource, and PROC
                          is 3, then 3 instances of 'train.py --epochs 200' will be launched in parallel on the GPU.

                          Default is 1.

  --num_simulations SIMS
                          SIMS is the number of is the number of instances of your base scripts to be launched.
                          $me will launch (SIMS/PROCS) jobs in order to run a total of SIMS instances of the base
                          scripts in parallel.

                          SIMS must be divisible by PROCS. See --num_proc_per_gpu for an explanation of PROCS.

                          Default is 12.

  --regress_dir REGRESS_DIR
                          REGRESS_DIR is the directory beneath which the simulation output directories will be generated.

                          Default is ${SLURM_SIMULATION_TOOLKIT_REGRESS_DIR}.

  --singleton
                          If provided, only one job named JOB_NAME will run at a time by this user on this cluster. If
                          a job named JOB_NAME is already running, this job will wait for that job to finish before
                          starting. Similarly, if this job is running, any future job named JOB_NAME and having used
                          the --singleton switch will wait for this job to finish.

                          Disabled by default.
  --time TIME
                          TIME is the time allocated for each job. Example format: '1-23:45:56' ie 1 day, 23 hours,
                          45 minutes, 56 seconds. Default is 4 hours.
"
}

# Echo the command run by the user
# useful if scrolling up in the shell or if called by wrapper script
input_command="${me} $@"

#echo "RUNNING:"
#echo "${input_command}"
#echo ""

########################################################################################################################
######################## SET DEFAULT REGRESSION PARAMETERS -- CHANGE THESE OPTIONALLY ##################################
########################################################################################################################
regress_dir=${SLURM_SIMULATION_TOOLKIT_REGRESS_DIR}

########################################################################################################################
###################################### ARGUMENT PROCESSING AND CHECKING ################################################
########################################################################################################################
blocking_jobs=()
singleton=''
base_script=''
hold=''

while [[ $# -ne 0 ]]; do
  case "$1" in
    -h|--help)
      showHelp
      exit 0
    ;;
    --)
      shift 1
      # pass all arguments following '--' to child script
      child_args="$@"
      shift $#
    ;;
    --account)
      account=$2
      shift 2
    ;;
    --base_script)
      base_script=$2
      shift 2
    ;;
    --blocking_job_manifest)
      blocking_jobs+=(`cat $2`)
      shift 2
    ;;
    --hold)
      hold=yes
      shift 1
    ;;
    --job_name)
      job_name=$2
      shift 2
    ;;
    --mail)
      email=yes
      EMAIL=$2
      shift 2
      if [[ ${EMAIL} == -* ]]; then
          echo "ERROR: invalid email: ${EMAIL}"
          exit 1
      fi
      if [[ ${EMAIL} != *@* ]]; then
          echo "ERROR: invalid email: ${EMAIL}"
          exit 1
      fi
    ;;
    --mem)
      mem=$2
      shift 2
    ;;
    --nodes)
      nodes=$2
      shift 2
    ;;
    --num_cpus)
      cpus=$2
      shift 2
    ;;
    --num_gpus)
      gpus=$2
      shift 2
    ;;
    --num_proc_per_gpu)
      num_proc_per_gpu=$2
      shift 2
    ;;
    --num_simulations)
      num_simulations=$2
      shift 2
    ;;
    --regress_dir)
      regress_dir=$2
      shift 2
    ;;
    --singleton)
      singleton='yes'
      shift 1
    ;;
    --time)
      time=$2
      shift 2
    ;;
    -*)
      echo "Invalid option $1"
      exit 1
    ;;
  esac
done

if [[ -z ${base_script} ]]; then
    die "Base script must be provided via --base_script option."
fi

if [[ ! -f ${base_script} ]]; then
    die "Invalid base script: ${base_script}. Please provide a valid one via --base_script"
fi
base_script=$(readlink -f ${base_script})

if (( ${num_simulations} % ${num_proc_per_gpu} )) ; then
  die "$num_simulations not divisible by $num_proc_per_gpu"
fi

num_jobs=$(echo $((num_simulations / num_proc_per_gpu)))


if [[ "${#blocking_jobs[@]}" -gt ${num_jobs} ]]; then
    msg="Number of blocking jobs (${#blocking_jobs[@]}) in the job manifest ($blocking_job_manifest)"
    msg+=" should be equal to the number of jobs (${num_jobs})."
    die "${msg}"
fi

########################################################################################################################
########################## DETERMINE SUMMARY FILE NAMES AND CREATE REGRESSION DIR ######################################
########################################################################################################################

# Create regression name and regression directory name based on job name and current time
regression_name="${job_name}_$(openssl rand -hex 4)"
output_dir=${regress_dir}/${regression_name}
batch_summary_dir=${output_dir}/batch_summary

# Create names of files that will contain summary information about regression
batch_command_file=${batch_summary_dir}/batch_command.txt
regression_logname_file=${batch_summary_dir}/log_manifest.txt
regression_slurm_logname_file=${batch_summary_dir}/slurm_log_manifest.txt
regression_job_numbers_file=${batch_summary_dir}/job_manifest.txt
regression_slurm_commands_file=${batch_summary_dir}/simulation_output.log
hash_reference_file=${batch_summary_dir}/hash_reference.txt
batch_cancellation_executable=${batch_summary_dir}/cancel_batch.sh

# create regression dir if doesn't exist
mkdir -p ${batch_summary_dir}

########################################################################################################################
######################## DETERMINE ARGUMENTS TO BE PASSED DOWN TO SIMULATION SCRIPT (simulation.sh) ####################
########################################################################################################################
job_script_options="--account ${account} --time ${time} --num_proc_per_gpu ${num_proc_per_gpu} --mem ${mem}"
job_script_options+=" --regress_dir ${output_dir} --nodes ${nodes} --num_cpus ${cpus} --num_gpus ${gpus}"
job_script_options+=" --base_script ${base_script}"
if [[ ${email} == yes ]]; then
  job_script_options+=" --mail ${EMAIL}"
fi
if [[ ${singleton} == 'yes' ]]; then
  job_script_options+=" --singleton"
fi
if [[ ${hold} == "yes" ]]; then
  job_script_options+=" --hold"
fi

########################################################################################################################
################################################ LAUNCH THE JOBS #######################################################
########################################################################################################################

declare -a pid_list
for (( i=0; i<$num_jobs; i++ ));
do
{
   job_unique_options=''
   if [[ "${#blocking_jobs[@]}" -gt 0 ]]; then
     job_unique_options+=" --wait_for_job ${blocking_jobs[$i]}"
   fi

   job_unique_options+=" --job_name ${job_name}"
   ${simulation_executable} ${job_script_options} ${job_unique_options} -- ${child_args} &> ${regression_slurm_commands_file}_${i}
   if [[ $? -ne 0 ]]; then
       die "${simulation_executable} failed. See ${regression_slurm_commands_file}_${i}"
   fi

   slurm_logfile=$(grep -oP '(?<=--output=)[^ ]+' ${regression_slurm_commands_file}_${i})
   echo ${slurm_logfile} > ${regression_slurm_logname_file}_${i}
   job_number=$(grep "Submitted" ${regression_slurm_commands_file}_${i} | grep -oP '\d+$')
   if [[ -z ${job_number} ]]; then
       die "Job number not found. ${simulation_executable} likely failed. See ${regression_slurm_commands_file}_${i}"
   fi

   for (( j=0; j<$num_proc_per_gpu; j++ )); do
      slurm_logdirname=$(dirname $slurm_logfile)
      slurm_logbasename=$(basename $slurm_logfile)
      gpu_number=${j}
      log_basename="${slurm_logbasename%.*}_proc_${gpu_number}.log"
      logfile=$slurm_logdirname/${log_basename}
      echo ${logfile} >> ${regression_logname_file}_${i}
   done

   echo ${job_number} > ${regression_job_numbers_file}_${i}
}&
pid=$!
pid_list[$i]=$pid
done

process_error=0
for (( i=0; i<$num_jobs; i++ ));
do
{
    pid=${pid_list[$i]}
    wait $pid
    if [[ $? -ne 0 ]]; then
        process_error=$((process_error+1))
    fi

    if [[ ${process_error} -gt 0 ]]; then
        die "${simulation_executable} failed. See above error."
    fi
}
done

#if [[ -n ${max_jobs_in_parallel} ]]; then
#    singleton_id=$(((last_singleton_id+$num_jobs) % ${max_jobs_in_parallel}))
#    echo ${singleton_id} > ${SLURM_SIMULATION_TOOLKIT_REGRESS_DIR}/singleton_id.txt
#fi

# remove temporary files
cat ${regression_slurm_logname_file}_* > ${regression_slurm_logname_file}
cat ${regression_logname_file}_* > ${regression_logname_file}
cat ${regression_job_numbers_file}_* > ${regression_job_numbers_file}
cat ${regression_slurm_commands_file}_* > ${regression_slurm_commands_file}
rm ${regression_slurm_logname_file}_* ${regression_logname_file}_*
rm ${regression_job_numbers_file}_* ${regression_slurm_commands_file}_*

# create batch cancellation script
echo '#!/usr/bin/env bash' > ${batch_cancellation_executable}
echo "scancel \$(cat ${regression_job_numbers_file})" >> ${batch_cancellation_executable}
chmod +x ${batch_cancellation_executable}

########################################################################################################################
#################################### PRINT LOCATION OF SUMMARY FILES TO USER ###########################################
########################################################################################################################

echo "${input_command}" > ${batch_command_file}

# Create a shorthand reference, eg beluga@4k35d00r to be used by regression_status.sh script
# Note: may be used in process_result.sh in the future
hash=$(echo -n `readlink -f $regression_logname_file` | sha1sum | grep -oP '^\w{8}')
reference="${local_cluster}@${hash}"

echo "${reference}" > ${hash_reference_file}

echo "JOB IDs FILE IN: $(readlink -f ${regression_job_numbers_file})"
echo "SIMULATION SCRIPT OUTPUT LOGFILE: $(readlink -f ${regression_slurm_commands_file})"
echo "BATCH CANCELLATION SCRIPT: $(readlink -f ${batch_cancellation_executable})"
echo "BATCH COMMAND FILE: $(readlink -f ${batch_command_file})"
echo "SLURM LOGFILES MANIFEST: $(readlink -f ${regression_slurm_logname_file})"
echo "SIMULATION LOGS MANIFEST: $(readlink -f ${regression_logname_file})"
echo "HASH REFERENCE FILE: $(readlink -f ${hash_reference_file})"
echo "HASH REFERENCE: $reference"