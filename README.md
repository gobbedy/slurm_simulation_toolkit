Work in progress. Currently, job launching scripts (```mini_regression.sh```, ```simulation.sh```, ```slurm.sh```, ```simulation.sbatch```) are ready to be beta tested by users. The job monitoring script (```regression_status.sh```) and the result processing script (```process_results.sh```) are not ready. This readme should sufficiently describe the job launching scripts for beta users.

# slurm_simulation_toolkit
By Guillaume Perrault-Archambault

## Introduction

This toolkit provides an automated workflow for launching batches of jobs (```mini_regression.sh```, ```simulation.sh```, ```slurm.sh```, ```simulation.sbatch```), monitoring these regressions (```regression_status.sh```), and post-process regressions (```process_results.sh```).

The toolkit is designed to work 'as is' without modification by the user. That said, is designed in a modular way, such that cluster-specific configurations can be overridden (by supplying your own ```SLURM_SIMULATION_TOOLKIT_CLUSTER_CONFIG_RC```) if the user wishes to add support for a new/unsupported cluster.

## Currently supported clusters
* Graham
* Cedar
* Beluga
* Beihang Dell cluster (referred to as "Beihang" in the code)

## Install instructions
```git clone https://github.com/SITE5039/slurm_simulation_toolkit <PATH_TO_TOOLKIT>```

Set and export the following environment variables:
```
SLURM_SIMULATION_TOOLKIT_HOME
SLURM_SIMULATION_BASE_SCRIPT
SLURM_SIMULATION_REGRESS_DIR
SLURM_SIMULATION_TOOLKIT_RC
SLURM_SIMULATION_TOOLKIT_CLUSTER_CONFIG_RC
```

You may do so by sourcing an rc file in your shell.

An example rc file can be found here: ```<PATH_TO_TOOLKIT>/user_template.rc```

You may copy ```<PATH_TO_TOOLKIT>/user_template.rc``` to any desired location ```<PATH_TO_RC>``` and modify ```user_template.rc``` as desired.

Then simply run:
```source <PATH_TO_RC>```

## Example: Running 12 jobs in parallel

```mini_regression.sh --num_simulations 12 -- --epochs 200 --batch_size 128```

The above assumes that your base script (located wherever ```SLURM_SIMULATION_BASE_SCRIPT``` points to) accepts a ```--epochs <NUM_EPOCHS>``` option and a ```--batch_size <BATCH_SIZE>``` option.

Note that toolkit parameters (here ```--num_simulations 12```) are separated from base script parameters (here ```--epochs 200 --batch_size 128```) with ```--```.

Run ```mini_regression.sh --help``` for more details on usage.

## Description of each script
### slurm.sh

Wraps sbatch SLURM command. Also supports srun and salloc in theory, but only sbatch is thoroughly tested.

Handles low-level SLURM switches and parameters that do not need to be exposed to the user.

Run ```slurm.sh --help``` for usage.

### simulation.sh.

Wraps ```slurm.sh```. Handles static simulation parameters that do not need to be updated frequently, as well as generating a new simulation output directory for each run.

Run ```simulation.sh --help``` for usage.

### mini_regression.sh

Wraps ```simulation.sh```. Handles launching multiple simulations in parallel.

Run ```mini_regression.sh --help``` for usage.
