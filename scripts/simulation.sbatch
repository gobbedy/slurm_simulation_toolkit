#!/bin/bash

######################################################################
# THE ONLY PART YOU REALLY NEED IS AT THE VERY END!!
######################################################################

set -o pipefail
me=$(basename ${0%%@@*})
full_me=${0%%@@*}
me_dir=$(dirname $(readlink -f ${0%%@@*}))



######################################################################
# Convenience functions
######################################################################
### exit elegantly
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

######################################################################
# Get node prefix, node suffix and login node
######################################################################

# get node prefix (eg gra, cdr, nia)
node_prefix=$(echo ${SLURM_JOB_NODELIST} | cut -c1-3)

# get node suffix for python, and login node
# eg in python cedar nodes are "cdr1132.int.cedar.computecanada.ca" instead of "cdr1132"
case "$node_prefix" in
  gra)
    cluster="graham"
    login_node="gra-login1"
  ;;
  cdr)
    cluster="cedar"
    login_node="cedar5"
  ;;
  blg)
    cluster="beluga"
    login_node="beluga3"
  ;;
  nia)
    cluster="niagara"
    login_node="nia-login06"
  ;;
  del)
    cluster="beihang"
    login_node="dell-mgt-01"
  ;;
esac

######################################################################
# Setup cleanup routine to trap on any exit condition (even normal)
######################################################################

function cleanupOnExit
{

  error=0
  local signal="$1"
  if [[ "${signal}" != "EXIT" ]]; then
    error=1
    printf "\nERROR in ${me}: User interrupted (${signal})\n" >&2
  fi

  # ENTER YOUR CODE HERE:
  # <SOME KIND OF HANDLING (eg e-mail user)

  info "Done at $(date +%Y-%m-%d.%H:%M:%S)"

  # Cleanup trap signals and force kill on same signal to propagate
  trap - ${signal}
  trap - EXIT
  if [[ "${signal}" != "SIGUSR1" ]]; then
    kill -${signal} $$
  fi
}

trap 'cleanupOnExit "SIGHUP"' SIGHUP
trap 'cleanupOnExit "SIGINT"' SIGINT
trap 'cleanupOnExit "SIGTERM"' SIGTERM
trap 'cleanupOnExit "SIGQUIT"' SIGQUIT
trap 'cleanupOnExit "SIGUSR1"' SIGUSR1
trap 'cleanupOnExit "SIGUSR1"' USR1
trap 'cleanupOnExit "EXIT"' EXIT


######################################################################
# Launch pythons simulation -- THE ONLY PART YOU REALLY NEED!!
######################################################################
job_name=$SLURM_JOB_NAME
prolog_file=$output_dir/${job_name}.prolog
export PYTHONUNBUFFERED=1 # Not needed if already in bashrc

for (( i=0; i<$num_proc_per_gpu; i++ ));
do
{
    gpu_process_logfile=$output_dir/${job_name}_proc_${i}.log
    cp ${prolog_file} ${gpu_process_logfile}
    echo "Launching ${python_script_path} on proc ${i}. Logfile:"
    echo ${gpu_process_logfile}
    export CUDA_VISIBLE_DEVICES=0
    ${python_script_path} ${python_options} &>> ${gpu_process_logfile}
}&
done
wait

if [[ ${cluster} != "cedar" ]]; then
    ssh $login_node scp -o "StrictHostKeyChecking=no" -r $output_dir gobbedy@cedar.computecanada.ca:/home/gobbedy/projects/def-yymao/gobbedy/regress/mixup_paper/${cluster}
fi