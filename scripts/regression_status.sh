#!/usr/bin/env bash
source ${SLURM_SIMULATION_TOOLKIT_HOME}/config/simulation_toolkit.rc

function showHelp {

echo "NAME
  $me -
     1) Report regression status (running, completed, failed)
     2) Print one line summary of results
SYNOPSIS
  $me [--ref REF | -f MANITEST]
OPTIONS
  -h, --help
                          Show this description
  --ref REF
                          REF is a short reference to the regression outputted by the mini_regression.sh script.
                          The format is <cluster_name>@<hash_of_log_manifest_filename>

  -f MANIFEST
                          MANIFEST is a file containing a list of logfiles to process. Only one manifest file may be
                          provided.
"
}

reference=''
#errors=0
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
    -f)
      log_manifest=$2
      shift 2
    ;;
    -*)
      echo "Invalid option $1"
      exit 1
    ;;
  esac
done

if [[ $# -ne 0 ]]; then
    die "ERROR: unparsed arguments $@"
fi

if [[ -n ${reference} ]]; then
    hash_to_find="${reference##*@}"
    regress_dir=${SLURM_SIMULATION_TOOLKIT_REGRESS_DIR}
    local_regressions_filename_list=(`readlink -f ${regress_dir}/*/regression_summary/log_manifest.txt`)
    declare -A local_regressions_filename_hashlist
    for local_regressions_filename in "${local_regressions_filename_list[@]}"
    do
        #echo $local_regressions_filename
        hash=$(echo -n `readlink -f $local_regressions_filename` | sha1sum | grep -oP '^\w{8}')
        #echo $hash
        local_regressions_filename_hashlist[$hash]=$local_regressions_filename
    done
    log_manifest=${local_regressions_filename_hashlist[${hash_to_find}]}
fi

if [[ ! -f ${log_manifest} ]]; then
    die "Please provide a valid reference or log manifest."
fi

regression_summary_dirname=$(dirname ${log_manifest})
job_manifest="${regression_summary_dirname}/job_manifest.txt"
command_file="${regression_summary_dirname}/regression_command.txt"

num_proc_per_gpu=$(grep -oPm 1 -- '--num_proc_per_gpu \d+' ${command_file} | grep -oZP '\d+')

#echo "Regression Command:"
#cat ${command_file}

#echo "JOBS:"
#cat $job_manifest

#echo "COMMAND:"
#cat $command_file

echo "Regression Summary Directory:"
echo ${regression_summary_dirname}
echo

# files used to summarize results
slurm_error_manifest_unique=${regression_summary_dirname}/error_manifest_slurm.txt
simulation_error_manifest=${regression_summary_dirname}/error_manifest.log
duration_successful_manifest=${regression_summary_dirname}/duration.successful
slurm_running_manifest_unique=${regression_summary_dirname}/running_manifest_slurm.txt
simulation_running_manifest=${regression_summary_dirname}/running_manifest.log

rm -f ${slurm_error_manifest_unique}
rm -f ${simulation_error_manifest}
rm -f ${duration_successful_manifest}
rm -f ${slurm_running_manifest_unique}
rm -f ${simulation_running_manifest}

# temporary files deleted at the end, no need to delete before beginning
pending_counter_file=${regression_summary_dirname}/pending
completed_counter_file=${regression_summary_dirname}/completed
slurm_error_manifest=${regression_summary_dirname}/error_manifest.slurm
slurm_running_manifest=${regression_summary_dirname}/running_manifest.slurm


logfiles=($(cat ${log_manifest}))
jobid_list=($(cat ${job_manifest}))
num_logs="${#logfiles[@]}"

test_errors=()
for (( i=0; i<$num_logs; i++ ));
do
{
    logfile=${logfiles[$i]}
    slurm_logfile=$(ls $(dirname $logfile)/*slurm)

    sbatch_command_error=`grep 'sbatch: error' ${slurm_logfile}`
    if [[ -n ${sbatch_command_error} ]]; then
        echo ${slurm_logfile} >> ${slurm_error_manifest}
        echo ${logfile} >> ${simulation_error_manifest}
        echo 1 >> ${completed_counter_file}
        continue
    fi

    if [[ -n ${num_proc_per_gpu} ]]; then
        jobid=${jobid_list[$((i/num_proc_per_gpu))]}
    else
        jobid=${jobid_list[$i]}
    fi

    job_failed=`sacct -j ${jobid} -o State -n | grep FAILED`
    if [[ -n ${job_failed} ]]; then
        echo ${slurm_logfile} >> ${slurm_error_manifest}
        echo ${logfile} >> ${simulation_error_manifest}
        echo 1 >> ${completed_counter_file}
        continue
    fi

    job_cancelled=`sacct -j ${jobid} -o State -n | grep CANCELLED`
    if [[ -n ${job_cancelled} ]]; then
        echo ${slurm_logfile} >> ${slurm_error_manifest}
        echo ${logfile} >> ${simulation_error_manifest}
        echo 1 >> ${completed_counter_file}
        continue
    fi

    job_pending=`sacct -j ${jobid} -o State -n | grep PENDING`
    if [[ -n ${job_pending} ]]; then
        echo 1 >> ${pending_counter_file}
        continue
    fi

    job_running=`sacct -j ${jobid} -o State -n | grep RUNNING`
    if [[ -n ${job_running} ]]; then
        echo ${slurm_logfile} >> ${slurm_running_manifest}
        echo ${logfile} >> ${simulation_running_manifest}
        continue
    fi

    echo 1 >> ${completed_counter_file}

    if [[ -n ${num_proc_per_gpu} ]]; then
        if [[ $((i % num_proc_per_gpu)) -eq 0 ]]; then
            simulation_duration=$(sacct -j ${jobid} -o Elapsed -np | grep -oPm 1 '^[^|]+')
            echo "${simulation_duration}" >> ${duration_successful_manifest}
        fi
    else
        simulation_duration=$(sacct -j ${jobid} -o Elapsed -np | grep -oPm 1 '^[^|]+')
        echo "${simulation_duration}" >> ${duration_successful_manifest}
    fi

}&
done
wait

running=0
if [[ -f ${simulation_running_manifest} ]]; then
    running=$(wc -l < ${simulation_running_manifest})
fi

pending=0
if [[ -f ${pending_counter_file} ]]; then
    pending=$(wc -l < ${pending_counter_file})
fi

successful=0
if [[ -f ${duration_successful_manifest} ]]; then
    if [[ -n ${num_proc_per_gpu} ]]; then
        successful=$(($(wc -l < ${duration_successful_manifest})*${num_proc_per_gpu}))
    else
        successful=$(wc -l < ${duration_successful_manifest})
    fi
fi

error=0
if [[ -f ${simulation_error_manifest} ]]; then
    errors=$(wc -l < ${simulation_error_manifest})
fi

num_completed_sims=0
if [[ -f ${completed_counter_file} ]]; then
    num_completed_sims=$(wc -l < ${completed_counter_file})
fi

if [[ -f ${slurm_running_manifest} ]]; then
    sort -u ${slurm_running_manifest} > ${slurm_running_manifest_unique}
fi

if [[ -f ${slurm_error_manifest} ]]; then
    sort -u ${slurm_error_manifest} > ${slurm_error_manifest_unique}
fi

rm -f ${pending_counter_file} ${completed_counter_file}
rm -f ${slurm_running_manifest} ${slurm_error_manifest}

if [[ ${errors} -gt 0 ]]; then
    if [[ ${num_completed_sims} -ne ${num_logs} ]]; then
        echo "REGRESSION WILL FAIL: $errors simulations have errors." >&2
        echo
        echo "Failed jobs slurm logs: ${slurm_error_manifest_unique}"
        echo "Failed simulation logs: ${simulation_error_manifest}"
        exit 1
    else
        echo "REGRESSION FAILED: $errors simulations have errors." >&2
        echo
        echo "Failed jobs slurm logs: ${slurm_error_manifest_unique}"
        echo "Failed simulation logs: ${simulation_error_manifest}"
        exit 1
    fi
else
    if [[ ${num_completed_sims} -ne ${num_logs} ]]; then
        echo "REGRESSION IN PROGRESS: ${num_completed_sims}/${num_logs} simulations complete. No errors so far."
        echo "Successful: ${successful}"
        echo "Running: ${running}"
        echo "Pending: ${pending}"
        echo
        echo "Running manifests:"
        echo "Slurm job logs: ${slurm_running_manifest_unique}"
        echo "Simulation logs: ${simulation_running_manifest}"
        exit 2
    else
        echo "REGRESSION SUCCEEDED: ${num_completed_sims}/${num_logs} simulations complete."
        echo
        echo "Job durations: ${duration_successful_manifest}"
    fi
fi