# Get name of cluster we're on
local_cluster=''

# Different prefix depending if login node (SLURM_JOB_NODELIST empty) vs compute node (SLURM_JOB_NODELIST contains
# list of compute nodes)
if [[ -z ${SLURM_JOB_NODELIST} ]]; then
    node_prefix=$(hostname | cut -c1-3)
    case "$node_prefix" in
      bel)
        local_cluster="beluga"
      ;;
      ced)
        local_cluster="cedar"
      ;;
      del)
        local_cluster="beihang"
      ;;
      gra)
        local_cluster="graham"
      ;;
      hel)
        local_cluster="helios"
      ;;
      ip*)
        local_cluster="mammouth"
      ;;
      nia)
        local_cluster="niagara"
      ;;
      *)
        die "ERROR: local cluster unsupported"
      ;;
    esac
else
    node_prefix=$(echo ${SLURM_JOB_NODELIST} | cut -c1-3)
    case "$node_prefix" in
      blg)
        local_cluster="beluga"
        login_node="beluga3"
      ;;
      cdr)
        local_cluster="cedar"
        login_node="cedar5"
      ;;
      del)
        local_cluster="beihang"
        login_node="dell-mgt-01"
      ;;
      gra)
        local_cluster="graham"
        login_node="gra-login1"
      ;;
      nia)
        local_cluster="niagara"
        login_node="nia-login06"
      ;;
      *)
        die "ERROR: local cluster unsupported"
      ;;
    esac
fi