#!/bin/bash

############################################################################################################
######### HELPER VARIABLES AND FUNCTIONS -- DO NOT CHANGE UNLESS YOU KNOW WHAT YOU'RE DOING ################
############################################################################################################
me=$(basename ${0%%@@*})
full_me=${0%%@@*}
me_dir=$(dirname $(readlink -f ${0%%@@*}))
parent_dir=$(dirname ${me_dir})

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
epochs=200
num_proc_per_gpu=1
time="0-02:00:00"
account=rrg-mao
batch_size=128
dataset=cifar10
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
    --batch_size)
      batch_size=$2
      shift 2
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
output_dir=${regress_dir}/test/test_${datetime_suffix}


# name of python script to be executed -- assumed to reside in current directory
# NOTE: This script will be copied to the output directory and the COPIED version will be executed
#       This allows you to continue working and not worry about when SLURM will launch your script.
python_script_name="train.py"

# options to be passed into python script
python_options="--epoch ${epochs} --batch_size ${batch_size} --dataset ${dataset}"

if [[ -n ${seed} ]]; then
    python_options+=" --seed ${seed}" # eg -h|--short, -s|--sanity, -p|--profile
fi


############################################################################################################
################################### PREPARE THE JOB LAUNCH #################################################
############################ YOU PROBABLY DON'T NEED TO CHANGE THIS ########################################
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
cp -rp ${parent_dir}/*py ${parent_dir}/scripts ${output_dir}

# full path to copied python script
python_script_path=${output_dir}/${python_script_name}

# full path to copied sbatch script
sbatch_script_path=${output_dir}/scripts/${sbatch_script_name}

# prepare arguments to job script (slurm.sh)
export="python_script_path=\"${python_script_path}\",output_dir=\"${output_dir}\""
export+=",python_options=\"${python_options}\",ALL"

# TODO: export escaped may be broken now
simulation_options="-t ${time} -j ${job_name} --prolog ${prolog_file} -n ${nodes} -c ${cpus} -g ${gpus} -m ${mem}"
simulation_options+=" --num_proc_per_gpu ${num_proc_per_gpu} --cmd sbatch --account ${account}"
if [[ ${email} == yes ]]; then
  simulation_options+=" --mail $EMAIL"
fi

if [[ ${test_mode} == yes ]]; then
  simulation_options+=" --test"
fi

if [[ -n ${blocking_job_id} ]]; then
  simulation_options+=" --wait_for_job ${blocking_job_id}"
fi

if [[ -n ${singleton} ]]; then
  simulation_options+=" --singleton"
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
slurm.sh ${simulation_options} -e "${export}" "${sbatch_script_path}" |& tee -a ${prolog_file}

# same prolog_file will be used to output job content -- add a header to separate this script's output from slurm.sh output
echo "" >> ${prolog_file}
echo "${me}: JOB OUTPUT:" >> ${prolog_file}