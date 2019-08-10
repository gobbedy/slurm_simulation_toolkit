#!/usr/bin/env bash
source ${SLURM_SIMULATION_TOOLKIT_HOME}/config/simulation_toolkit.rc
datetime_suffix=$(date +%b%d_%H%M%S)

# TODO: MUST ALSO UPDATED THE JOB NUMBERS MANIFEST SO THAT BATCH_STATUS WILL WORK!!
# AKA UPDATE THIS job_manifest="${batch_summary_dirname}/job_manifest.txt"

function showHelp {

echo "NAME
  $me -
     Relaunch failed simulations.

SYNOPSIS
  $me [-f MANIFEST | -l MANIFEST_LIST] [OPTIONS]

OPTIONS
  -h, --help
                          Show this description

  -f MANIFEST
                          MANIFEST is a file containing a list of logfiles to process. Only one manifest file may be
                          provided.

  -l MANIFEST_LIST
                          MANIFEST_LIST is a file containing a list of manifests (one per line). Only one manifest list
                          file may be provided.

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
  --preserve_order
                          Simulations will be run in the same order as they appear in REGRESN_CTRL.

                          Similarly to the --max_jobs_in_parallel option, this comes at a price on systems using a
                          fairshare policy. The age factor of pending jobs will not change as long as the previous
                          job has not begun.

                          This can have a BIG impact on job pending times, so use with caution.

                          Order is not preserved by default.

"
}

manifest_list=()
manifest_list_file=''
max_jobs_in_parallel=''
preserve_order=''
while [[ "$1" == -* ]]; do
  case "$1" in
    -h|--help)
      showHelp
      exit 0
    ;;
     -f)
      manifest_list+=($2)
      shift 2
    ;;
    -l)
      manifest_list_file=$2
      shift 2
    ;;
    --max_jobs_in_parallel)
      max_jobs_in_parallel=$2
      shift 2
    ;;
    --preserve_order)
      preserve_order='yes'
      shift 1
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

if [[ -n ${manifest_list_file} ]]; then
    manifest_list+=($(cat ${manifest_list_file}))
    regress_summary_dir=$(dirname ${manifest_list_file})
else
    regress_summary_dir=$PWD
fi
new_jobs_manifest=${regress_summary_dir}/new_job_manifest.txt
rm -f ${new_jobs_manifest}

unset pid_list
declare -A pid_list
start=`date +%s`
echo "Relaunching failed jobs..."
for batch_manifest in "${manifest_list[@]}"
do
{
    #echo ""
    echo "Processing ${batch_manifest}..."
    parent_dir=$(dirname ${batch_manifest})
    batch_cmd_file="${parent_dir}/batch_command.txt"
    batch_cmd=$(cat ${batch_cmd_file})
    num_proc_per_gpu=$(grep -oP -- '--num_proc_per_gpu \K\d+' ${batch_cmd_file})
    if [[ -z ${num_proc_per_gpu} ]]; then
      num_proc_per_gpu=1
    fi

    # get number of failed sims (aka number of simulations to run now)
    num_simulations=$(batch_status.sh -f $batch_manifest |& grep -oP 'Failed: \K\d+')
    if [[ ${num_simulations} -eq 0 ]]; then
        #echo "No failures. Skipping..."
        continue
    fi
    #echo "Relaunching ${num_simulations} failed simulations..."

    # check if simulations timed out
    # get failed sim seeds
    fail_manifest=${parent_dir}/error_manifest.txt
    seed_list_str=''
    seed_found=''
    for file in `cat $fail_manifest`; do
        seed_list_str+=","
        seed=''
        if [[ -f ${file} ]]; then
            #seed=$(grep -oPhm 1 'seed \K\d+' ${file})
            seed=$(grep -oPm 1 'SEED \K\d+' ${file})
            seed_found='yes'
        fi
        #seed=$(grep -oPh 'SEED \K\d+' ${file})
        seed_list_str+=$seed
    done
    seed_list_str=${seed_list_str:1}

#    slurm_fail_manifest=${parent_dir}/error_manifest_slurm.txt
#    checkpoint_list_str=''
#    for slurm_logfile in `cat $slurm_fail_manifest`; do
#        checkpoint_list_str+=","
#        sim_dir=$(dirname ${slurm_logfile})
#        time_limit_reached=$(grep 'DUE TO TIME LIMIT' ${slurm_logfile})
#        checkpoints=''
#        if [[ -n ${time_limit_reached} ]]; then
#            checkpoints=$(ls ${sim_dir}/*checkpoint* | tr [:space:] ',')
#        else
#            checkpoints=$(printf ',%.0s' $(seq 1 $num_proc_per_gpu))
#        fi
#        if [[ -n ${checkpoints} ]]; then
#            checkpoints=${checkpoints::-1}
#        fi
#        checkpoint_list_str+=${checkpoints}
#    done
#    checkpoint_list_str=${checkpoint_list_str:1}

    #slurm_fail_manifest=${parent_dir}/error_manifest_slurm.txt
    checkpoint_list_str=''
    time_limit_failure=''
    for file in `cat $fail_manifest`; do
        checkpoint_list_str+=","
        sim_dir=$(dirname ${file})
        slurm_logfile=${sim_dir}/*.slurm
        time_limit_reached=$(grep 'DUE TO TIME LIMIT' ${slurm_logfile})
        checkpoint=''
        if [[ -n ${time_limit_reached} ]]; then
            seed=$(grep -oPm 1 'SEED \K\d+' ${file})
            checkpoint=${sim_dir}/checkpoint_${seed}.torch
            time_limit_failure='yes'
        fi
        checkpoint_list_str+=${checkpoint}
    done
    checkpoint_list_str=${checkpoint_list_str:1}

    # escape forward slashes for upcoming sed expression
    checkpoint_list_str=$(echo $checkpoint_list_str  | sed -e 's/\//\\\//g')

    new_args="--num_simulations ${num_simulations}"
    if [[ ${seed_found} ]]; then
      new_args+=" --seeds ${seed_list_str}"
    fi
    if [[ ${time_limit_failure} ]]; then
      new_args+=" --checkpoints ${checkpoint_list_str}"
    fi

    # replace --num_simulations with appriopriate $num_simulations
    new_batch_cmd=$(echo "${batch_cmd}" | sed -e "s/--num_simulations [0-9]\+/${new_args}/g")

    # remove --hold
    #new_batch_cmd=${new_batch_cmd//--hold/}

    # launch new regression
    eval "${new_batch_cmd}" > ${parent_dir}/summary.log

    # get new manifest
    new_manifest=$(grep -oP 'SIMULATION LOGS MANIFEST: \K.+' ${parent_dir}/summary.log)

    fail_list=($(cat $fail_manifest))
    new_list=($(cat $new_manifest))
    for (( i=0; i<${num_simulations}; i++ ));
    do
    {
        fail_log=${fail_list[$i]}
        new_log=${new_list[$i]}


        old_sim_dir=$(dirname ${fail_log})
        old_slurm_logfile=${old_sim_dir}/*.slurm
        time_limit_reached=$(grep 'DUE TO TIME LIMIT' ${old_slurm_logfile})
        if [[ -n ${time_limit_reached} ]]; then
            # copy fail_log until the last "Checkpoint Saving" to new_log
            checkpoint_line=$(grep -n 'Checkpoint Saving' ${fail_log} | tail -1 | grep -oP '^\d+')
            sed -n "1,${checkpoint_line}p" ${fail_log} > ${new_log}
        fi
    }
    done

    # get original job manifest
    original_job_manifest="${parent_dir}/job_manifest.txt"

    # name for new concatenated manifest
    composed_manifest="${batch_manifest%.*}_FULL.txt"

    # name for new job manifest
    composed_job_manifest="${original_job_manifest%.*}_FULL.txt"

    # get new job manifest
    new_job_manifest=$(grep -oP 'JOB IDs FILE IN: \K.+' ${parent_dir}/summary.log)
    cat ${new_job_manifest} >> ${new_jobs_manifest}

    # get non-fail job manifest of original batch
    exclude_list=($(grep -F -x -n -f ${fail_manifest} ${batch_manifest} | cut -f1 -d:))

    sed_exclude_option=`printf '%sd;' "${exclude_list[@]}"`
    sed -e ${sed_exclude_option} ${batch_manifest} > ${parent_dir}/non_fail_manifest.txt

    if [[ -s ${parent_dir}/non_fail_manifest.txt ]]; then
      grep -hoP 'Submitted batch job \K.+' $(sed 's/_proc_[0-9]\+\.log/.slurm/' ${parent_dir}/non_fail_manifest.txt | sort -u) > ${parent_dir}/non_fail_job_manifest.txt
      # cat batch_manifest and new manifest into new file
      cat ${parent_dir}/non_fail_manifest.txt ${new_manifest} > ${composed_manifest}

    else
      cp ${new_manifest} ${composed_manifest}
    fi

    if [[ -s ${parent_dir}/non_fail_job_manifest.txt ]]; then
      # cat original (successful) job manifest and new job manifest into new file
      cat ${parent_dir}/non_fail_job_manifest.txt ${new_job_manifest} > ${composed_job_manifest}
    else
      cp ${new_job_manifest} ${composed_job_manifest}
    fi

    # keep the original job manifest
    mv ${original_job_manifest} ${original_job_manifest}.old_${datetime_suffix}

    # keep the original manifest
    mv ${batch_manifest} ${batch_manifest}.old_${datetime_suffix}

    # replace the old job manifest with the new one
    mv ${composed_job_manifest} ${original_job_manifest}

    # replace the old manifest with the new one
    mv ${composed_manifest} ${batch_manifest}

    #echo "UPDATED MANIFEST:"
    #echo ${batch_manifest}

    #echo "UPDATED JOB MANIFEST:"
    #echo ${original_job_manifest}

    rm -f ${parent_dir}/summary.log ${parent_dir}/non_fail_job_manifest.txt ${parent_dir}/non_fail_manifest.txt
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
    die "Job relaunching failed. See above error(s)."
fi


end=`date +%s`
runtime=$((end-start))
echo "Relauching took $runtime seconds"
echo ""

unset pid_list
declare -A pid_list
start=`date +%s`
echo "Releasing jobs..."

if [[ ! -f ${new_jobs_manifest} ]]; then
  die "No jobs to release. Are you sure there are any failed simulations to relaunch?"
fi

job_id_list=($(cat ${new_jobs_manifest}))
for (( idx=0; idx<${#job_id_list[@]}; idx++ ));
do
{
    job_id=${job_id_list[${idx}]}
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
        scontrol update jobid=${job_id} ${dependency_option}
    fi
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
echo ""


rm ${new_jobs_manifest}