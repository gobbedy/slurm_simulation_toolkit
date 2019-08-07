#!/usr/bin/env bash
source ${SLURM_SIMULATION_TOOLKIT_HOME}/config/simulation_toolkit.rc

custom_processing_functions=''
if [[ -f ${SLURM_SIMULATION_TOOLKIT_RESULTS_PROCESSING_FUNCTIONS} ]]; then
    source ${SLURM_SIMULATION_TOOLKIT_RESULTS_PROCESSING_FUNCTIONS}
    custom_processing_functions='yes'
fi

function showHelp {

echo "NAME
  $me -
     1) Report batch status (running, completed, failed)
     2) Print custom summary of results
SYNOPSIS
  $me [--ref REF | -f MANITEST]
OPTIONS
  -h, --help
                          Show this description
  --ref REF
                          REF is an 8-character hash outputted by simulation_batch.sh, which uniquely identifies a
                          specific batch.
                          The format is <cluster_name>@<hash_of_log_manifest_filename>

  -f MANIFEST
                          MANIFEST is a file containing a list of logfiles to process (one per line). Only one manifest
                          file may be provided.
"
}

reference=''
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
    log_manifest_list=(`readlink -f ${regress_dir}/*/*/batch_summary/log_manifest.txt`)
    log_manifest_list+=(`readlink -f ${regress_dir}/*/batch_summary/log_manifest.txt`)

    # legacy support
    log_manifest_list+=(`readlink -f ${regress_dir}/*/regression_summary/log_manifest.txt`)

    declare -A log_manifest_hashlist
    for current_log_manifest in "${log_manifest_list[@]}"
    do
        #echo $current_log_manifest
        hash=$(echo -n `readlink -f $current_log_manifest` | sha1sum | grep -oP '^\w{8}')
        #echo $hash
        log_manifest_hashlist[$hash]=$current_log_manifest
    done
    log_manifest=${log_manifest_hashlist[${hash_to_find}]}

    if [[ ! -f ${log_manifest} ]]; then
        die "Hash provided is invalid: ${hash_to_find}"
    fi
fi

if [[ ! -f ${log_manifest} ]]; then
    die "Please provide a valid reference or log manifest."
fi

batch_summary_dirname=$(dirname ${log_manifest})
job_manifest="${batch_summary_dirname}/job_manifest.txt"

command_file="${batch_summary_dirname}/batch_command.txt"

# legacy support
if [[ ! -f ${command_file} ]]; then
    command_file="${batch_summary_dirname}/regression_command.txt"
fi


num_proc_per_gpu=$(grep -oPm 1 -- '--num_proc_per_gpu \d+' ${command_file} | grep -oZP '\d+')


#echo "Regression Command:"
#cat ${command_file}

#echo "JOBS:"
#cat $job_manifest

#echo "COMMAND:"
#cat $command_file

echo "Batch Summary Directory:"
echo ${batch_summary_dirname}
echo

# files used to summarize results
slurm_error_manifest_unique=${batch_summary_dirname}/error_manifest_slurm.txt
simulation_error_manifest=${batch_summary_dirname}/error_manifest.txt
rm -f ${slurm_error_manifest_unique} ${simulation_error_manifest} ${simulation_error_manifest}_*

slurm_running_manifest_unique=${batch_summary_dirname}/running_manifest_slurm.txt
simulation_running_manifest=${batch_summary_dirname}/running_manifest.txt
rm -f ${slurm_running_manifest_unique} ${simulation_running_manifest}

duration_successful_manifest=${batch_summary_dirname}/durations.txt
slurm_successful_manifest_unique=${batch_summary_dirname}/successful_manifest_slurm.txt
simulation_successful_manifest=${batch_summary_dirname}/successful_manifest.txt
rm -f ${duration_successful_manifest} ${slurm_successful_manifest_unique} ${simulation_successful_manifest}

# temporary files deleted at the end, also deleted here in case script dies
pending_counter_file=${batch_summary_dirname}/pending
completed_counter_file=${batch_summary_dirname}/completed
slurm_error_manifest=${batch_summary_dirname}/error_manifest.slurm
slurm_running_manifest=${batch_summary_dirname}/running_manifest.slurm
rm -f ${pending_counter_file} ${completed_counter_file} ${slurm_error_manifest} ${slurm_running_manifest}

logfiles=($(cat ${log_manifest}))
jobid_list=($(cat ${job_manifest}))
num_logs="${#logfiles[@]}"

test_errors=()
declare -a pid_list
for (( i=0; i<$num_logs; i++ ));
do
{
    zero_padded_idx=$(printf "%05d\n" ${i})

    logfile=${logfiles[$i]}
    slurm_logfile=$(ls $(dirname $logfile)/*slurm)

    sbatch_command_error=`grep 'sbatch: error' ${slurm_logfile}`
    if [[ -n ${sbatch_command_error} ]]; then
        echo ${slurm_logfile} >> ${slurm_error_manifest}
        echo ${logfile} >> ${simulation_error_manifest}_${zero_padded_idx}
        echo 1 >> ${completed_counter_file}
        continue
    fi

    if [[ -n ${num_proc_per_gpu} ]]; then
        jobid=${jobid_list[$((i/num_proc_per_gpu))]}
    else
        jobid=${jobid_list[$i]}
    fi



    job_state=`sacct -j ${jobid} -o State -n`
    return_code=$?
    if [[ ${return_code} -ne 0 ]]; then
        die "sacct command failed. See above error."
    fi

    job_failed=`echo $job_state | grep FAILED`
    if [[ -n ${job_failed} ]]; then
        echo ${slurm_logfile} >> ${slurm_error_manifest}
        echo ${logfile} >> ${simulation_error_manifest}_${zero_padded_idx}
        echo 1 >> ${completed_counter_file}
        continue
    fi

    job_cancelled=`echo $job_state | grep CANCELLED`
    if [[ -n ${job_cancelled} ]]; then
        echo ${slurm_logfile} >> ${slurm_error_manifest}
        echo ${logfile} >> ${simulation_error_manifest}_${zero_padded_idx}
        echo 1 >> ${completed_counter_file}
        continue
    fi


    job_pending=`echo $job_state | grep PENDING`
    if [[ -n ${job_pending} ]]; then
        echo 1 >> ${pending_counter_file}
        continue
    fi

    job_running=`echo $job_state | grep RUNNING`
    if [[ -n ${job_running} ]]; then
        echo ${slurm_logfile} >> ${slurm_running_manifest}
        echo ${logfile} >> ${simulation_running_manifest}
        continue
    fi

    echo 1 >> ${completed_counter_file}

    simulation_duration=$(sacct -j ${jobid} -o Elapsed -np | grep -oPm 1 '^[^|]+')
    return_code=$?
    if [[ ${return_code} -ne 0 ]]; then
        die "sacct command failed. See above error."
    fi

    if [[ -n ${num_proc_per_gpu} ]]; then
        if [[ $((i % num_proc_per_gpu)) -eq 0 ]]; then
            echo "${simulation_duration}" >> ${duration_successful_manifest}
            echo ${slurm_logfile} >> ${slurm_successful_manifest_unique}
        fi
    else
        echo "${simulation_duration}" >> ${duration_successful_manifest}
            echo ${slurm_logfile} >> ${slurm_successful_manifest_unique}
    fi
    echo ${logfile} >> ${simulation_successful_manifest}

    if [[ -n ${custom_processing_functions} ]]; then
        process_logfile ${i} ${command_file} ${logfile} ${batch_summary_dirname}
    fi

}&
pid=$!
pid_list[$i]=$pid
done

error=0
for (( i=0; i<$num_logs; i++ ));
do
{
    pid=${pid_list[$i]}
    wait $pid
    if [[ $? -ne 0 ]]; then
        error=$((error+1))
        #pkill -P $$ # kill child processes
        #die "sacct command failed. See above error."
    fi
}
done

if [[ -n "$(ls ${simulation_error_manifest}_*)" ]]; then
    cat ${simulation_error_manifest}_* > ${simulation_error_manifest}
    rm -f ${simulation_error_manifest}_*
fi

if [[ ${error} -ne 0 ]]; then
    die "sacct failed. See above error(s)."
fi

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

errors=0
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
        echo "Pending: ${pending}"
        echo "Running: ${running}"
        echo "Successful: ${successful}"
        echo "Failed: ${errors}"
        echo
        echo "Failed jobs slurm logs: ${slurm_error_manifest_unique}"
        echo "Failed simulation logs: ${simulation_error_manifest}"
        if [[ -n ${custom_processing_functions} ]]; then
            generate_summary $command_file $batch_summary_dirname
        fi
        exit 2
    else
        echo "REGRESSION FAILED: $errors simulations have errors." >&2
        echo "Pending: ${pending}"
        echo "Running: ${running}"
        echo "Successful: ${successful}"
        echo "Failed: ${errors}"
        echo
        echo "Failed jobs slurm logs: ${slurm_error_manifest_unique}"
        echo "Failed simulation logs: ${simulation_error_manifest}"
        if [[ -n ${custom_processing_functions} ]]; then
            generate_summary $command_file $batch_summary_dirname
        fi
        exit 2
    fi
else
    if [[ ${pending} -eq ${num_logs} ]]; then
        echo "REGRESSION PENDING: All jobs still pending."
        echo "Pending: ${pending}"
        echo "Running: ${running}"
        echo "Successful: ${successful}"
        echo "Failed: ${errors}"
        exit 3
    elif [[ ${num_completed_sims} -ne ${num_logs} ]]; then
        echo "REGRESSION IN PROGRESS: ${num_completed_sims}/${num_logs} simulations complete. No errors so far."
        echo "Pending: ${pending}"
        echo "Running: ${running}"
        echo "Successful: ${successful}"
        echo "Failed: ${errors}"
        if [[ -f ${slurm_running_manifest_unique} ]]; then
            echo
            echo "Running manifests:"
            echo "Slurm job logs: ${slurm_running_manifest_unique}"
            echo "Simulation logs: ${simulation_running_manifest}"
        fi
        exit 4
    else
        echo "REGRESSION SUCCEEDED: ${num_completed_sims}/${num_logs} simulations complete."
        echo "Pending: ${pending}"
        echo "Running: ${running}"
        echo "Successful: ${successful}"
        echo "Failed: ${errors}"
        echo
        echo "Job durations: ${duration_successful_manifest}"
    fi
    if [[ -n ${custom_processing_functions} ]]; then
        generate_summary $command_file $batch_summary_dirname
    fi
fi
