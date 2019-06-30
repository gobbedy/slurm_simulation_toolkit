function process_logfile {
    command_file=$1
    logfile=$2
    output_dir=$3 # regression summary dir

    test_errors_manifest=${output_dir}/test_errors.txt
    average_test_error=$(grep -oP '(?<=Test Acc: )[^%]+' ${logfile} | tail -n 10 | awk '{print 1-$1/100}' | paste -sd+ | bc | awk '{print $1*10}')
    echo ${average_test_error} >> ${test_errors_manifest}
}

function generate_summary {
    command_file=$1
    output_dir=$2 # regression summary dir
    test_errors_manifest=${output_dir}/test_errors.txt

    batch_size=$(grep -oPm 1 -- '--batch_size \d+' ${command_file} | grep -oZP '\d+')
    label_dim=$(grep -oPm 1 -- '--label_dim \d+' ${command_file} | grep -oZP '\d+')
    lam_parameters=$(grep -oPm 1 -- '--lam_parameters [\w\.]+ [\w\.]+' ${command_file} | grep -oZP '[\w\.]+ [\w\.]+$')
    gam_parameters=$(grep -oPm 1 -- '--gamma_parameters [\w\.]+ [\w\.]+' ${command_file} | grep -oZP '[\w\.]+ [\w\.]+$')
    dat_parameters=$(grep -oPm 1 -- '--dat_parameters [\w\.]+ [\w\.]+' ${command_file} | grep -oZP '[\w\.]+ [\w\.]+$')
    dat_transform=$(grep -oZPm 1 -- '--dat_transform' ${command_file})
    no_mixup=$(grep -oZPm 1 -- '--no_mixup' ${command_file})
    cosine_loss=$(grep -oPm 1 -- '--cosine_loss' ${command_file})
    dat=$(grep -oZPm 1 -- '--directional_adversarial' ${command_file})
    dataset=$(grep -oPm 1 -- '--dataset \w+' ${command_file} | grep -oZP '\w+$')
    epochs=$(grep -oPm 1 -- '--epoch \d+' ${command_file} | grep -oZP '\d+')

    test_errors=($(cat ${test_errors_manifest}))
    rm -f ${test_errors_manifest}
    sum_test_error=$( IFS="+"; bc <<< "${test_errors[*]}" )
    test_error_mean=$(awk "BEGIN {print ${sum_test_error}/${num_completed_sims}; exit}")
    if [[ ${num_completed_sims} -gt 1 ]]; then
        test_error_std_dev=$(printf '%s\n' "${test_errors[@]}"  | awk "{sumsq+=(${test_error_mean}-\$1)**2}END{print sqrt(sumsq/(NR-1))}")
        if [[ "${test_error_std_dev}" == 0 ]]; then
            die "ERROR: Standard deviation is 0. Did all simulations use the same seed?"
        fi
        std_dev_mean=$(echo "${test_error_std_dev}/sqrt(${num_completed_sims})" | bc -l)
    else
        std_dev_mean="N/A"
    fi

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
        if [ "${dat_parameters}" == "3.0 1.0" ] || [ "${dat_parameters}" == "3 1" ] ; then
            sim_type="MIXUP ${loss} (UNIFORM/SANITY)"
        else
            sim_type="UNTIED ${loss} (DT)"
        fi
        lam_parameters="N/A"
        gam_parameters="N/A"
    else
        if [ "${gam_parameters}" == "1.0 1.0" ] || [ "${gam_parameters}" == "1 1" ] ; then
            if [ "${lam_parameters}" == "1.0 1.0" ] || [ "${lam_parameters}" == "1 1" ] ; then
                sim_type="MIXUP ${loss} (UNIFORM/SANITY)"
            else
                sim_type="MIXUP ${loss}"
            fi
        else
            sim_type="UNTIED ${loss} (GS)"
        fi
        dat_parameters="N/A"
    fi

    echo "${sim_type}, ${dataset}, ${test_error_mean}%, ${std_dev_mean}, ${lam_parameters}, ${gam_parameters}, ${dat_parameters}, ${epochs}, ${num_completed_sims}, ${batch_size}, ${reference}, ${log_manifest}"
}