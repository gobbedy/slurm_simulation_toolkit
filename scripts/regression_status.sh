#!/bin/bash
set -o pipefail
me=$(basename ${0%%@@*})
full_me=${0%%@@*}
me_dir=$(dirname $(readlink -f ${0%%@@*}))

function die {
  err_msg="$@"
  printf "$me: %b\n" "${err_msg}" >&2
  exit 1
}

function error {
  err_msg="$@"
  errors=$(( errors + 1 ))
  printf "$me: ERROR: %b\n" "${err_msg}" >&2
}

check_epochs=''
errors=0
while [[ "$1" == -* ]]; do
  case "$1" in
    #--check_epochs)
    #  # only process first "epochs" epochs
    #  check_epochs=$2
    #  shift 2
    #;;
    -*)
      die "Invalid option $1"
    ;;
  esac
done

#if [[ -z ${check_epochs} ]]; then
#  die "must provide number of epochs via --check_epochs"
#fi

reference=$1
hash_to_find="${reference##*@}"

regression_dir=regressions
local_regressions_filename_list=(`readlink -f ${regression_dir}/*`)
declare -A local_regressions_filename_hashlist
for local_regressions_filename in "${local_regressions_filename_list[@]}"
do
    #echo $local_regressions_filename
    hash=$(echo -n `readlink -f $local_regressions_filename` | sha1sum | grep -oP '^\w{8}')
    #echo $hash
    local_regressions_filename_hashlist[$hash]=$local_regressions_filename
done

log_manifest=${local_regressions_filename_hashlist[${hash_to_find}]}
regression_name=$(basename ${log_manifest::-22})
job_manifest="${log_manifest::-9}_jobs.txt"
command_file="${log_manifest::-9}_command.txt"

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
    echo ${result_separator}
    echo "LOGFILE: $logfile"
    jobid=${jobid_list[$i]}
    num_epochs=$(grep -c "Test Acc:" ${logfile})
    job_running=`sacct -j ${jobid} -o State -n | grep RUNNING`
    if [[ -n ${job_running} ]]; then
        echo "Completed ${num_epochs} epochs (job ${jobid} still running)."
        echo ${result_separator}
        continue
    fi
    batch_size=$(grep -oP -- '--batch_size \d+' $logfile | grep -oP '\d+')
    label_dim=$(grep -oP -- '--label_dim \d+' $logfile | grep -oP '\d+')
    lam_parameters=$(grep -oP -- '--lam_parameters [\w\.]+ [\w\.]+' $logfile | grep -oP '[\w\.]+ [\w\.]+$')
    gam_parameters=$(grep -oP -- '--gamma_parameters [\w\.]+ [\w\.]+' $logfile | grep -oP '[\w\.]+ [\w\.]+$')
    dat_parameters=$(grep -oP -- '--dat_parameters [\w\.]+ [\w\.]+' $logfile | grep -oP '[\w\.]+ [\w\.]+$')
    dat_transform=$(grep -oP -- '--dat_transform' $logfile)
    no_mixup=$(grep -oP -- '--no_mixup' $logfile)
    cosine_loss=$(grep -oP -- '--cosine_loss' $logfile)
    dat=$(grep -oP -- '--directional_adversarial' $logfile)
    dataset=$(grep -oP -- '--dataset \w+' $logfile | grep -oP '\w+$')
    check_epochs=$(grep -oP -- '--epoch \d+' $logfile | grep -oP '\d+')
    if [[ ${num_epochs} -ne ${check_epochs} ]]; then
      error "Detected only ${num_epochs} out of ${check_epochs} epochs in job ${jobid}."
      echo ${result_separator}
      continue
    else
        echo "Job ${jobid} completed successfully."
    fi

    average_test_error=$(grep -oP '(?<=Test Acc: )[^%]+' ${logfile} | head -n ${num_epochs} | tail -n 10 | awk '{print 1-$1/100}' | paste -sd+ | bc | awk '{print $1*10}')
    test_errors+=(${average_test_error})

    num_completed_jobs=$(( num_completed_jobs + 1 ))

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
        echo "REGRESSION IN PROGRESS: ${num_completed_jobs}/${num_logs} simulations complete."
        exit 2
    else
        echo "REGRESSION SUCCEEDED: ${num_completed_jobs}/${num_logs} simulations complete."
    fi
fi

sum_test_error=$( IFS="+"; bc <<< "${test_errors[*]}" )
test_error_mean=$(awk "BEGIN {print ${sum_test_error}/${num_completed_jobs}; exit}")
if [[ ${num_completed_jobs} -gt 1 ]]; then
    test_error_std_dev=$(printf '%s\n' "${test_errors[@]}"  | awk "{sumsq+=(${test_error_mean}-\$1)**2}END{print sqrt(sumsq/(NR-1))}")
    std_dev_mean=$(echo "${test_error_std_dev}/sqrt(${num_processed_logs})" | bc -l)
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