#!/bin/bash
set -o pipefail
me=$(basename ${0%%@@*})
full_me=${0%%@@*}
#set -e

function die {
  err_msg="$@"
  printf "$me: %b\n" "${err_msg}" >&2
  exit 1
}

original_options=$@

######### HELPER VARIABLES AND FUNCTIONS ################

############## PROCESS INPUTS ############
logfiles=()
exclude_list=()
generate_curves=''
email_results=''
regression_name=''
one_pdf=''
one_graph=''
cluster=''
manifest_file=''
epochs='' # by default, prints all results
print_individual_results=yes
print_train_losses=no
histogram=''
check_epochs=''
while [[ "$1" == -* ]]; do
  case "$1" in
    -l)
      logfiles+=($2)
      shift 2
    ;;
    -e)
      exclude_list+=($2)
      shift 2
    ;;
    --cluster)
      cluster=$2
      shift 2
    ;;
    -f)
      manifest_file=$2
      shift 2
    ;;
    --no_individual)
      print_individual_results=no
      shift 1
    ;;
    --histogram)
      histogram=yes
      shift 1
    ;;
    --train_losses)
      print_train_losses=yes
      shift 1
    ;;
    -c)
      generate_curves=1
      shift 1
    ;;
    -m)
      email_results=1
      shift 1
    ;;
    --one_pdf)
      one_pdf=1
      generate_curves=1
      shift 1
    ;;
    --epochs)
      # only process first "epochs" epochs
      epochs=$2
      shift 2
    ;;
    --check_epochs)
      # only process first "epochs" epochs
      check_epochs=$2
      shift 2
    ;;
    --one_graph)
      one_graph=1
      shift 1
    ;;
    -n)
      regression_name=$2
      shift 2
      if [[ -z ${regression_name} ]]; then
          echo "ERROR: empty regression name"
          exit 1
      fi
    ;;
	# START CHANGES HERE
	# END CHANGES HERE
    -*)
      echo "Invalid option $1"
      exit 1
    ;;
  esac
done

# which lines to remove
sed_exclude_option=`printf '%sd;' "${exclude_list[@]}"`

################## SETUP REMOTE LOGIN ####################
node_prefix=$(hostname | cut -c1-3)
if [[ $node_prefix == "hel" ]]; then
   local_cluster=helios
elif [[ $node_prefix == "nia" ]]; then
   local_cluster=niagara
elif [[ $node_prefix == "bel" ]]; then
   local_cluster=beluga
   # beluga doesn't support mailing, so need to use cedar
   ssh_mail_node="gobbedy@cedar.computecanada.ca"
   ssh $ssh_mail_node "bash -s" -- < $full_me $original_options
   exit
elif [[ $node_prefix == "ced" ]]; then
   local_cluster=cedar
elif [[ $node_prefix == "del" ]]; then
   local_cluster=beihang
elif [[ $node_prefix == "gra" ]]; then
   local_cluster=graham
else
   echo "ERROR: local cluster prefix \"${node_prefix}\" unrecognized"
   exit 1
fi

if [[ -n ${cluster} ]]; then
    if [[ $cluster == $local_cluster ]]; then
        echo "WARNING: IGNORING CLUSTER OPTION since ${cluster} is local"
        # setting cluster to empty string skips grabbing stuff via ssh
        cluster=''
    fi
fi

if [[ -n ${cluster} ]]; then

    if [[ ${cluster} == "beluga" ]]; then
        cluster_url=${cluster}.computecanada.ca
    elif [[ ${cluster} == "cedar" ]]; then
        cluster_url=${cluster}.computecanada.ca
    elif [[ ${cluster} == "graham" ]]; then
        cluster_url=${cluster}.computecanada.ca
    elif [[ ${cluster} == "helios" ]]; then
        cluster_url=${cluster}.calculquebec.ca
    elif [[ ${cluster} == "niagara" ]]; then
        cluster_url=${cluster}.computecanada.ca
    else
        echo "ERROR: unknown/supported cluster: ${cluster}"
        exit 1
    fi

    mnt_parent_dir=~/mnt
    if [[ ! -d ${mnt_parent_dir} ]]; then
        mkdir ${mnt_parent_dir}
    fi

    mnt_dir=${mnt_parent_dir}/${cluster}

    # unmount if already mounted or badly mounted
    fusermount -u ${mnt_dir} 2> /dev/null

    sleep 1

    # create if doesn't already exist
    #rm -rf ${mnt_dir}
    mkdir ${mnt_dir} 2> /dev/null

    # now finally, mount
    sshfs -o allow_other -o follow_symlinks -o ssh_command="ssh -i ~/.ssh/id_rsa" gobbedy@${cluster_url}:/ ${mnt_dir}

    # prepend mnt_dir to manifest file
    if [[ -n ${manifest_file} ]]; then
        manifest_file="${mnt_dir}${manifest_file}"
        #cat ${manifest_file}
        logfiles+=($(cat ${manifest_file}))
    fi

    # prepend mnt_dir to each logfile
    logfiles=( "${logfiles[@]/#/${mnt_dir}}" )

else
    if [[ -n ${manifest_file} ]]; then
        logfiles+=($(cat ${manifest_file}))
    fi
fi

if [[ -n ${exclude_list} ]]; then
    sed_exclude_option=`printf '%sd;' "${exclude_list[@]}"`
    logfiles=($(printf '%s\n' "${logfiles[@]}" | sed -e ${sed_exclude_option}))
fi

num_logs="${#logfiles[@]}"
if [[ ${num_logs} -gt 1 ]]; then
  if [[ -z ${regression_name} ]]; then
    if [[ -n ${manifest_file} ]]; then
        log_basename=`basename ${manifest_file}`
        regression_name=${log_basename::-9}
    else
        echo "ERROR: regression name not provided (use -n NAME)"
        exit 1
    fi
  fi
else
  if [[ -z ${regression_name} ]]; then
    # use parent directory as regression name for single logfile
    regression_name=$(basename $(dirname "${logfiles[@]}"))
  fi
fi

############### SETUP VARIABLES #####################
mailx_executable="/usr/bin/mailx"
results_dir=$PWD/results
output_dir=${results_dir}/${regression_name}
processed_results_log=${output_dir}/${regression_name}_processed.txt
global_tex_output_dir=${output_dir}/${regression_name}_tex

################## PROCESS LOGFILES ####################

# create results dir if doesn't exist
if [[ ! -d ${results_dir} ]]; then
  mkdir ${results_dir}
fi

# remove output dir if it already exists, and create new one
rm -rf ${output_dir}
mkdir ${output_dir}

# create a tex output dir for all tex files
mkdir ${global_tex_output_dir}

# prepare tex names if generating a single pdf for the whole regression
if [[ -n ${one_pdf} ]]; then
    global_tikz_texfile=${global_tex_output_dir}/tikz_${regression_name}.tex
    global_texfile=${global_tex_output_dir}/${regression_name}.tex
    # generated pdf will have same name as texfile
    global_pdf_file=${global_tex_output_dir}/${regression_name}.pdf
fi

sum_test_error=0
sum_train_loss=0
test_errors=()
train_losses=()
email_appends=''
num_processed_logs=0
total_simulation_seconds=0
for logfile in "${logfiles[@]}"
do

    echo "PROCESSING: ${logfile}" |tee -a ${processed_results_log}

    # show last 10 test accuracies
    #echo "LAST 10:" |tee -a ${processed_results_log}
    #grep -oP "Test Acc:.+%" ${logfile} | tail -n 10 |tee -a ${processed_results_log}


    # show total number of epochs for this sim
    #echo "EPOCHS:"  |tee -a ${processed_results_log}
    if [[ -n ${epochs} ]]; then
        num_epochs=${epochs} # "head -n -0" for all lines
    else
        num_epochs=$(grep -c "Test Acc:" ${logfile})
    fi
    if [[ -n ${check_epochs} ]]; then
        if [[ ${num_epochs} -ne ${check_epochs} ]]; then
          echo "WARNING: Detected only ${num_epochs} epochs. SKIPPING." >&2
          continue
        fi
    fi
    echo "EPOCHS: ${num_epochs}"  |tee -a ${processed_results_log}

    simulation_seconds=$(grep "Simulation Duration" ${logfile} | grep -oP '[\d:]+$' | awk -F: '{ print ($1 * 3600) + ($2 * 60) + $3 }')

    # show average of last 10 test accuracies
    average_test_error=$(grep -oP '(?<=Test Acc: )[^%]+' ${logfile} | head -n ${num_epochs} | tail -n 10 | awk '{print 1-$1/100}' | paste -sd+ | bc | awk '{print $1*10}')
    if [[ ${print_individual_results} == "yes" ]]; then
        echo "AVG TEST ERROR OF LAST 10 EPOCHS:"  |tee -a ${processed_results_log}
        if [[ -z ${average_test_error} ]]; then
          echo "ERROR: no validation errors found for above logfile"
          exit 1
        fi
        echo ${average_test_error}%  |tee -a ${processed_results_log}
    fi

    # show average of last 10 train losses
    average_train_loss=$(grep -oP '(?<=Train Loss: )[^ ]+' ${logfile} | head -n ${num_epochs} | tail -n 10 | awk '{print $1}' | paste -sd+ | bc | awk '{print $1/10}')
    if [[ ${print_individual_results} == "yes" ]]; then
        if [[ ${print_train_losses} == "yes" ]]; then
            echo "AVG TRAIN LOSS OF LAST 10 EPOCHS:"  |tee -a ${processed_results_log}
            if [[ -z ${average_train_loss} ]]; then
              echo "ERROR: no train losses found for above logfile"
              exit 1
            fi
            echo ${average_train_loss} |tee -a ${processed_results_log}
        fi
    fi

    echo "" |tee -a ${processed_results_log}

    # keep running sum of average test errors over all sims
    sum_test_error=$(echo $sum_test_error + $average_test_error | bc)

    # keep running sum of average train losses over all sims
    sum_train_loss=$(echo $sum_train_loss + $average_train_loss | bc)

    # keep list of (separate) test errors for all sims
    test_errors+=(${average_test_error})
    test_errors_str+=(${average_test_error}%)

    # keep list of (separate) train losses for all sims
    train_losses+=(${average_train_loss})

    # get parent directory basename
    parent_dir_basename=$(basename $(dirname ${logfile}))

    # remove datetime suffix (last 13 characters) and use this as simulation name
    #simulation_name=${parent_dir_basename::-13}
    if [[ $logfile == *train_* ]]; then
        simulation_name=`basename $logfile | grep -oP '\d\d\d'`
        #log_basename=${log_basename::-4}
        #simulation_name=762
    else
        simulation_name=${parent_dir_basename::-13}
    fi

    # print all training losses to file
    #grep -oP '(?<=Train Loss: )[^ ]+' ${logfile} > ${simulation_name}_train.txt

    if [[ -n ${generate_curves} ]]; then
        # store all training losses in array
        train_loss_array=($(grep -oP '(?<=Train Loss: )[^ ]+' ${logfile} | head -n ${num_epochs}))

        # get train loss vs epoch coordinates string, eg "(0,1.20)(1,1.13)(2,0.96)(3,0.88)"
        # also get max and min train loss
        train_loss_coordinates_string=""
        min_train_loss=10000
        max_train_loss=0

        for (( idx=0; idx<"${#train_loss_array[@]}"; idx++ ))
        do
            epoch=$((idx + 1))
            train_loss_array="${train_loss_array[${idx}]}"
            train_loss_coordinates_string+="("
            train_loss_coordinates_string+="${epoch}"
            train_loss_coordinates_string+=","
            train_loss_coordinates_string+="${train_loss_array}"
            train_loss_coordinates_string+=")"

            if (( $(echo "${train_loss_array} > ${max_train_loss}" |bc -l) )); then
                max_train_loss="${train_loss_array}"
            fi

            if (( $(echo "${train_loss_array} < ${min_train_loss}" |bc -l) )); then
                min_train_loss="${train_loss_array}"
            fi
        done

        # store all test errors in array
        test_error_array=($(grep -oP '(?<=Test Acc: )[^%]+' ${logfile} | awk '{print 1-$1/100}' | head -n ${num_epochs}))

        # get test error vs epoch coordinates string, eg "(0,1.20)(1,1.13)(2,0.96)(3,0.88)"
        # also get max and min test error
        test_error_coordinates_string=""
        min_test_error=10000
        max_test_error=0
        for (( idx=0; idx<"${#test_error_array[@]}"; idx++ ))
        do
            epoch=$((idx + 1))
            test_error="${test_error_array[${idx}]}"
            test_error_coordinates_string+="("
            test_error_coordinates_string+="${epoch}"
            test_error_coordinates_string+=","
            test_error_coordinates_string+="${test_error}"
            test_error_coordinates_string+=")"

            if (( $(echo "${test_error} > ${max_test_error}" |bc -l) )); then
                max_test_error="${test_error}"
            fi

            if (( $(echo "${test_error} < ${min_test_error}" |bc -l) )); then
                min_test_error="${test_error}"
            fi
        done
        # create output directory for tex output files
        tex_output_dir=${global_tex_output_dir}/${simulation_name}_tex
        rm -rf ${tex_output_dir}
        mkdir ${tex_output_dir}

        # create name for input tex file
        tex_file=${tex_output_dir}/plots_${simulation_name}.tex

        # name for tikspicture template file (to be fed into tex file)
        tikz_tex_file=${tex_output_dir}/tikz_${simulation_name}.tex

        # generated pdf will have same name as texfile
        pdf_file=${tex_output_dir}/plots_${simulation_name}.pdf

        # replace template's COORDINATES with actual coordinates string
        sed -e "s/COORDINATES_TRAIN_LOSS/${train_loss_coordinates_string}/g" tex_templates/tikzpicture_template.tex > ${tikz_tex_file}
        sed -i "s/COORDINATES_TEST_ERROR/${test_error_coordinates_string}/g" ${tikz_tex_file}

        # replace template tex's SIMULATION_NAME with actual simulation name

        # replace "_" with "\_" to make tex happy
        # magicm basically explains why I need a million backslahes here: https://www.linuxquestions.org/questions/slackware-14/sed-command-to-replace-slash-with-backslash-136312/
        simulation_name_tex=${simulation_name//_/\\\\\\_}
        sed -i "s/SIMULATION_NAME/${simulation_name_tex}/g" ${tikz_tex_file}

        # replace template tex's SIMULATION_NAME with actual simulation name
        regression_name_tex=${regression_name//_/\\\\\\_}
        sed -i "s/REGRESSION_NAME/${regression_name_tex}/g" ${tikz_tex_file}

        # replace template tex's EPOCHS with actual number of epochs
        sed -i "s/EPOCHS/${num_epochs}/g" ${tikz_tex_file}

        # set min and max for y coordinates
        y_min_train_loss=$(awk "BEGIN {print ${min_train_loss}*0.9; exit}")
        y_max_train_loss=$(awk "BEGIN {print ${max_train_loss}*1.1; exit}")
        y_min_test_error=$(awk "BEGIN {print ${min_test_error}*0.9; exit}")
        y_max_test_error=$(awk "BEGIN {print ${max_test_error}*1.1; exit}")

        # generate y_ticks string
        num_y_ticks=4
        y_ticks_train_loss=''
        for (( idx=0; idx<"${num_y_ticks}"; idx++ ))
        do
            y_ticks_train_loss+=$(awk "BEGIN {print ${min_train_loss} + (${max_train_loss} - ${min_train_loss})*${idx}/(${num_y_ticks}-1); exit}")
            if [[ ${idx} -lt $((num_y_ticks-1)) ]]; then
                y_ticks_train_loss+=","
            fi
        done

        y_ticks_test_error=''
        for (( idx=0; idx<"${num_y_ticks}"; idx++ ))
        do
            y_ticks_test_error+=$(awk "BEGIN {print ${min_test_error} + (${max_test_error} - ${min_test_error})*${idx}/(${num_y_ticks}-1); exit}")
            if [[ ${idx} -lt $((num_y_ticks-1)) ]]; then
                y_ticks_test_error+=","
            fi
        done

        # replace template tex's YMIN with actual minimum training loss
        sed -i "s/YMIN_TRAIN_LOSS/${y_min_train_loss}/g" ${tikz_tex_file}
        sed -i "s/YMIN_TEST_ERROR/${y_min_test_error}/g" ${tikz_tex_file}

        # replace template tex's YMAX with actual maximum training loss
        sed -i "s/YMAX_TRAIN_LOSS/${y_max_train_loss}/g" ${tikz_tex_file}
        sed -i "s/YMAX_TEST_ERROR/${y_max_test_error}/g" ${tikz_tex_file}

        # replace template tex's Y_TICKS with desired ticks
        sed -i "s/Y_TICKS_TRAIN_LOSS/${y_ticks_train_loss}/g" ${tikz_tex_file}
        sed -i "s/Y_TICKS_TEST_ERROR/${y_ticks_test_error}/g" ${tikz_tex_file}

        if [[ -n ${one_pdf} ]]; then
            printf "\n\n" >> ${tikz_tex_file}
            cat ${tikz_tex_file} >> ${global_tikz_texfile}
        else
            # replace TIKZPICTURES in train_loss template with the contents of ${tikz_tex_file}
            # credit: https://stackoverflow.com/a/34070185/8112889
            sed -e "/TIKSZPICTURES/r ${tikz_tex_file}" -e "/TIKSZPICTURES/d" tex_templates/plots_template.tex > ${tex_file}

            # generate training loss graph pdf from texfile
            pdflatex -synctex=1 -interaction=nonstopmode -output-directory ${tex_output_dir} ${tex_file} > ${tex_output_dir}/pdflatex.log
            pdflatex_return=$?

            if [[ ${pdflatex_return} -ne 0 ]]; then
              echo "ERROR: pdflatex failed with exit code: ""${pdflatex_return}"". See logfile:"
              echo ${tex_output_dir}/pdflatex.log
              exit 1
            fi

            if [[ -n ${email_results} ]]; then
                email_appends+=" -a ${pdf_file}"
            fi
        fi
    fi
    num_processed_logs=$(( num_processed_logs + 1 ))
    total_simulation_seconds=$(( simulation_seconds + total_simulation_seconds ))
done

if [[ -n ${one_pdf} ]]; then
    sed -e "/TIKSZPICTURES/r ${global_tikz_texfile}" -e "/TIKSZPICTURES/d" tex_templates/plots_template.tex > ${global_texfile}

    # generate training loss graph pdf from texfile
    pdflatex -synctex=1 -interaction=nonstopmode -output-directory ${global_tex_output_dir} ${global_texfile} > ${global_tex_output_dir}/pdflatex.log
    pdflatex_return=$?

    if [[ ${pdflatex_return} -ne 0 ]]; then
      echo "ERROR: pdflatex failed with exit code: ""${pdflatex_return}"". See logfile:"
      echo ${global_tex_output_dir}/pdflatex.log
      exit 1
    fi

    if [[ -n ${email_results} ]]; then
        email_appends+=" -a ${global_pdf_file}"
    fi
fi


round()
{
echo $(printf %.$2f $(echo "scale=$2;(((10^$2)*$1)+0.5)/(10^$2)" | bc))
};

floor()
{
echo $(printf %.$2f $(echo "scale=$2;(((10^$2)*$1))/(10^$2)" | bc))
};

ceil()
{
echo $(printf %.$2f $(echo "scale=$2;(((10^$2)*$1)+1)/(10^$2)" | bc))
};

if [[ ${num_processed_logs} -gt 1 ]]; then
    test_error_mean=$(awk "BEGIN {print ${sum_test_error}/${num_processed_logs}; exit}"  |tee -a ${processed_results_log})
    test_error_std_dev=$(printf '%s\n' "${test_errors[@]}"  | awk "{sumsq+=(${test_error_mean}-\$1)**2}END{print sqrt(sumsq/(NR-1))}")
    std_dev_mean=$(echo "${test_error_std_dev}/sqrt(${num_processed_logs})" | bc -l)
    confidence_interval=$(echo "${std_dev_mean} * 2" | bc -l | grep -oP '.*\.\d{6}')

    if [[ -n ${histogram} ]]; then
      test_errors_file=${global_tex_output_dir}/test_errors.txt
      test_error_histogram_texfile=${global_tex_output_dir}/test_error_histogram_${regression_name}.tex
      global_histogram_pdf_file=${global_tex_output_dir}/test_error_histogram_${regression_name}.pdf

      min_test_error=$(echo "${test_errors[*]}" | tr ' ' '\n' | awk 'NR==1{min=$0}NR>1 && $1<min{min=$1;pos=NR}END{print min}')
      max_test_error=$(echo "${test_errors[*]}" | tr ' ' '\n' | awk 'NR==1{max=0}NR>1 && $1>max{max=$1;pos=NR}END{print max}')
      min_test_error_floor=$(floor ${min_test_error} 1)
      max_test_error_ceil=$(ceil ${max_test_error} 1)
      #echo $test_error_mean
      #echo $test_error_std_dev
      #echo $min_test_error
      #echo $max_test_error
      #echo $min_test_error_floor
      #echo $max_test_error_ceil

      printf '%s\n' "${test_errors[@]}" > ${test_errors_file}

      sed -e "/TEST_ERROR_LIST/r ${test_errors_file}" -e "/TEST_ERROR_LIST/d" tex_templates/histogram_template.tex > ${test_error_histogram_texfile}

      sed -i "s/MIN_BUCKET_EDGE/${min_test_error_floor}/g" ${test_error_histogram_texfile}
      sed -i "s/MAX_BUCKET_EDGE/${max_test_error_ceil}/g" ${test_error_histogram_texfile}
      sed -i "s/TEST_ERROR_MEAN/${test_error_mean}/g" ${test_error_histogram_texfile}
      sed -i "s/TEST_ERROR_STDV/${test_error_std_dev}/g" ${test_error_histogram_texfile}

      # generate training loss graph pdf from texfile
      pdflatex -synctex=1 -interaction=nonstopmode -output-directory ${global_tex_output_dir} ${test_error_histogram_texfile} > ${global_tex_output_dir}/histogram_pdflatex.log
      pdflatex_return=$?

      if [[ ${pdflatex_return} -ne 0 ]]; then
        echo "ERROR: pdflatex failed with exit code: ""${pdflatex_return}"". See logfile:"
        echo ${global_tex_output_dir}/histogram_pdflatex.log
        exit 1
      fi

      if [[ -n ${email_results} ]]; then
        email_appends+=" -a ${global_histogram_pdf_file}"
      fi

    fi

    echo "AVG TEST ERROR OF ALL SIMULATIONS +- 95% CONFIDENCE (2*stdv)"  |tee -a ${processed_results_log}
    avg_test_error=$(awk "BEGIN {print ${sum_test_error}/${num_processed_logs}; exit}"  |tee -a ${processed_results_log})
    avg_test_error_str="${avg_test_error}%"
    echo "${avg_test_error_str},${confidence_interval},${num_processed_logs}" |tee -a ${processed_results_log}
    if [[ ${num_processed_logs} -ne ${num_logs} ]]; then
        echo "WARNING: only processed ${num_processed_logs} of ${num_logs} logs"
    fi

    if [[ ${print_train_losses} == "yes" ]]; then
        echo "AVG TRAIN LOSS OF ALL SIMULATIONS (LAST 10 EPOCHS)"  |tee -a ${processed_results_log}
        avg_train_loss=$(awk "BEGIN {print ${sum_train_loss}/${num_processed_logs}; exit}"  |tee -a ${processed_results_log})
        echo $avg_train_loss |tee -a ${processed_results_log}
    fi

    if [[ ${print_individual_results} == "yes" ]]; then
        echo "INDIVIDUAL SIMULATION TEST ERRORS"  |tee -a ${processed_results_log}
        function join_by { local IFS=", "; echo "$*"; }
        #join_by "${test_errors_str[@]}"  | tee -a ${processed_results_log}
        echo ${test_errors_str[@]}
        echo "For Excel, avg followed by individual:"
        echo $avg_test_error_str
        printf '%s\n' "${test_errors_str[@]}"
        if [[ ${print_train_losses} == "yes" ]]; then
            echo "INDIVIDUAL SIMULATION TRAIN LOSSES"  |tee -a ${processed_results_log}
            #join_by "${train_losses[@]}"  |tee -a ${processed_results_log}
            echo ${train_losses[@]}
            echo "For Excel, avg followed by individual:"
            echo $avg_train_loss
            printf '%s\n' "${train_losses[@]}"
        fi
    fi
fi

avg_simulation_time=$(( total_simulation_seconds / num_processed_logs ))
echo "AVERAGE SIMULATION TIME"
echo $total_simulation_seconds
printf '%dh:%dm:%ds\n' $(($avg_simulation_time/3600)) $(($avg_simulation_time%3600/60)) $(($avg_simulation_time%60))

if [[ -n ${email_results} ]]; then
  subject="REGRESSION RESULTS: ${regression_name}"
  cat ${processed_results_log} | ${mailx_executable} ${email_appends} -s "$(echo -e "${subject}")" ${EMAIL}
fi