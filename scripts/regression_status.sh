#!/usr/bin/env bash
source ${SLURM_SIMULATION_TOOLKIT_HOME}/config/simulation_toolkit.rc

batch_status_executable="batch_status.sh"

function showHelp {

echo "NAME
  $me -
     1) Report batch status (running, completed, failed) for each batch
     2) Print custom summary of results for each batch
SYNOPSIS
  $me [--refm REF_MANIFEST | -f LOG_MANIFEST_LISTING_FILE]
OPTIONS
  -h, --help
                          Show this description
  --refm REF_MANIFEST
                          REF_MANIFEST is a file containing a list of references (one per line). A reference is an
                          8-character hash outputted by simulation_batch.sh, which uniquely identifies a specific batch.
                          The format of each reference is <cluster_name>@<hash_of_log_manifest_filename>

  -f LOG_MANIFEST_LISTING_FILE
                          LOG_MANIFEST_LISTING_FILE is a file containing a list of logfile manifests to process (one per
                          file). Stated more succinctly, it is a manifest of log manifests.
                          Only one listing file may be provided.
"
}

echo "Processing arguments and preparing files..."
reference_manifest=''
log_manifest_listing_file=''
while [[ "$1" == -* ]]; do
  case "$1" in
    -h|--help)
      showHelp
      exit 0
    ;;
    --refm)
      reference_manifest=$2
      shift 2
    ;;
    -f)
      log_manifest_listing_file=$2
      shift 2
    ;;
    -*)
      echo "Invalid option $1"
      exit 1
    ;;
  esac
done

# check that one of the files (but not both) is provided
if [[ ( -z ${reference_manifest} ) && ( -z ${log_manifest_listing_file} ) ]]; then
    die "You must provide a log manifest list (via -f) or a reference manifest (via --refm). See --help."
fi

if [[ ( -n ${reference_manifest} ) && ( -n ${log_manifest_listing_file} ) ]]; then
    msg="You provided both a log manifest list (via -f) and a reference manifest (via --refm)."
    msg+="Please provide only one. See --help."
    die "${msg}"
fi

# check that file exists
if [[ -n ${reference_manifest} ]]; then
    if [[ ! -f ${reference_manifest} ]]; then
        die "Reference manifest (${reference_manifest}) doesn't exist."
    fi
    hash_reference_list=($(cat ${reference_manifest}))
    num_batches="${#hash_reference_list[@]}"
fi

if [[ -n ${log_manifest_listing_file} ]]; then
    if [[ ! -f ${log_manifest_listing_file} ]]; then
        die "Log manifest list (${log_manifest_listing_file}) doesn't exist."
    fi
    log_manifest_list=($(cat ${log_manifest_listing_file}))
    num_batches="${#log_manifest_list[@]}"
fi

if [[ -n ${reference_manifest} ]]; then
    regression_summary_dir=$(dirname ${reference_manifest})
elif [[ -n ${log_manifest_listing_file} ]]; then
    regression_summary_dir=$(dirname ${log_manifest_listing_file})
fi

batch_status_output_log=${regression_summary_dir}/batch_status_output.log
rm -f ${batch_status_output_log}_* ${batch_status_output_log}

failed_batch_status_out_log=${regression_summary_dir}/failed_batch_status_output.log
failed_hash_manifest=${regression_summary_dir}/failed_hash_manifest.txt
failed_manifest_list=${regression_summary_dir}/failed_manifest_list.txt
rm -f ${failed_batch_status_out_log}_* ${failed_hash_manifest}_* ${failed_manifest_list}_*
rm -f ${failed_batch_status_out_log} ${failed_hash_manifest} ${failed_manifest_list}

result_failed_batch_status_out_log=${regression_summary_dir}/result_failed_batch_status_output.log
result_failed_hash_manifest=${regression_summary_dir}/result_failed_hash_manifest.txt
result_failed_manifest_list=${regression_summary_dir}/result_failed_manifest_list.txt
rm -f ${result_failed_batch_status_out_log}_* ${result_failed_hash_manifest}_* ${result_failed_manifest_list}_*
rm -f ${result_failed_batch_status_out_log} ${result_failed_hash_manifest} ${result_failed_manifest_list}

passed_results=${regression_summary_dir}/passed_results.txt
passed_batch_status_out_log=${regression_summary_dir}/passed_batch_status_output.log
passed_hash_manifest=${regression_summary_dir}/passed_hash_manifest.txt
passed_manifest_list=${regression_summary_dir}/passed_manifest_list.txt
rm -f ${passed_results}_* ${passing_batch_status_out_log} ${passed_hash_manifest}_* ${passed_manifest_list}_*
rm -f ${passed_results} ${passed_batch_status_out_log} ${passed_hash_manifest} ${passed_manifest_list}

pending_batch_status_out_log=${regression_summary_dir}/pending_batch_status_out_log.txt
pending_hash_manifest=${regression_summary_dir}/pending_hash_manifest.txt
pending_manifest_list=${regression_summary_dir}/pending_manifest_list.txt
rm -f ${pending_batch_status_out_log}_* ${pending_hash_manifest}_* ${pending_manifest_list}_*
rm -f ${pending_batch_status_out_log} ${pending_hash_manifest} ${pending_manifest_list}

running_batch_status_out_log=${regression_summary_dir}/running_batch_status_out_log.txt
running_hash_manifest=${regression_summary_dir}/running_hash_manifest.txt
running_manifest_list=${regression_summary_dir}/running_manifest_list.txt
rm -f ${running_batch_status_out_log}_* ${running_hash_manifest}_* ${running_manifest_list}_*
rm -f ${running_batch_status_out_log} ${running_hash_manifest} ${running_manifest_list}

pending_sim_cnt_file=${regression_summary_dir}/pending_sim_cnt.txt
running_sim_cnt_file=${regression_summary_dir}/running_sim_cnt.txt
passed_sim_cnt_file=${regression_summary_dir}/passed_sim_cnt.txt
failed_sim_cnt_file=${regression_summary_dir}/failed_sim_cnt.txt
result_failed_sim_cnt_file=${regression_summary_dir}/result_failed_sim_cnt.txt
rm -f ${pending_sim_cnt_file}_* ${running_sim_cnt_file}_* ${passed_sim_cnt_file}_* ${failed_sim_cnt_file}_*
rm -f ${pending_sim_cnt_file} ${running_sim_cnt_file} ${passed_sim_cnt_file} ${failed_sim_cnt_file}
rm -f ${result_failed_sim_cnt_file}_* ${result_failed_sim_cnt_file}

running_sim_manifest=${regression_summary_dir}/running_sim_manifest.txt
passing_sim_manifest=${regression_summary_dir}/passing_sim_manifest.txt
failing_sim_manifest=${regression_summary_dir}/failing_sim_manifest.txt
result_failing_sim_manifest=${regression_summary_dir}/result_failing_sim_manifest.txt
rm -f ${running_sim_manifest}_* ${passing_sim_manifest}_* ${failing_sim_manifest}_* ${result_failing_sim_manifest}_*
rm -f ${running_sim_manifest} ${passing_sim_manifest} ${failing_sim_manifest} ${result_failing_sim_manifest}

echo "Processing Regression..."
declare -A pid_list
for (( idx=0; idx<${num_batches}; idx++ ));
do
{
    zero_padded_idx=$(printf "%05d\n" $idx) # for alphabetical ordering

    # run batch status
    batch_list_option=''
    if [[ -n ${reference_manifest} ]]; then
        batch_list_option=" --ref ${hash_reference_list[${idx}]}"
    elif [[ -n ${log_manifest_listing_file} ]]; then
        batch_list_option=" -f ${log_manifest_list[${idx}]}"
    fi
    ${batch_status_executable} ${batch_list_option} &> ${batch_status_output_log}_${zero_padded_idx}
    return_code=$?

    # batch status script failed
    num_fail=0
    while [[ ${return_code} -eq 1 ]]; do
        # retry
        echo "${batch_status_executable} failed. Retrying..."
        ${batch_status_executable} ${batch_list_option} &> ${batch_status_output_log}_${zero_padded_idx}
        return_code=$?
        if [[ ${return_code} -eq 1 ]]; then
            num_fail=$((num_fail+1))
            if [[ ${num_fail} -eq 5 ]]; then
                die "${batch_status_executable} failed. See errors in ${batch_status_output_log}_${zero_padded_idx}"
            fi
        fi
    done

    # get batch summary dir
    batch_summary_dir=$(grep -A 1 "Batch Summary Directory:" ${batch_status_output_log}_${zero_padded_idx} | tail -n1)

    if [[ -f ${batch_summary_dir}/error_manifest.txt ]]; then
        cat ${batch_summary_dir}/error_manifest.txt > ${failing_sim_manifest}_${zero_padded_idx}
    fi

    if [[ -f ${batch_summary_dir}/running_manifest.txt ]]; then
        cat ${batch_summary_dir}/running_manifest.txt > ${running_sim_manifest}_${zero_padded_idx}
    fi


    if [[ -f ${batch_summary_dir}/successful_manifest.txt ]]; then
        cat ${batch_summary_dir}/successful_manifest.txt > ${passing_sim_manifest}_${zero_padded_idx}
    fi
    # count the number of pending, running, passed, failed sims using manifests in batch summary dir
    grep "Pending:" ${batch_status_output_log}_${zero_padded_idx} | grep -oP '\d+$' > ${pending_sim_cnt_file}_${zero_padded_idx}
    grep "Running:" ${batch_status_output_log}_${zero_padded_idx} | grep -oP '\d+$' > ${running_sim_cnt_file}_${zero_padded_idx}
    grep "Failed:" ${batch_status_output_log}_${zero_padded_idx} | grep -oP '\d+$' > ${failed_sim_cnt_file}_${zero_padded_idx}
    grep "Successful:" ${batch_status_output_log}_${zero_padded_idx} | grep -oP '\d+$' > ${passed_sim_cnt_file}_${zero_padded_idx}

    # batch passed
    if [[ ${return_code} -eq 0 ]]; then
        # extract results and output them to logfile
        cp ${batch_status_output_log}_${zero_padded_idx} ${passed_batch_status_out_log}_${zero_padded_idx}
        # TODO: generalize to all users
        tail -n1 ${passed_batch_status_out_log}_${zero_padded_idx} > ${passed_results}_${zero_padded_idx}
        if [[ -n ${reference_manifest} ]]; then
            echo ${hash_reference_list[${idx}]} &> ${passed_hash_manifest}_${zero_padded_idx}
        elif [[ -n ${log_manifest_listing_file} ]]; then
            echo ${log_manifest_list[${idx}]} &> ${passed_manifest_list}_${zero_padded_idx}
        fi
    else
        echo "" > ${passed_results}_${zero_padded_idx}
        if [[ -n ${reference_manifest} ]]; then
            echo "" &> ${passed_hash_manifest}_${zero_padded_idx}
        elif [[ -n ${log_manifest_listing_file} ]]; then
            echo "" &> ${passed_manifest_list}_${zero_padded_idx}
        fi
    fi

    # failed while processing results
    if [[ ${return_code} -eq 5 ]]; then
        cp ${batch_status_output_log}_${zero_padded_idx} ${result_failed_batch_status_out_log}_${zero_padded_idx}
        if [[ -n ${reference_manifest} ]]; then
            echo ${hash_reference_list[${idx}]} &> ${result_failed_hash_manifest}_${zero_padded_idx}
        elif [[ -n ${log_manifest_listing_file} ]]; then
            echo ${log_manifest_list[${idx}]} &> ${result_failed_manifest_list}_${zero_padded_idx}
        fi
        cat ${batch_summary_dir}/successful_manifest.txt > ${result_failing_sim_manifest}_${zero_padded_idx}
        grep "Successful:" ${batch_status_output_log}_${zero_padded_idx} | grep -oP '\d+$' > ${result_failed_sim_cnt_file}_${zero_padded_idx}
        continue
    fi

    # batch failed
    if [[ ${return_code} -eq 2 ]]; then
        cp ${batch_status_output_log}_${zero_padded_idx} ${failed_batch_status_out_log}_${zero_padded_idx}
        if [[ -n ${reference_manifest} ]]; then
            echo ${hash_reference_list[${idx}]} &> ${failed_hash_manifest}_${zero_padded_idx}
        elif [[ -n ${log_manifest_listing_file} ]]; then
            echo ${log_manifest_list[${idx}]} &> ${failed_manifest_list}_${zero_padded_idx}
        fi
        continue
    fi

    # all batch jobs still pending
    if [[ ${return_code} -eq 3 ]]; then
        cp ${batch_status_output_log}_${zero_padded_idx} ${pending_batch_status_out_log}_${zero_padded_idx}
        if [[ -n ${reference_manifest} ]]; then
            echo ${hash_reference_list[${idx}]} &> ${pending_hash_manifest}_${zero_padded_idx}
        elif [[ -n ${log_manifest_listing_file} ]]; then
            echo ${log_manifest_list[${idx}]} &> ${pending_manifest_list}_${zero_padded_idx}
        fi
        continue
    fi

    # batch still running
    if [[ ${return_code} -eq 4 ]]; then
        cp ${batch_status_output_log}_${zero_padded_idx} ${running_batch_status_out_log}_${zero_padded_idx}
        if [[ -n ${reference_manifest} ]]; then
            echo ${hash_reference_list[${idx}]} &> ${running_hash_manifest}_${zero_padded_idx}
        elif [[ -n ${log_manifest_listing_file} ]]; then
            echo ${log_manifest_list[${idx}]} &> ${running_manifest_list}_${zero_padded_idx}
        fi
        continue
    fi

}&
pid=$!
pid_list[$pid]=1
done

error=0
for pid in "${!pid_list[@]}"
do
{
    wait $pid
    if [[ $? -ne 0 ]]; then
        error=$((error+1))
    fi
}
done

if [[ ${error} -ne 0 ]]; then
    die "${batch_status_executable} failed. See above error(s)."
fi

cat ${pending_sim_cnt_file}_* > ${pending_sim_cnt_file}
cat ${running_sim_cnt_file}_* > ${running_sim_cnt_file}
cat ${passed_sim_cnt_file}_* > ${passed_sim_cnt_file}
cat ${failed_sim_cnt_file}_* > ${failed_sim_cnt_file}
cat ${result_failed_sim_cnt_file}_* > ${result_failed_sim_cnt_file}
rm -f ${pending_sim_cnt_file}_* ${running_sim_cnt_file}_* ${passed_sim_cnt_file}_* ${failed_sim_cnt_file}_*
rm -f ${result_failed_sim_cnt_file}_*

pending_sims=$(paste -sd+ ${pending_sim_cnt_file} | bc)
running_sims=$(paste -sd+ ${running_sim_cnt_file} | bc)
successful_sims=$(paste -sd+ ${passed_sim_cnt_file} | bc)
failed_sims=$(paste -sd+ ${failed_sim_cnt_file} | bc)
result_failed_sims=$(paste -sd+ ${result_failed_sim_cnt_file} | bc)

rm -f ${pending_sim_cnt_file} ${running_sim_cnt_file} ${passed_sim_cnt_file} ${failed_sim_cnt_file}
rm -f ${result_failed_sim_cnt_file}

cat ${running_sim_manifest}_* > ${running_sim_manifest} 2> /dev/null
cat ${passing_sim_manifest}_* > ${passing_sim_manifest} 2> /dev/null
cat ${failing_sim_manifest}_* > ${failing_sim_manifest} 2> /dev/null
cat ${result_failing_sim_manifest}_* > ${result_failing_sim_manifest} 2> /dev/null
rm -f ${running_sim_manifest}_* ${passing_sim_manifest}_* ${failing_sim_manifest}_* ${result_failing_sim_manifest}_*

pending=0
if [[ -n $(ls ${pending_batch_status_out_log}_* 2> /dev/null) ]]; then
    if [[ -n ${reference_manifest} ]]; then
        cat ${pending_hash_manifest}_* > ${pending_hash_manifest}
        rm ${pending_hash_manifest}_*
        pending=$(wc -l < ${pending_hash_manifest})
    elif [[ -n ${log_manifest_listing_file} ]]; then
        cat ${pending_manifest_list}_* > ${pending_manifest_list}
        rm ${pending_manifest_list}_*
        pending=$(wc -l < ${pending_manifest_list})
    fi
    cat ${pending_batch_status_out_log}_* > ${pending_batch_status_out_log}
fi

running=0
if [[ -n $(ls ${running_batch_status_out_log}_* 2> /dev/null) ]]; then
    if [[ -n ${reference_manifest} ]]; then
        cat ${running_hash_manifest}_* > ${running_hash_manifest}
        rm -f ${running_hash_manifest}_*
        running=$(wc -l < ${running_hash_manifest})
    elif [[ -n ${log_manifest_listing_file} ]]; then
        cat ${running_manifest_list}_* > ${running_manifest_list}
        rm -f ${running_manifest_list}_*
        running=$(wc -l < ${running_manifest_list})
    fi
    cat ${running_batch_status_out_log}_* > ${running_batch_status_out_log}
fi

successful=0
if [[ -n $(ls ${passed_batch_status_out_log}_* 2> /dev/null) ]]; then
    if [[ -n ${reference_manifest} ]]; then
        cat ${passed_hash_manifest}_* > ${passed_hash_manifest}
        cat ${passed_results}_* > ${passed_results}
        rm -f ${passed_hash_manifest}_* ${passed_results}_*
        successful=$(grep -cve '^\s*$' < ${passed_hash_manifest})
    elif [[ -n ${log_manifest_listing_file} ]]; then
        cat ${passed_manifest_list}_* > ${passed_manifest_list}
        cat ${passed_results}_* > ${passed_results}
        rm -f ${passed_manifest_list}_* ${passed_results}_*
        successful=$(grep -cve '^\s*$' < ${passed_manifest_list})
    fi
    cat ${passed_batch_status_out_log}_* > ${passed_batch_status_out_log}
fi

failed=0
if [[ -n $(ls ${failed_batch_status_out_log}_* 2> /dev/null) ]]; then
    if [[ -n ${reference_manifest} ]]; then
        cat ${failed_hash_manifest}_* > ${failed_hash_manifest}
        rm -f ${failed_hash_manifest}_*
        failed=$(wc -l < ${failed_hash_manifest})
    elif [[ -n ${log_manifest_listing_file} ]]; then
        cat ${failed_manifest_list}_* > ${failed_manifest_list}
        rm -f ${failed_manifest_list}_*
        failed=$(wc -l < ${failed_manifest_list})
    fi
    cat ${failed_batch_status_out_log}_* > ${failed_batch_status_out_log}
fi

result_failed=0
if [[ -n $(ls ${result_failed_batch_status_out_log}_* 2> /dev/null) ]]; then
    if [[ -n ${reference_manifest} ]]; then
        cat ${result_failed_hash_manifest}_* > ${result_failed_hash_manifest}
        rm -f ${result_failed_hash_manifest}_*
        result_failed=$(wc -l < ${result_failed_hash_manifest})
    elif [[ -n ${log_manifest_listing_file} ]]; then
        cat ${result_failed_manifest_list}_* > ${result_failed_manifest_list}
        rm -f ${result_failed_manifest_list}_*
        result_failed=$(wc -l < ${result_failed_manifest_list})
    fi
    cat ${result_failed_batch_status_out_log}_* > ${result_failed_batch_status_out_log}
fi

cat ${batch_status_output_log}_* > ${batch_status_output_log}
rm -f ${batch_status_output_log}_* ${pending_batch_status_out_log}_* ${running_batch_status_out_log}_*
rm -f ${passed_batch_status_out_log}_* ${failed_batch_status_out_log}_* ${result_failed_batch_status_out_log}_*

echo "REGRESSION SUMMARY DIR: ${regression_summary_dir}"
echo "----------------------------------------------------------------------------------------------"
echo "BATCHES:"
echo "PENDING: ${pending}"
echo "RUNNING: ${running}"
echo "PASSED: ${successful}"
echo "FAILED: ${failed}"
echo "RESULT FAILED: ${result_failed}"
if [[ ${running} -gt 0 ]]; then
    if [[ -n ${reference_manifest} ]]; then
        echo "HASHES OF RUNNING BATCHES: ${running_hash_manifest}"
    elif [[ -n ${log_manifest_listing_file} ]]; then
        echo "MANIFESTS OF RUNNING BATCHES: ${running_manifest_list}"
    fi
fi
if [[ ${successful} -gt 0 ]]; then
    if [[ -n ${reference_manifest} ]]; then
        echo "HASHES OF PASSED BATCHES: ${passed_hash_manifest}"
    elif [[ -n ${log_manifest_listing_file} ]]; then
        echo "MANIFESTS OF PASSED BATCHES: ${passed_manifest_list}"
    fi
    echo "RESULTS OF PASSED BATCHES: ${passed_results}"
fi
if [[ ${failed} -gt 0 ]]; then
    if [[ -n ${reference_manifest} ]]; then
        echo "HASHES OF FAILED BATCHES: ${failed_hash_manifest}"
    elif [[ -n ${log_manifest_listing_file} ]]; then
        echo "MANIFESTS OF FAILED BATCHES: ${failed_manifest_list}"
    fi
fi
if [[ ${result_failed} -gt 0 ]]; then
    if [[ -n ${reference_manifest} ]]; then
        echo "HASHES OF FAILED BATCHES: ${result_failed_hash_manifest}"
    elif [[ -n ${log_manifest_listing_file} ]]; then
        echo "MANIFESTS OF FAILED BATCHES: ${result_failed_manifest_list}"
    fi
fi

echo "----------------------------------------------------------------------------------------------"
echo "SIMULATIONS:"
echo "PENDING: ${pending_sims}"
echo "RUNNING: ${running_sims}"
echo "PASSED: ${successful_sims}"
echo "FAILED: ${failed_sims}"
echo "RESULT FAILED (double counts passed/failed): ${result_failed_sims}"
if [[ ${running_sims} -gt 0 ]]; then
    echo "MANIFEST OF RUNNING SIMS: ${running_sim_manifest}"
fi
if [[ ${successful_sims} -gt 0 ]]; then
    echo "MANIFEST OF PASSED SIMS: ${passing_sim_manifest}"
fi
if [[ ${failed_sims} -gt 0 ]]; then
    echo "MANIFEST OF FAILED SIMS: ${failing_sim_manifest}"
fi
if [[ ${result_failed_sims} -gt 0 ]]; then
    echo "MANIFEST OF RESULT-FAILED SIMS: ${result_failing_sim_manifest}"
fi
echo "----------------------------------------------------------------------------------------------"