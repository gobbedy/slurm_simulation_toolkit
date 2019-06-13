#!/usr/bin/env bash
source ${SLURM_SIMULATION_TOOLKIT_HOME}/config/simulation_toolkit.rc

############################################################################################################
######################################## HELPER VARIABLES AND FUNCTIONS ####################################
############################################################################################################

function showHelp {

echo "NAME
  $me -
     1) Runs slurm job using srun
     2) Uses CPU or GPU options defined in project.rc as SRUN_OPTIONS_CPU or SRUN_OPTIONS_GPU
SYNOPSIS
  $me [OPTIONS] [-- OPTIONS_FOR_BASE_SCRIPT]
OPTIONS
  -h, --help
                          Show this description

  --account ACCOUNT
                          ACCOUNT is the slurm account to use for every job (def-yymao or rrg-yymao).
                          Default is rrg-mao on Cedar, def-yymao otherwise.

  -c, --num_cpus CPUS
                          CPUS is the number of CPUs to be allocated to the job. Default 1.

  --cmd, --command COMMAND
                          COMMAND is the SLURM command to use: salloc, srun or sbatch. Default is salloc.

  -e, --export EXPORT
                          EXPORT is a comma-separated list of environment variables to be passed down to the sbatch
                          script (aka SCRIPT_NAME). eg 'a=2,str=\"hello\"'

  -g, --num_gpus NUM_GPUS
                          NUM_GPUS is the number of GPUs to be allocated to the job. Default 0.

  -j, --job_name JOB_NAME
                          JOB_NAME is the name of job to be displayed in SLURM queue.

  -m, --mem MEM
                          MEM is the amount of memory (eg 500m, 7g) to request.

  --mail EMAIL
                          Send user e-mail when job ends. Sends e-mail to EMAIL

  -n, --nodes NODES
                          NODES is the number of compute nodes to request.

  --num_proc_per_gpu PROCS
                          PROCS is the number of processes, aka simulations, to run on the requested compute resource.

                          If for example you are running the command 'train.py --epochs 200' on a GPU resource, and PROC
                          is 3, then 3 instances of 'train.py --epochs 200' will be launched in parallel on the GPU.

                          Default is 2 (process per resource) on Beihang cluster, 1 otherwise.

  --output LOGFILE
                          Logfile is the SLURM output filename.

  -s, --test
                          Run slurm command in test mode. Command that *would* be run is printed
                          but job is not actually scheduled.
                          Can be used to test the launch scripts themselves.

  --script_name SCRIPT_NAME
                          SCRIPT_NAME is the name of sbatch script to be executed. To be safe, provide full path.
                          If CMD is salloc, SCRIPT_NAME should not be provided.
                          If CMD is srun or sbatch, SCRIPT_NAME must be provided.

  --singleton
                          If provided, only one job named JOB_NAME will run at a time by this user on this cluster. If
                          a job named JOB_NAME is already running, this job will wait for that job to finish before
                          starting. Similarly, if this job is running, any future job named JOB_NAME and having used
                          the --singleton switch will wait for this job to finish.

  -t, --time TIME
                          TIME is the clock time allocated to the job: As of July 2018, salloc max is 3 hours.
                          The job will be interrupted if the script is still running after the time limit is up.

  --wait_for_job JOB_ID
                          If provided, the current job will wait for job with ID JOB_ID before starting.
"
}

########################################################################################################################
########################################## SET DEFAULT REGRESSION PARAMETERS ###########################################
########################################################################################################################
slurm_command=srun
singleton=no
blocking_job_id=''

########################################################################################################################
###################################### ARGUMENT PROCESSING AND CHECKING ################################################
########################################################################################################################
script_name=''
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
      break
    ;;
    -a|--account)
      account=$2
      shift 2
    ;;
    -c|--num_cpus)
      cpus=$2
      shift 2
    ;;
    --cmd|--command)
      slurm_command=$2
      shift 2
    ;;
    -e|--export)
      export=$2
      shift 2
    ;;
    -g|--num_gpus)
      gpus=$2
      shift 2
    ;;
    -j|--job_name)
      job_name=$2
      shift 2
    ;;
    -m|--mem)
      mem=$2
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
    -n|--nodes)
      nodes=$2
      shift 2
    ;;
    --num_proc_per_gpu)
      num_proc_per_gpu=$2
      shift 2
    ;;
    --output)
      output_file=$2
      shift 2
    ;;
    -s|--test)
      slurm_test_mode=yes
      shift 1
    ;;
    --script_name)
      script_name=$2
      shift 2
    ;;
    --singleton)
      singleton=yes
      shift 1
    ;;
    -t|--time)
      time=$2
      shift 2
    ;;
    --wait_for_job)
      blocking_job_id=$2
      shift 2
    ;;
    -*)
      die "Invalid option $1"
    ;;
  esac
done

########################################################################################################################
########################################### BUILD SLURM OPTIONS ########################################################
########################################################################################################################
if [[ -z ${output_file} ]]; then
  output_file=${job_name}.slurm
fi

if [[ "${slurm_command}" == "salloc" ]]; then
  if [[ -n ${script_name} ]]; then
    >&2 echo "$me: ERROR: salloc command does not require a script to be run"
    exit 1
  fi
else
  if [[ -z ${script_name} ]]; then
    >&2 echo "$me: ERROR: require exactly 1 script to run"
    exit 1
  fi
fi

slurm_options="--time=${time} --job-name=${job_name} --nodes=${nodes}"
slurm_options+=" --output=${output_file} --open-mode=append"

if [[ ${account} != "dummy" ]]; then
    slurm_options+=" --account=${account}"
fi

if [[ ${email} == "yes" ]]; then
  slurm_options+=" --mail-type=END --mail-user=${EMAIL} --signal=USR1@5"
  export+=",mail=yes"
fi

if [[ ${slurm_test_mode} == "yes" ]]; then
  slurm_options+=" --test-only"
fi

if [[ ${singleton} == "yes" ]]; then
  slurm_options+=" --dependency=singleton"
fi

if [[ ${local_cluster} == "niagara" ]]; then
    slurm_options+=" --ntasks=${cpus}"
else
    if [[ ${cpus} -gt 0 ]]; then
      slurm_options+=" --ntasks=${cpus}"
    fi
    if [[ ${mem} != "dummy" ]]; then
        slurm_options+=" --mem=${mem}"
    fi
fi

if [[ ${gpus} -gt 0 ]]; then
  slurm_options+=" --gres=gpu:${gpus}"
  export+=",num_proc_per_gpu=${num_proc_per_gpu}"
fi

if [[ -n ${blocking_job_id} ]]; then
  slurm_options+=" --dependency=afterany:${blocking_job_id}"
fi

########################################################################################################################
############################################# LAUNCH SLURM COMMAND #####################################################
########################################################################################################################

if [[ ${slurm_command} == "salloc" ]]; then
  slurm_run_command="${slurm_command} ${slurm_options}"
else
  slurm_run_command="${slurm_command} ${slurm_options} --export=${export} ${script_name} ${child_args}"
fi

echo "${me}: SUBMITTING THE FOLLOWING SLURM COMMAND on `date`:"
echo  ${slurm_run_command}
echo ""

echo "${me}: SLURM SUBMISSION OUTPUT:"
eval ${slurm_run_command}

if [[ ${slurm_command} == "salloc" ]]; then
  echo "SLURM JOB ENDED ON `date`"
fi