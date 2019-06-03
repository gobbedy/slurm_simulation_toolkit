#!/usr/bin/env bash
source ${SLURM_SIMULATION_TOOLKIT_RC}

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

regression_summary_dir=${SLURM_SIMULATION_REGRESS_DIR}/regression_summary
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
#result_separator="------------------------------------------------------------------------------------------------------------------"
result_separator=`printf %125s |tr " " "-"`
num_completed_jobs=0

#for logfile in "${logfiles[@]}"
test_errors=()
for (( i=0; i<$num_logs; i++ ));
do
    logfile=${logfiles[$i]}
    slurm_logfile=$(ls $(dirname $logfile)/*slurm)

    batch_size=$(grep -oPm 1 -- '--batch_size \d+' $slurm_logfile | grep -oZP '\d+')
    label_dim=$(grep -oPm 1 -- '--label_dim \d+' $slurm_logfile | grep -oZP '\d+')
    lam_parameters=$(grep -oPm 1 -- '--lam_parameters [\w\.]+ [\w\.]+' $slurm_logfile | grep -oZP '[\w\.]+ [\w\.]+$')
    gam_parameters=$(grep -oPm 1 -- '--gamma_parameters [\w\.]+ [\w\.]+' $slurm_logfile | grep -oZP '[\w\.]+ [\w\.]+$')
    dat_parameters=$(grep -oPm 1 -- '--dat_parameters [\w\.]+ [\w\.]+' $slurm_logfile | grep -oZP '[\w\.]+ [\w\.]+$')
    dat_transform=$(grep -oZPm 1 -- '--dat_transform' $slurm_logfile)
    no_mixup=$(grep -oZPm 1 -- '--no_mixup' $slurm_logfile)
    cosine_loss=$(grep -oPm 1 -- '--cosine_loss' $slurm_logfile)
    dat=$(grep -oZPm 1 -- '--directional_adversarial' $slurm_logfile)
    dataset=$(grep -oPm 1 -- '--dataset \w+' $slurm_logfile | grep -oZP '\w+$')
    check_epochs=$(grep -oPm 1 -- '--epoch \d+' $slurm_logfile | grep -oZP '\d+')
    num_cpus=$(grep -oPm 1 -- '--ntasks=\d+' $slurm_logfile | grep -oZP '\d+')

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
        error "Job ${jobid} completed but failed. Check ${slurm_logfile}"
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

    num_epochs=$(grep -c "Test Acc:" ${logfile})
    job_running=`sacct -j ${jobid} -o State -n | grep RUNNING`
    if [[ -n ${job_running} ]]; then
        echo "Completed ${num_epochs} out of ${check_epochs} epochs (job ${jobid} still running)."
        echo ${result_separator}
        continue
    fi

    num_completed_jobs=$(( num_completed_jobs + 1 ))

    echo "EPOCHS:"
    echo $num_epochs
    if [[ ${num_epochs} -ne ${check_epochs} ]]; then
      error "Detected only ${num_epochs} out of ${check_epochs} epochs in job ${jobid}."
      echo ${result_separator}
      continue
    else
        echo "Job ${jobid} completed successfully."
        simulation_seconds=$(grep "Simulation Duration" ${logfile} | grep -oP '[\d:]+$' | awk -F: '{ print ($1 * 3600) + ($2 * 60) + $3 }')
        echo "Used ${num_cpus}"
        echo "Duration ${simulation_seconds} seconds"
    fi

    average_test_error=$(grep -oP '(?<=Test Acc: )[^%]+' ${logfile} | head -n ${num_epochs} | tail -n 10 | awk '{print 1-$1/100}' | paste -sd+ | bc | awk '{print $1*10}')
    test_errors+=(${average_test_error})

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

sum_test_error=$( IFS="+"; bc <<< "${test_errors[*]}" )
test_error_mean=$(awk "BEGIN {print ${sum_test_error}/${num_completed_jobs}; exit}")
if [[ ${num_completed_jobs} -gt 1 ]]; then
    test_error_std_dev=$(printf '%s\n' "${test_errors[@]}"  | awk "{sumsq+=(${test_error_mean}-\$1)**2}END{print sqrt(sumsq/(NR-1))}")
    if [[ "${test_error_std_dev}" == 0 ]]; then
        die "ERROR: Standard deviation is 0. Did all simulations use the same seed?"
    fi
    std_dev_mean=$(echo "${test_error_std_dev}/sqrt(${num_processed_logs})" | bc -l)
    echo C
else
    std_dev_mean="N/A"
fi

# TODO: add lam_params, dat_param, gam_params (use N/A if relevant)
echo $lam_parameters
echo $gam_parameters
echo $dat_parameters
if [[ -n ${cosine_loss} ]]; then
  loss="NC ($label_dim)"
else
  loss="CE"
fi

if [[ -n ${dat} ]]; then
    sim_type="DAT ${loss}"
    lam_parameters="N/A"
    gam_parameters="N/A"
elif [[ -n ${no_mixup} ]]; then
    sim_type="BASELINE ${loss}"
    lam_parameters="N/A"
    gam_parameters="N/A"
    dat_parameters="N/A"
elif [[ -n ${dat_transform} ]]; then
    # if dat_params 2 1, mixup -- TECHNICALLY OTHER dat_params CAN BE MIXUP BUT UNLIKELY
    if [ ${dat_parameters} == "3.0 1.0" ] || [ ${dat_parameters} == "3 1" ] ; then
        sim_type="MIXUP ${loss} (UNIFORM/SANITY)"
    else
        sim_type="UNTIED ${loss} (DT)"
    fi
    lam_parameters="N/A"
    gam_parameters="N/A"
else
    if [ ${gam_parameters} == "1.0 1.0" ] || [ ${gam_parameters} == "1 1" ] ; then
        if [ ${lam_parameters} == "1.0 1.0" ] || [ ${lam_parameters} == "1 1" ] ; then
            sim_type="MIXUP ${loss} (UNIFORM/SANITY)"
        else
            sim_type="MIXUP ${loss}"
        fi
    else
        sim_type="UNTIED ${loss} (GS)"
    fi
    dat_parameters="N/A"
fi

echo "${sim_type}, ${dataset}, ${test_error_mean}%, ${std_dev_mean}, ${lam_parameters}, ${gam_parameters}, ${dat_parameters}, ${check_epochs}, ${num_completed_jobs}, ${batch_size}, ${reference}, ${log_manifest}"