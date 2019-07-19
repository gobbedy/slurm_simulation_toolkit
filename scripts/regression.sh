#!/usr/bin/env bash
source ${SLURM_SIMULATION_TOOLKIT_HOME}/config/simulation_toolkit.rc
source ${SLURM_SIMULATION_TOOLKIT_JOB_RC_PATH} # time, nodes, cpus, gpus, memory to request by cluster
datetime_suffix=$(date +%b%d_%H%M%S)

#######################################################################################################################
########################################### HELPER VARIABLES AND FUNCTIONS ############################################
#######################################################################################################################

batch_simulation_executable="simulation_batch.sh"

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
                          Default is rrg-mao on Cedar, def-yymao otherwise. If also provided at the regression
                          control file level, the regression control file argument takes precendence.

  --max_jobs_in_parallel MAX
                          Enforce a maximum of MAX jobs in parallel for the current regression. This is mainly useful
                          for SLURM systems that don't use a fairshare policy (eg. in Beta testing phase of a new
                          cluster). Makes use of the '--dependency=<...>' option of sbatch.

                          On systems that DO use a fairshare policy, this option is probably a bad idea, for two
                          reasons. The first is that fairshare policies handle prioritizing jobs, so there shouldn't be
                          any need to manually limit the number of jobs to a fixed number.

                          But should the user still decide to use this option on a system using a fairshare policy,
                          the maximum number of jobs enforcement comes at a price: jobs may stay in the PENDING state
                          for a longer period of time. This is because the mechanism to preserve order is job
                          dependencies, and the age factor of pending jobs does not change while it waits for its
                          dependency to be met. See https://slurm.schedmd.com/priority_multifactor.html

                          Default is no maximum.

  --num_proc_per_gpu PROCS
                          PROCS is the number of processes, aka simulations, to run on the requested compute resource.

                          If for example you are running the command 'train.py --epochs 200' on a GPU resource, and PROC
                          is 3, then 3 instances of 'train.py --epochs 200' will be launched in parallel on the GPU.

                          If also provided at the regression control file level, the regression control file argument
                          takes precendence.

                          Default is 1.

  --mail EMAIL
                          Send user e-mail when jobs ends. Sends e-mail to EMAIL
  --preserve_order
                          Simulations will be run in the same order as they appear in REGRESN_CTRL.

                          Similarly to the --max_jobs_in_parallel option, this comes at a price on systems using a
                          fairshare policy. The age factor of pending jobs will not change as long as the previous
                          job has not begun.

                          This can have a BIG impact on job pending times, so use with caution.

                          Order is not preserved by default.

  --regresn_ctrl REGRESN_CTRL
                          REGRESN_CTRL is a control file containing a list of simulation batches to run.
"
}

# Echo the command run by the user
# useful if scrolling up in the shell or if called by wrapper script
input_command="${me} $@"

echo "RUNNING:"
echo "${input_command}"
echo ""

########################################################################################################################
######################## SET DEFAULT REGRESSION PARAMETERS -- CHANGE THESE OPTIONALLY ##################################
########################################################################################################################
regress_dir=${SLURM_SIMULATION_TOOLKIT_REGRESS_DIR}

########################################################################################################################
###################################### ARGUMENT PROCESSING AND CHECKING ################################################
########################################################################################################################
max_jobs_in_parallel=''
regresn_ctrl_file=''
preserve_order=''
num_proc_per_gpu='' # will default to 1 in simulation_batch.sh if neither provided here nor in regresn ctrl file
account='' # will similarly be set to correct default in simulation_batch.sh if not provided
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
    --max_jobs_in_parallel)
      max_jobs_in_parallel=$2
      shift 2
    ;;
    --num_proc_per_gpu)
      num_proc_per_gpu=$2
      shift 2
    ;;
    --preserve_order)
      preserve_order='yes'
      shift 1
    ;;
    --regresn_ctrl)
      regresn_ctrl_file=$2
      shift 2
    ;;
    -*)
      echo "Invalid option $1"
      exit 1
    ;;
  esac
done

if [[ -z ${regresn_ctrl_file} ]]; then
    die "Please provide a regression control file via --regresn_ctrl"
fi

if [[ ! -f "${regresn_ctrl_file}" ]]; then
    die "Regression control file ($regresn_ctrl_file) invalid. Please provide a valid one via --regresn_ctrl"
fi
regresn_ctrl_file=$(readlink -f ${regresn_ctrl_file})

########################################################################################################################
########################## DETERMINE SUMMARY FILE NAMES AND CREATE REGRESSION DIR ######################################
########################################################################################################################

# Create regression name and regression directory name based on job name and current time
regression_name="${datetime_suffix}"
output_dir=${regress_dir}/${regression_name}
regression_summary_dir=${output_dir}/regression_summary

# Create names of files that will contain summary information about regression
summary_logfile=${regression_summary_dir}/summary.log
batch_outputs_logfile=${regression_summary_dir}/batch_outputs.log
regression_cancellation_executable=${regression_summary_dir}/cancel_regression.sh
regression_command_file=${regression_summary_dir}/regression_command.txt
simulations_manifests=${regression_summary_dir}/simulations_manifests.txt
hash_manifest=${regression_summary_dir}/hash_manifest.txt
batch_command_manifest=${regression_summary_dir}/batch_command_manifest.txt

# create regression dir if doesn't exist
mkdir -p ${regression_summary_dir}

# copy regresn ctrl file for safekeeping
cp ${regresn_ctrl_file} ${regression_summary_dir}
ctrl_file_basename=$(basename ${regresn_ctrl_file})
regresn_ctrl_file="${regression_summary_dir}/${ctrl_file_basename}"

########################################################################################################################
################## DETERMINE ARGUMENTS TO BE PASSED DOWN TO SIMULATION SCRIPT (simulation_batch.sh) ####################
########################################################################################################################
batch_script_options=" --regress_dir ${output_dir}"
if [[ ${email} == yes ]]; then
  batch_script_options+=" --mail ${EMAIL}"
fi

########################################################################################################################
######################################## PROCESS THE CONTROL FILE ######################################################
########################################################################################################################
source_root_dir=${SLURM_SIMULATION_TOOLKIT_SOURCE_ROOT_DIR}
readarray lines < ${regresn_ctrl_file}

echo "Pre-processing control file..."
start_time=`date +%s`
declare -a total_line_list
for (( idx=0; idx<${#lines[@]}; idx++ ));
do
{
   # remove leading and trailing whitespace
   line=${lines[${idx}]}
   line="$(echo -e "${line}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

   # skip comments
   if [[ ${line:0:1} == "#" ]]; then
       continue
   fi

   # skip empty lines
   if [[ -z "${line}" ]]; then
       continue
   fi

   # handle loop control commands
   if [[ ${line:0:1} == "@" ]]; then
       # remove inner whitespace
       line="$(echo -e "${line}" | sed -e 's/[[:space:]]*//')"

       # get loop variable names
       loop_iterator_name_list=($(echo ${line} | grep -oP '\w+(?=\[)'))

       # get range data
       range_data_list=($(echo ${line} | grep -oP '[^\[]+(?=\])'))

       # create bash arrays from loop variable names / data
       for (( kdx=0; kdx<"${#loop_iterator_name_list[@]}"; kdx++ ));
       do
           loop_iterator_name=${loop_iterator_name_list[${kdx}]}
           range_data=${range_data_list[${kdx}]}

           # handle if range uses start:increment:end format eg myval[0:2:10]
           if [[ $(echo ${range_data} | tr -cd ':' | wc -c) -eq 2 ]]; then
               start=$(echo ${range_data} | grep -oP '^[^:]+')
               increment=$(echo ${range_data} | grep -oP ':\K.+(?=:)')
               end=$(echo ${range_data} | grep -oP '[^:]+$')
               iterator_values=$(seq ${start} ${increment} ${end})
               eval "declare -a ${loop_iterator_name}=(${iterator_values})"
           else
              # handle if range specified using comma separated values eg myval[0,2,4,6,8,10]
               iterator_values=${range_data//,/ }
               eval "declare -a ${loop_iterator_name}=(${iterator_values})"
           fi
           num_iterator_values=$(echo ${iterator_values} | wc -w)
           if [[ ${kdx} -eq 0 ]]; then
               if [[ ${unrolled_loop_size} -eq 0 ]]; then
                   unrolled_loop_size=${num_iterator_values}
               else
                   unrolled_loop_size=$((num_iterator_values * unrolled_loop_size))
               fi
           fi

       done

       loop_iterator_name_list_str="${loop_iterator_name_list[@]}"
       loop_iterator_name_matrix+=("${loop_iterator_name_list_str}")

       continue
   fi

   if [[ -n ${loop_iterator_name_matrix} ]]; then

       # see https://unix.stackexchange.com/a/136216/205605
       readarray line_list < <(yes $line | head -n ${unrolled_loop_size})
       loop_iterator_matrix_size=${#loop_iterator_name_matrix[@]}
       total_permutations=1
       for (( kdx=0; kdx<${loop_iterator_matrix_size}; kdx++ ));
       do
       {
           loop_iterator_name_spaced_list=${loop_iterator_name_matrix[${kdx}]} # eg "alpha alpha_related"
           loop_iterator_name_list=($(echo ${loop_iterator_name_spaced_list})) # get (alpha alpha_related)

           # get first element array size, ie ${#alpha[@]} -- should be same as other ones (eg. ${#alpha_related[@]}
           first_loop_iterator_name=${loop_iterator_name_list[0]} # eg "alpha"
           if [[ -z ${first_loop_iterator_name} ]]; then
               echo $line
               die "first_loop_iterator_name empty"
               exit
           fi
           array_size_cmd=$(echo \$\{#${first_loop_iterator_name}[@]\}) # eg "${#alpha[@]}"
           array_size=$(eval echo ${array_size_cmd})

           for (( mdx=0; mdx<${#loop_iterator_name_list[@]}; mdx++ ));
           do
           {
               loop_iterator_name=${loop_iterator_name_list[${mdx}]} # eg "alpha"
               iterator_value_list_cmd=$(echo \$\{${loop_iterator_name}[@]\}) # eg "${alpha[@]}"
               iterator_value_list=($(eval echo ${iterator_value_list_cmd}))  # eg (1.0 1.5 2.0 2.5)
               #echo $loop_iterator_name
               for (( pdx=0; pdx<${unrolled_loop_size}; pdx++ ));
               do
               {
                   iterator_value=${iterator_value_list[(${pdx}/${total_permutations})%${array_size}]}
                   unrolled_line=${line_list[${pdx}]}
                   unrolled_line=$(echo ${unrolled_line} | sed "s/\<${loop_iterator_name}\>/${iterator_value}/g")
                   line_list[${pdx}]=${unrolled_line}
               }
               done
           }
           done
           total_permutations=$((total_permutations*array_size))
       }
       done
       unset loop_iterator_name_matrix
       unrolled_loop_size=0
   else
       line_list=("${line}")
   fi
   total_line_list+=("${line_list[@]}")
}
done

# split lines into manageable number of simulations
max_sim_per_bucket=1500
total_num_sim_bucket=0
line_bucket_start_idx_list=(0)
declare -a line_bucket_end_idx_list
for (( idx=0; idx<${#total_line_list[@]}; idx++ ));
do
{
   # remove leading and trailing whitespace
   line=${total_line_list[${idx}]}

   num_sim=$(echo $line | grep -oP -- '--num_simulations\s+\K\d+')
   if [[ -z ${num_sim} ]]; then
       num_sim=${num_simulations}
   fi
   total_num_sim_bucket=$((total_num_sim_bucket+num_sim))
   if [[ ${total_num_sim_bucket} -gt ${max_sim_per_bucket} ]]; then
       total_num_sim_bucket=${num_sim}
       line_bucket_end_idx_list+=($((idx-1)))
       line_bucket_start_idx_list+=(${idx})
   fi

}
done
line_bucket_end_idx_list+=($((idx-1)))
end=`date +%s`
runtime=$((end-start_time))
echo "Pre-processing took $runtime seconds"

########################################################################################################################
######################################### LAUNCH THE JOB BATCHES #######################################################
########################################################################################################################

echo "Launching jobs..."
start=`date +%s`
for (( jdx=0; jdx<${#line_bucket_start_idx_list[@]}; jdx++ ));
do
{
    unset pid_list
    declare -A pid_list
    line_bucket_start=${line_bucket_start_idx_list[${jdx}]} # eg 3
    line_bucket_end=${line_bucket_end_idx_list[${jdx}]} # eg 5
    line_bucket_size=$((line_bucket_end-line_bucket_start+1)) # eg 3
    for (( idx=0; idx<${line_bucket_size}; idx++ )); # 0,1,2
    do
    {
       line=${total_line_list[$((${line_bucket_start}+${idx}))]}
       line_split=($(echo $line))

       base_script=$(readlink -f ${source_root_dir}/${line_split[0]})
       batch_sim_args="${line_split[@]:1}"

       batch_unique_options=''
       if [[ ! "${batch_sim_args}" =~ "--account" ]]; then
           if [[ -n ${account} ]]; then
               batch_unique_options+=" --account ${account}"
           fi
       fi

       if [[ ! "${batch_sim_args}" =~ "--num_proc_per_gpu" ]]; then
           if [[ -n ${num_proc_per_gpu} ]]; then
               batch_unique_options+=" --num_proc_per_gpu ${num_proc_per_gpu}"
           fi
       fi

       zero_padded_idx=$(printf "%05d\n" ${idx}) # for alphabetical ordering
       ${batch_simulation_executable} --hold --base_script ${base_script} ${batch_script_options} ${batch_unique_options} ${batch_sim_args} &> ${batch_outputs_logfile}_${zero_padded_idx}
       if [[ $? -ne 0 ]]; then
           die "${batch_simulation_executable} failed. See ${batch_outputs_logfile}_${zero_padded_idx}"
       fi
    }&
    pid=$!
    pid_list[$pid]=1
    done

    process_error=0
    for pid in "${!pid_list[@]}"
    do
    {
        wait $pid
        if [[ $? -ne 0 ]]; then
            process_error=$((process_error+1))
        fi
    }
    done

    if [[ ${process_error} -gt 0 ]]; then
        die "${batch_simulation_executable} failed. See above error(s)."
    fi
}
done
end=`date +%s`
runtime=$((end-start))
echo "Launching took $runtime seconds"

# remove temporary files
cat ${batch_outputs_logfile}_* > ${batch_outputs_logfile}
rm ${batch_outputs_logfile}_*

# create batch cancellation script
echo '#!/usr/bin/env bash' > ${regression_cancellation_executable}
ls ${output_dir}/*/batch_summary/cancel_batch.sh >> ${regression_cancellation_executable}
chmod +x ${regression_cancellation_executable}

########################################################################################################################
############################################# RELEASE THE JOBS #########################################################
########################################################################################################################

unset pid_list
declare -A pid_list
start=`date +%s`
echo "Releasing jobs..."
job_id_list=($(cat $(grep "JOB IDs FILE IN:" ${batch_outputs_logfile} | grep -oP "\S+$")))
#job_id_list=($(cat ${output_dir}/*/batch_summary/job_manifest.txt|sort -n)) # in launch order
for (( idx=0; idx<${#job_id_list[@]}; idx++ ));
do
{
    job_id=${job_id_list[${idx}]}
    individual_job_name="${job_name}"
    dependency=""
    if [[ -n ${max_jobs_in_parallel} ]]; then

        # an easy way to implement max number of jobs would be to use singleton
        # however if want max number of jobs WITH preserving order, CANNOT use singleton because
        # singleton does not work in combination with other dependencies (slurm bug?)
        # instead, impose max number of jobs in parallel by waiting for prior jobs to finish
        if [[ ${idx} -ge ${max_jobs_in_parallel} ]]; then
            depend_idx=$((idx-max_jobs_in_parallel))
            depend_job_id=${job_id_list[${depend_idx}]}
            dependency+="afterany:${depend_job_id}"
        fi

    fi
    if [[ -n ${preserve_order} ]]; then
        if [[ ${idx} -ne 0 ]]; then
            if [[ -n ${dependency} ]]; then
                dependency+=","
            fi
            prev_idx=$((idx-1))
            prev_job_id=${job_id_list[${prev_idx}]}
            dependency+="after:${prev_job_id}"
        fi
    fi


    dependency_option=''
    if [[ -n ${dependency} ]]; then
        dependency_option="Dependency=${dependency}"
    fi

    scontrol update jobid=${job_id} JobName=${individual_job_name} ${dependency_option}
    scontrol release ${job_id}
}&
pid=$!
pid_list[$pid]=1
done

process_error=0
for pid in "${!pid_list[@]}"
do
{
    wait $pid
    if [[ $? -ne 0 ]]; then
        process_error=$((process_error+1))
    fi
}
done

if [[ ${process_error} -gt 0 ]]; then
    die "Job releasing failed. See above error(s)."
fi


end=`date +%s`
runtime=$((end-start))
echo "Releasing took $runtime seconds"

# get batch directories in the order created
#batch_dirs=($(grep CANCEL ${batch_outputs_logfile} | grep -oP "${output_dir}/\w+"))

# create manifest of simulation manifests -- preserve same order as regresn control file
grep "SIMULATION LOGS" ${batch_outputs_logfile} | grep -oP "\S+$" >> ${simulations_manifests}

# create manifest of batch hash references (preserve order)
grep "HASH REFERENCE:" ${batch_outputs_logfile} | grep -oP "\S+$" >> ${hash_manifest}

# create manifest of batch commands (preserve order)
cat $(grep "BATCH COMMAND" ${batch_outputs_logfile} | grep -oP "\S+$") >> ${batch_command_manifest}

########################################################################################################################
#################################### PRINT LOCATION OF SUMMARY FILES TO USER ###########################################
########################################################################################################################

echo "${input_command}" > ${regression_command_file}

echo "BATCH SCRIPT OUTPUT LOGFILE: $(readlink -f ${batch_outputs_logfile})" |tee -a ${summary_logfile}
echo "BATCH COMMAND MANIFEST: $(readlink -f ${batch_command_manifest})" |tee -a ${summary_logfile}
echo "REGRESSION CANCELLATION SCRIPT: $(readlink -f ${regression_cancellation_executable})" |tee -a ${summary_logfile}
echo "REGRESSION COMMAND FILE: $(readlink -f ${regression_command_file})" |tee -a ${summary_logfile}
echo "REGRESSION CONTROL FILE (COPY): $(readlink -f ${regresn_ctrl_file})" |tee -a ${summary_logfile}
echo "SIMULATION MANIFESTS: $(readlink -f ${simulations_manifests})" |tee -a ${summary_logfile}
echo "HASH REFERENCES TO BATCH RUNS: $(readlink -f ${hash_manifest})" |tee -a ${summary_logfile}
echo ""
echo "ABOVE SUMMARY: ${summary_logfile}"