#!/bin/bash
set -o pipefail
me=$(basename ${0%%@@*})
full_me=${0%%@@*}
me_dir=$(dirname $(readlink -f ${0%%@@*}))

############################################################################################################
######### HELPER VARIABLES AND FUNCTIONS -- DO NOT CHANGE UNLESS YOU KNOW WHAT YOU'RE DOING ################
############################################################################################################

# if one of the commands in a pipe (eg slurm.sh call at end of script) fails, the entire command returns non-zero code
# otherwise only the return code of last command would be returned regardless if some earlier commands in the pipe failed
set -o pipefail

# name of this script (simulation.sh)
me=$(basename ${0%%@@*})

# full path to this script, ie /path/to/simulation.sh
full_me=${0%%@@*}

# parent directory of this script, ie /path/to
me_dir=$(dirname $(readlink -f ${0%%@@*}))

# regression directory -- root directory where all simulations will go!
node_prefix=$(hostname | cut -c1-3)
if [[ $node_prefix == "hel" ]]; then
   local_cluster=helios
elif [[ $node_prefix == "del" ]]; then
   local_cluster=beihang
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


if [[ $local_cluster == "helios" ]]; then
    regress_dir=/home/${USER}/projects/regress
elif [[ $local_cluster == "niagara" ]]; then
    #regress_dir=/home/y/yymao/${USER}/regress
    # on niagara, only scratch disk is writable by compute nodes
    regress_dir=/scratch/y/yymao/gobbedy/regress
elif [[ $local_cluster == "beihang" ]]; then
    regress_dir=/home/LAB/kongfs/gobbedy/regress
else
    regress_dir=/home/${USER}/projects/def-yymao/gobbedy/regress
fi

# datetime suffix, eg if we are November 14th, 6:56AM and 1 second -- datetime suffix is Nov14_065601
# will be used later to autogenerate a unique output directory
datetime_suffix=$(date +%b%d_%H%M%S_%3N)

# exit elegantly
function die {
  err_msg="$@"
  printf "$me: %b\n" "${err_msg}" >&2
  exit 1
}

# Usage: info "string message"
function info
{
  printf "${me}: INFO - %s\n" "$@"
}

############################################################################################################
######################################### PARSE ARGUMENTS ##################################################
###################################### YOU MUST CHANGE THIS!!! #############################################
############################################################################################################

function showHelp {

echo "NAME - DESCRIPTION

  $me -
     1) Creates output (regression) directory
     2) Launches SLURM job

SYNOPSIS

  $me [OPTIONS]

OPTIONS

  -h, --help
                          Show this description
  --seed
                          Simulation seed. (Default to random if not provided)
  --mixup
                          Mix the pixel-embedded images
"
}

# parse arguments to be ultimately passed down to python script
# START CHANGES HERE
# END CHANGES HERE

seed=''
mixup=''
stratified_sampling=''
normalize=''
epochs=800
num_proc_per_gpu=1
time="0-02:00:00"
account=rrg-mao
batch_size=128
label_dim=300
directional_adversarial=''
sanity_learning_rate=''
decay_learning_rate=''
iid_sampling=''
one_lambda_per_batch=''
dat_parameters='2.0 1.0'
gamma_parameters='1.0 1.0'
lam_parameters='1.0 1.0'
lr=0.1
dataset=cifar10
dat_transform=''
cosine_loss=''
blocking_job_id=''
singleton=''
job_name=''

while [[ "$1" == -* ]]; do
  case "$1" in
    -h|--help)
      showHelp
      exit 0
    ;;
    --account)
      account=$2
      shift 2
    ;;
    --job_name)
      job_name=$2
      shift 2
    ;;
    --num_proc_per_gpu)
      num_proc_per_gpu=$2
      shift 2
    ;;
    --epochs)
      epochs=$2
      shift 2
    ;;
    --checkpoint)
      checkpoint_location=$2
      shift 2
    ;;
    --singleton)
      singleton=1
      shift 1
    ;;
    --time)
      time=$2
      shift 2
    ;;
    -s|--seed)
      seed=$2
      shift 2
    ;;
    --dataset)
      dataset=$2
      shift 2
    ;;
    --lr)
      lr=$2
      shift 2
    ;;
    --mixup)
      mixup=1
      shift 1
    ;;
    --cosine_loss)
      cosine_loss=1
      shift 1
    ;;
    --stratified_sampling)
      stratified_sampling=1
      shift 1
    ;;
    --normalize)
      normalize=1
      shift 1
    ;;
    --one_lambda_per_batch)
      one_lambda_per_batch=1
      shift 1
    ;;
    --sanity_learning_rate)
      sanity_learning_rate=1
      shift 1
    ;;
    --decay_learning_rate)
      decay_learning_rate=1
      shift 1
    ;;
    --iid_sampling)
      iid_sampling=1
      shift 1
    ;;
    --dat_transform)
      dat_transform=1
      shift 1
    ;;
    --directional_adversarial)
      directional_adversarial=1
      shift 1
    ;;
    --batch_size)
      batch_size=$2
      shift 2
    ;;
    --label_dim)
      label_dim=$2
      shift 2
    ;;
    --dat_parameters)
      dat_parameters="$2 $3"
      shift 3
    ;;
    --gamma_parameters)
      gamma_parameters="$2 $3"
      shift 3
    ;;
    --lam_parameters)
      lam_parameters="$2 $3"
      shift 3
    ;;
    --wait_for_job)
      blocking_job_id=$2
      shift 2
    ;;
	# START CHANGES HERE
	# END CHANGES HERE
    -*)
      die "Invalid option $1"
    ;;
  esac
done


# START CHANGES HERE
# Check that arguments are valid.

# END CHANGES HERE

############################################################################################################
####################### SIMULATION PARAMETERS -- YOU MUST CHANGE THESE!!! ##################################
############################################################################################################

# simulation parameters
gpus=1
node_prefix=$(hostname | cut -c1-3)
if [[ $node_prefix == ip* ]]; then
    # mammouth
    time="2-00:00:00"
    nodes=1
    cpus=24
    mem=256gb
elif [[ $node_prefix == "ced" ]]; then
    if [[ ${gpus} == 0 ]]; then
        time="1-00:00:00"
        nodes=1
        cpus=32
        mem=257000M
    else
        nodes=1
        cpus=6
        mem=3200M
    fi
elif [[ $node_prefix == "del" ]]; then
    if [[ ${gpus} == 0 ]]; then
        time="1-00:00:00"
        nodes=1
        cpus=32
        mem=257000M
    else
        nodes=1
        cpus=10
        mem=''
    fi
elif [[ $node_prefix == "gra" ]]; then
    if [[ ${gpus} == 0 ]]; then
        time="1-00:00:00"
        nodes=1
        cpus=32
        mem=128000M
    else
        nodes=1
        cpus=16
        mem=63759M
    fi
elif [[ $node_prefix == "bel" ]]; then
    if [[ ${gpus} == 0 ]]; then
        account=rrg-yymao
        time="1-00:00:00"
        nodes=1
        cpus=40
        mem=191000M
    else
        nodes=1
        cpus=10
        mem=47750M
    fi
elif [[ $node_prefix == "nia" ]]; then
    time="1-00:00:00"
    nodes=1
    cpus=80
    gpus=0
    mem=100G
fi

#time="24:00:00" # hours:minutes:seconds
#time="2-00:00:00"
# TIME IS NOW SET VIA COMMAND LINE OPTION
email=no
test_mode=no

if [[ -z ${job_name} ]]; then
    job_name="directional_simulation"
fi
  #account=def-yymao
# ACCOUNT IS NOW SET VIA COMMAND LINE OPTION

# your e-mail address is used by slurm.sh to e-mail you at start + end of simulation
# if you don't want an e-mail, set email=no above
#export EMAIL=youremail@uottawa.ca

# directory where simulation output will reside -- to be autogenerated
# change the end of it should always be beneath ${regress_dir} !!
output_dir=${regress_dir}/mixup_paper/directional_${datetime_suffix}


# name of python script to be executed -- assumed to reside in current directory
# NOTE: This script will be copied to the output directory and the COPIED version will be executed
#       This allows you to continue working and not worry about when SLURM will launch your script.
python_script_name="train.py"

# options to be passed into python script
python_options="--epoch ${epochs} --lr ${lr} --batch_size ${batch_size} --dat_parameters ${dat_parameters}"
python_options+=" --dataset ${dataset}  --gamma_parameters ${gamma_parameters} --lam_parameters ${lam_parameters}"
python_options+=" --label_dim ${label_dim}"

if [[ -z ${mixup} ]]; then
    python_options+=" --no_mixup"
fi

if [[ -n ${stratified_sampling} ]]; then
    python_options+=" --stratified_sampling"
fi

if [[ -z ${normalize} ]]; then
    python_options+=" --no_normalize"
fi

if [[ -n ${directional_adversarial} ]]; then
    python_options+=" --directional_adversarial"
fi

if [[ -n ${cosine_loss} ]]; then
    python_options+=" --cosine_loss"
fi

if [[ -n ${one_lambda_per_batch} ]]; then
    python_options+=" --one_lambda_per_batch"
fi

if [[ -n ${sanity_learning_rate} ]]; then
    python_options+=" --sanity_learning_rate"
fi

if [[ -n ${decay_learning_rate} ]]; then
    python_options+=" --decay_learning_rate"
fi

if [[ -n ${iid_sampling} ]]; then
    python_options+=" --iid_sampling"
fi

if [[ -n ${dat_transform} ]]; then
    python_options+=" --dat_transform"
fi

if [[ -n ${checkpoint_location} ]]; then
    python_options+=" --checkpoint ${checkpoint_location}"
fi

if [[ -n ${seed} ]]; then
    python_options+=" --seed ${seed}" # eg -h|--short, -s|--sanity, -p|--profile
fi


############################################################################################################
################################### PREPARE THE JOB LAUNCH #################################################
############################ YOU PROBABLY DON'T NEED TO CHANGE THIS ########################################
############################################################################################################

# prolog_file where simulation output will reside
prolog_file=${output_dir}/${job_name}.prolog

# name of batch script to be called by sbatch command
sbatch_script_name="simulation.sbatch"

###### create regression output directory tree #####
if [[ ! -d ${output_dir} ]]; then
    mkdir -p ${output_dir}
fi

# Copy current executables (assumed to be .py, .sh and .sbatch files in the current directory) to output_dir.
# In particular, the copied version of your
# This serves as a snapshotting of current code for later debugging (useful when running simultaneous sims)
# on mammouth, cp -r takes forever for some reason, so doing mkdir and copying contents of models instead
mkdir ${output_dir}/models
cp -p models/* ${output_dir}/models
cp -p *py *sh *sbatch ${output_dir}

# full path to copied python script
python_script_path=${output_dir}/${python_script_name}

# full path to copied sbatch script
sbatch_script_path=${output_dir}/${sbatch_script_name}

# prepare arguments to job script (slurm.sh)
export="python_script_path=\"${python_script_path}\",output_dir=\"${output_dir}\",python_options=\""${python_options}"\",ALL"
mail=''
if [[ ${email} == yes ]]; then
  mail="--mail $EMAIL"
fi
test=''
if [[ ${test_mode} == yes ]]; then
  test="--test"
fi

wait_for_job=''
if [[ -n ${blocking_job_id} ]]; then
  wait_for_job=" --wait_for_job ${blocking_job_id}"
fi

singleton_option=''
if [[ -n ${singleton} ]]; then
  singleton_option=" --singleton"
fi

echo "${me}: LOGFILE:"
echo  ${prolog_file}
echo ""

############################################################################################################
################################ LAUNCH THE JOB (ie call slurm.sh) #########################################
####################### DO NOT CHANGE UNLESS YOU KNOW WHAT YOU'RE DOING ####################################
############################################################################################################

# launch job (more exactly, call job launching script slurm.sh)
#module load python/3.6.3
slurm.sh --cmd sbatch -t "${time}" -j "${job_name}" --prolog "${prolog_file}" -n "${nodes}" -c "${cpus}" --num_proc_per_gpu ${num_proc_per_gpu} -g "${gpus}" -m "${mem}" -e "${export}" --account "${account}" ${singleton_option} ${wait_for_job} ${mail} ${test} "${sbatch_script_path}" |& tee -a ${prolog_file}

# same prolog_file will be used to output job content -- add a header to separate this script's output from slurm.sh output
#echo "" >> ${prolog_file}
#echo "${me}: JOB OUTPUT:" >> ${prolog_file}