#!/usr/bin/env bash
source ${SLURM_SIMULATION_TOOLKIT_HOME}/config/simulation_toolkit.rc

function showHelp {

echo "NAME
  $me -
     1) Report regression status (running, completed, failed)
     2) Print one line summary of results
SYNOPSIS
  $me [OPTIONS]
OPTIONS
  -h, --help
                          Show this description
  --ref REF
                          REF is a short reference to the regression outputted by the mini_regression.sh script.
                          The format is <cluster_name>@<hash_of_log_manifest_filename>
"
}

check_epochs=''
while [[ "$1" == -* ]]; do
  case "$1" in
    -h|--help)
      showHelp
      exit 0
    ;;
    --ref)
      reference=$2
      shift 2
    ;;
    -*)
      echo "Invalid option $1"
      exit 1
    ;;
  esac
done

errors=0
while [[ "$1" == -* ]]; do
  case "$1" in
    -*)
      die "Invalid option $1"
    ;;
  esac
done

if [[ $# -ne 0 ]]; then
    die "ERROR: unparsed arguments $@"
fi

hash_to_find="${reference##*@}"
regression_summary_dir=${SLURM_SIMULATION_TOOLKIT_REGRESS_DIR}/regression_summary
local_regressions_filename_list=(`readlink -f ${regression_summary_dir}/*/log_manifest.txt`)
declare -A local_regressions_filename_hashlist
for local_regressions_filename in "${local_regressions_filename_list[@]}"
do
    #echo $local_regressions_filename
    hash=$(echo -n `readlink -f $local_regressions_filename` | sha1sum | grep -oP '^\w{8}')
    #echo $hash
    local_regressions_filename_hashlist[$hash]=$local_regressions_filename
done
log_manifest=${local_regressions_filename_hashlist[${hash_to_find}]}
regression_summary_dirname=$(dirname ${log_manifest})
job_manifest="${regression_summary_dirname}/job_manifest.txt"
command_file="${regression_summary_dirname}/regression_command.txt"

#echo "JOBS:"
#cat $job_manifest

#echo "COMMAND:"
#cat $command_file

logfiles=($(cat ${log_manifest}))
jobid_list=($(cat ${job_manifest}))
num_logs="${#logfiles[@]}"
result_separator=`printf %125s |tr " " "-"`
num_completed_jobs=0

#for logfile in "${logfiles[@]}"
test_errors=()
for (( i=0; i<$num_logs; i++ ));
do
    logfile=${logfiles[$i]}
    slurm_logfile=$(ls $(dirname $logfile)/*slurm)
    echo ${result_separator}
    echo "LOGFILE: $logfile"

    sbatch_command_error=`grep 'sbatch: error' ${slurm_logfile}`
    if [[ -n ${sbatch_command_error} ]]; then
        error "sbatch command failed. Check ${slurm_logfile}"
        echo ${result_separator}
        num_completed_jobs=$(( num_completed_jobs + 1 ))
        continue
    fi

    jobid=${jobid_list[$i]}

    job_failed=`sacct -j ${jobid} -o State -n | grep FAILED`
    if [[ -n ${job_failed} ]]; then
        error "Job ${jobid} failed. Check ${logfile} or ${slurm_logfile}"
        echo ${result_separator}
        num_completed_jobs=$(( num_completed_jobs + 1 ))
        continue
    fi

    job_pending=`sacct -j ${jobid} -o State -n | grep PENDING`
    if [[ -n ${job_pending} ]]; then
        echo "Job ${jobid} has not yet started."
        echo ${result_separator}
        continue
    fi

    job_running=`sacct -j ${jobid} -o State -n | grep RUNNING`
    if [[ -n ${job_running} ]]; then
        echo "Job ${jobid} still running."
        echo ${result_separator}
        continue
    fi

    num_completed_jobs=$(( num_completed_jobs + 1 ))

    echo "Job ${jobid} completed successfully."
    simulation_duration=$(sacct -j ${jobid} -o Elapsed -np | grep -oPm 1 '^[^|]+')
    echo "Duration ${simulation_duration}"

    echo ${result_separator}
done

if [[ ${num_completed_jobs} -ne ${num_logs} ]]; then
    echo "${num_completed_jobs} out of ${num_logs} simuations done"
fi

if [[ ${errors} -gt 0 ]]; then
    if [[ ${num_completed_jobs} -ne ${num_logs} ]]; then
        echo "REGRESSION WILL FAIL: $errors simulations have errors." >&2
        exit 1
    else
        echo "REGRESSION FAILED: $errors simulations have errors." >&2
        exit 1
    fi
else
    if [[ ${num_completed_jobs} -ne ${num_logs} ]]; then
        echo "REGRESSION IN PROGRESS: ${num_completed_jobs}/${num_logs} simulations complete. No errors so far."
        exit 2
    else
        echo "REGRESSION SUCCEEDED: ${num_completed_jobs}/${num_logs} simulations complete."
    fi
fi