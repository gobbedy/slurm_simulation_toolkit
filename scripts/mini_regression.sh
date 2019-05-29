#!/bin/bash
set -o pipefail
me=$(basename ${0%%@@*})
full_me=${0%%@@*}
me_dir=$(dirname $(readlink -f ${0%%@@*}))

input_command="${me} $@"

echo "RUNNING:"
echo "${input_command}"
echo ""

function die {
  err_msg="$@"
  printf "$me: %b\n" "${err_msg}" >&2
  exit 1
}

dat_parameters='2.0 1.0'
lam_parameters='1.0 1.0'
#num_proc_per_gpu=1
cosine_loss=''
num_simulations=12
singleton=''
dat_transform='no'
dataset='cifar10'
label_dim=300
time="0-4:00:00"
mixup='yes'
batch_size=128
epochs=200
while [[ "$1" == -* ]]; do
  case "$1" in
    #--num_proc_per_gpu)
    #  num_proc_per_gpu=$2
    #  shift 2
    #;;
    --label_dim)
      cosine_loss=1
      label_dim=$2
      shift 2
    ;;
    --singleton)
      singleton=1
      shift 1
    ;;
    --no_mixup)
      mixup='no'
      shift 1
    ;;
    --dat_parameters)
      dat_transform='yes'
      dat_parameters="$2 $3"
      shift 3
    ;;
    --lam_parameters)
      lam_parameters="$2 $3"
      shift 3
    ;;
    --num_simulations)
      num_simulations=$2
      shift 2
    ;;
    --epochs)
      epochs=$2
      shift 2
    ;;
    --time)
      time=$2
      shift 2
    ;;
    --dataset)
      dataset=$2
      shift 2
    ;;
    --batch_size)
      batch_size=$2
      shift 2
    ;;
    -*)
      echo "Invalid option $1"
      exit 1
    ;;
  esac
done

#regression_name=$1
run_dir=`dirname $me_dir`
regression_dir=$run_dir/regressions
export PATH=$me_dir:$PATH

checkpoint_location=/home/gobbedy/projects/def-yymao/gobbedy/regress/mixup_paper/directional_Apr26_140114/checkpoint.torch


directional_adversarial=no # yes=directional_adversarial, no=mixup
#dataset='cifar10'

if [[ ${directional_adversarial} == "yes" ]]; then

    #time="0-4:00:00"
    gam_parameters="1.0 1.0"
    #epochs=800
    large_gpu=no #Helios option only for now (large:24GB; regular:5GB
    checkpoint=no

    #seed='' # empty string -> randomized seed
    use_random_seed=yes
    starting_lr=0.1

    # "WEIRD" options
    normalize=yes # sanity=yes
    learning_rate='' # sanity=sanity; decay=decay; empty string=drop at 40/100

    BASELINE=no
    if [[ ${BASELINE} == 'yes' ]]; then
        iid_sampling=no
        one_lambda_per_batch=yes # sanity=no
        stratified_sampling=no
    else
        iid_sampling=yes
        one_lambda_per_batch=no # sanity=no
        stratified_sampling=no
    fi

else
    # This should basically always stay "1 1" unless we decide to do an untied mixup sweep in the mixup domain
    gam_parameters="1.0 1.0"

    large_gpu=no #Helios option only for now (large:24GB; regular:5GB
    checkpoint=no


    use_random_seed=yes
    starting_lr=0.1


    # "WEIRD" options
    normalize=yes # sanity=yes
    learning_rate='' # sanity=sanity; decay=decay; empty string=drop at 40/100

    # BASELINE means run exactly as original authors ran it (with lambda from uniform distribution)
    BASELINE=no
    if [[ ${BASELINE} == 'yes' ]]; then
        iid_sampling=no
        one_lambda_per_batch=yes # sanity=no
        stratified_sampling=no
    else
        iid_sampling=yes
        one_lambda_per_batch=no # sanity=no
        stratified_sampling=no
    fi
fi

dataset_upercase=$(echo ${dataset} | awk '{ print toupper($0) }')

if [[ ${dat_transform} == "yes" ]]; then
    dat_param_arr=($(echo "$dat_parameters" | tr '.' '_'))
    regression_name="DAT_TRANSFORM_${dataset_upercase}_${dat_param_arr[0]}_${dat_param_arr[1]}"
else
    lam_param_arr=($(echo "$lam_parameters" | tr '.' '_'))
    regression_name="MIXUP_${dataset_upercase}_${lam_param_arr[0]}_${lam_param_arr[1]}"
fi

datetime_suffix=$(date +%b%d_%H%M%S)
regression_name=${regression_name}_${datetime_suffix}

regression_command_file=${regression_dir}/${regression_name}_command.txt
regression_logname_file=${regression_dir}/${regression_name}_logs.txt
regression_job_numbers_file=${regression_dir}/${regression_name}_jobs.txt

node_prefix=$(hostname | cut -c1-3)
num_proc_per_gpu=1
if [[ $node_prefix == "hel" ]]; then
   local_cluster=helios
elif [[ $node_prefix == "del" ]]; then
   local_cluster=beihang
   num_proc_per_gpu=2
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

hash=$(echo -n `readlink -f $regression_logname_file` | sha1sum | grep -oP '^\w{8}')
reference="${local_cluster}@${hash}"

if (( $num_simulations % $num_proc_per_gpu )) ; then
  die "$num_simulations not divisible by $num_proc_per_gpu"
fi

num_jobs=$(echo $((num_simulations / num_proc_per_gpu)))

node_prefix=$(hostname | cut -c1-3)
job_script_executable="simulation.sh"

if [[ $node_prefix == "ced" ]]; then
    account="rrg-yymao"
    #account="def-yymao"
else
    account="def-yymao"
fi

job_script_options="--lr ${starting_lr} --dat_parameters ${dat_parameters} --gamma_parameters ${gam_parameters} --lam_parameters ${lam_parameters}"
job_script_options+=" --account ${account} --epochs ${epochs} --num_proc_per_gpu ${num_proc_per_gpu} --label_dim ${label_dim}"

if [[ -n ${cosine_loss} ]]; then
    job_script_options+=" --cosine_loss"
fi

if [[ $node_prefix == "hel" ]]; then
    if [[ ${large_gpu} == yes ]]; then
      job_script_options+=" --large_gpu"
    fi
fi

if [[ ${dat_transform} == "yes" ]]; then
  job_script_options+=" --dat_transform"
fi

if [[ ${checkpoint} == "yes" ]]; then
    job_script_options+=" --checkpoint ${checkpoint_location}"
fi

if [[ ${stratified_sampling} == "yes" ]]; then
    job_script_options+=" --stratified_sampling"
fi

if [[ ${directional_adversarial} == "yes" ]]; then
  job_script_options+=' --directional_adversarial'
elif [[ ${mixup} == "yes" ]]; then
  job_script_options+=' --mixup'
fi

if [[ ${one_lambda_per_batch} == "yes" ]]; then
    job_script_options+=" --one_lambda_per_batch"
fi

if [[ ${learning_rate} == "sanity" ]]; then
    job_script_options+=" --sanity_learning_rate"
elif [[ ${learning_rate} == "decay" ]]; then
    job_script_options+=" --decay_learning_rate"
fi

if [[ ${normalize} == "yes" ]]; then
  job_script_options+=' --normalize'
fi

if [[ ${iid_sampling} == "yes" ]]; then
  job_script_options+=' --iid_sampling'
fi

# create regression dir if doesn't exist
if [[ ! -d ${regression_dir} ]]; then
  mkdir ${regression_dir}
fi

echo "${input_command}" > ${regression_command_file}

for (( i=0; i<$num_jobs; i++ ));
do

   seed_option=''
   if [[ "${use_random_seed}" == "no" ]]; then
     seed_option="--seed ${i}"
   fi

   wait_for_job_option=''
   if [[ "${#blocking_jobs[@]}" -gt 0 ]]; then
     wait_for_job_option="--wait_for_job ${blocking_jobs[$i]}"
   fi
   
   job_name='dat'
   singleton_option=''
   if [[ -n ${singleton} ]]; then
        last_singleton_id=`cat ${regression_dir}/singleton_id.txt`
        singleton_id=$(((last_singleton_id+1) % 30))
        echo ${singleton_id} > ${regression_dir}/singleton_id.txt
        job_name+="_${singleton_id}"
        singleton_option='--singleton'
   fi

   ${job_script_executable} ${job_script_options} ${seed_option} ${wait_for_job_option} ${singleton_option} --job_name ${job_name} --time ${time} --batch_size ${batch_size} --dataset ${dataset} |tee tmp_output.log

   if [[ $node_prefix == "hel" ]]; then
       prolog_file=$(grep -oP '(?<=-o )[^ ]+' tmp_output.log)
       job_number=$(grep -oP '^\d+$' tmp_output.log)
   else
       prolog_file=$(grep -oP '(?<=--output=)[^ ]+' tmp_output.log)
       job_number=$(grep "Submitted" tmp_output.log | grep -oP '\d+$')
   fi
   rm tmp_output.log

   for (( j=0; j<$num_proc_per_gpu; j++ )); do
      prolog_dirname=`dirname $prolog_file`
      prolog_basename=`basename $prolog_file`
      gpu_number=${j}
      log_basename="${prolog_basename%.*}_proc_${gpu_number}.log"
      logfile=$prolog_dirname/${log_basename}
      echo ${logfile} >> ${regression_logname_file}
   done

   echo ${job_number} >> ${regression_job_numbers_file}
done

echo ""

echo "JOB NUMBERS CONTAINED IN:"
readlink -f ${regression_job_numbers_file}
echo ""

echo "LOGFILE NAMES CONTAINED IN:"
readlink -f ${regression_logname_file}
echo ""

echo "REGRESSION COMMAND CONTAINED IN:"
readlink -f ${regression_command_file}
echo ""

echo "HASH REFERENCE:"
echo $reference