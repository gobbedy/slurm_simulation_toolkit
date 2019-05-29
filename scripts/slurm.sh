#!/bin/bash
set -o pipefail
me=$(basename ${0%%@@*})
full_me=${0%%@@*}
me_dir=$(dirname $(readlink -f ${0%%@@*}))

######################################################################
# Helper functions
######################################################################

function showHelp {

echo "NAME
  $me -
     1) Runs slurm job using srun
     2) Uses CPU or GPU options defined in project.rc as SRUN_OPTIONS_CPU or SRUN_OPTIONS_GPU
SYNOPSIS
  $me [OPTIONS] [--num_cpus|--num_gpus|--job_name|--time] [script_name]
OPTIONS
  -h, --help
                          Show this description
  -a, --account
                          Which account to use (def-yymao or rrg-yymao)
  --mail EMAIL
                          Send user e-mail when job ends. Sends e-mail to EMAIL
  -c, --num_cpus
                          Number of CPUs to be allocated to the job. Default 1.
  --cmd, --command
                          The SLURM command to use: salloc, srun or sbatch. Default is srun.
                          If salloc, not script_name must not be provided.
                          If srun or sbatch, script_name must be provide.
  -e, --export
                          Which SLURM command (salloc, srun, sbatch) to use. Default salloc.
  -g, --num_gpus
                          Number of GPUs to be allocated to the job. Default 0.
  -j, --job_name
                          Name of job to be displayed in SLURM queue.
  -m, --mem
                          Amount of memory (eg 500m, 7g). Default 256m.
  -n, --nodes
                          Number of compute nodes.
  -o, --output
                          Logfile name.
  -s, --test
                          Run slurm command in test mode. Command that *would* be run is printed
                          but job is not actually scheduled.
                          Can be used to test the launch scripts themselves.
  -t, --time
                          Time allocated to the job: As of July 2018, admin max is 3 hours. The job will be interrupted
                          if the script is still running.
"
}

function die {
  printf "${me}: %b\n" "$@" >&2
  exit 1
}

time="00:01:00"
job_name=portfolio
num_cpus=1
num_gpus=0
num_proc_per_gpu=1
mem=256m
slurm_command=srun
mail='' 
slurm_test_mode=''
singleton=''
account="def-yymao"
blocking_job_id=''

while [[ "$1" == -* ]]; do
  case "$1" in
    -h|--help)
      showHelp
      exit 0
    ;;
    -a|--account)
      account=$2
      shift 2
    ;;
    --mail)
      mail=yes
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
    -c|--num_cpus)
      num_cpus=$2
      shift 2
    ;;
    --num_proc_per_gpu)
      num_proc_per_gpu=$2
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
      num_gpus=$2
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
    -n|--nodes)
      num_nodes=$2
      shift 2
    ;;
    --prolog)
      prolog_file=$2
      shift 2
    ;;
    -s|--test)
      slurm_test_mode=yes
      shift 1
    ;;
    --singleton)
      singleton=yes
      shift 1
    ;;
    -t|--time)
      # for now, looks like max duration is 3hours
      time=`date -d "Dec 31 + $2"  "+%j-%H:%M:%S" |& sed 's/^365-//'`
	  if [[ $? -ne 0 ]]; then
	    # date command doesn't like the format given, we assume it's a format that slurm understands directly
		time=$2
	  fi
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

node_prefix=$(hostname | cut -c1-3)
if [[ $node_prefix == "hel" ]]; then
   local_cluster=helios
elif [[ $node_prefix == "del" ]]; then
   local_cluster=beihang
elif [[ $node_prefix == "nia" ]]; then
   local_cluster=niagara
elif [[ $node_prefix == "bel" ]]; then
   local_cluster=beluga
elif [[ $node_prefix == "ced" ]]; then
   local_cluster=cedar
elif [[ $node_prefix == "gra" ]]; then
   local_cluster=graham
elif [[ $node_prefix == ip* ]]; then
   local_cluster=mammouth
else
  echo "WARNING: local cluster unsupported"
fi

# should be /32 instead of /48 on graham
# But I haven't used this option in years anyway
if [[ ${local_cluster} == "graham" ]]; then
  num_nodes=$((( ($num_cpus-1) / 32) + 1 ))
elif [[ -z ${num_nodes} ]]; then
  num_nodes=$((( ($num_cpus-1) / 48) + 1 ))
fi

if [[ -z ${prolog_file} ]]; then
  prolog_file=${job_name}.log
fi

if [[ "${slurm_command}" == "salloc" ]]; then
  if [[ $# -ne 0 ]]; then
    >&2 echo "$me: ERROR: salloc command does not require a script to be run"
    exit 1
  fi
else
  if [[ $# -ne 1 ]]; then
    >&2 echo "$me: ERROR: require exactly 1 script to run"
    exit 1
  fi
  script_name=$1
fi

slurm_options="--time=${time} --job-name=${job_name} --nodes=${num_nodes}"
slurm_options+=" --output=${prolog_file} --open-mode=append"

if [[ ${local_cluster} != "beihang" ]]; then
    slurm_options+=" --account=${account}"
fi

if [[ -n ${mail} ]]; then
  #slurm_options+=" --mail-type=BEGIN --mail-type=END --mail-type=REQUEUE --mail-user=gperr050@uottawa.ca"
  slurm_options+=" --mail-type=END --mail-user=${EMAIL} --signal=USR1@5"
  export+=",mail=yes"
fi

if [[ -n ${slurm_test_mode} ]]; then 
  slurm_options+=" --test-only"
fi

if [[ -n ${singleton} ]]; then
  slurm_options+=" --dependency=singleton"
fi

if [[ ${local_cluster} == "niagara" ]]; then
    slurm_options+=" --ntasks=${num_cpus}"
#elif [[ ${local_cluster} == "beihang" ]]; then
#    :
else
    if [[ ${num_cpus} -gt 0 ]]; then
      slurm_options+=" --ntasks=${num_cpus}"
    fi
    slurm_options+=" --mem=${mem}"
fi

if [[ ${num_gpus} -gt 0 ]]; then
  slurm_options+=" --gres=gpu:${num_gpus}"
  export+=",num_proc_per_gpu=${num_proc_per_gpu}"
fi

if [[ -n ${blocking_job_id} ]]; then
  slurm_options+=" --dependency=afterany:${blocking_job_id}"
fi

if [[ ${slurm_command} == "salloc" ]]; then
  slurm_run_command="${slurm_command} ${slurm_options}"
else
  slurm_run_command="${slurm_command} ${slurm_options} --export=${export} ${script_name}"
fi

echo "${me}: SUBMITTING THE FOLLOWING SLURM COMMAND on `date`:"
echo  ${slurm_run_command}
echo ""

echo "${me}: SLURM SUBMISSION OUTPUT:"
eval ${slurm_run_command}

if [[ ${slurm_command} == "salloc" ]]; then
  echo "SLURM JOB ENDED ON `date`"
fi