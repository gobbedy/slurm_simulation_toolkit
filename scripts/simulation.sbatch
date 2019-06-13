#!/usr/bin/env bash
source ${SLURM_SIMULATION_TOOLKIT_HOME}/config/simulation_toolkit.rc

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
# Launch pythons simulation
######################################################################
job_name=$SLURM_JOB_NAME
slurm_logfile=$output_dir/${job_name}.slurm
export PYTHONUNBUFFERED=1 # Not needed if already in bashrc

for (( i=0; i<$num_proc_per_gpu; i++ ));
do
{
    gpu_process_logfile=$output_dir/${job_name}_proc_${i}.log
    cp ${slurm_logfile} ${gpu_process_logfile}
    echo "Launching ${script_path} on proc ${i}. Logfile:"
    echo ${gpu_process_logfile}
    export CUDA_VISIBLE_DEVICES=0
    echo "Script Arguments:"
    echo $@
    ${script_path} $@ &>> ${gpu_process_logfile}
    if [[ $? -ne 0 ]]; then
        die "${script_path} failed. See ${gpu_process_logfile}"
    fi
}&
done
wait

#if [[ ${cluster} != "cedar" ]]; then
#    ssh $login_node scp -o "StrictHostKeyChecking=no" -r $output_dir gobbedy@cedar.computecanada.ca:/home/gobbedy/projects/def-yymao/gobbedy/regress/mixup_paper/${cluster}
#fi