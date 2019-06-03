Work in progress. This introduction is not complete and the code is not ready to be used.

# slurm_simulation_toolkit
By Guillaume Perrault-Archambault

## Introduction

The goal is for users to get an automated workflow for launching batches jobs (```mini_regression.sh```, ```simulation.sh```, ```slurm.sh```, ```simulation.sbatch```), monitoring these regressions (```regression_status.sh```), and post-process regressions (```process_results.sh```).

## Currently supported clusters
* Graham
* Cedar
* Beluga
* Beihang Dell cluster (referred to as "Beihang" in the code)

## Install instructions
Add the scripts directory to your path:  
```export PATH=<PATH-TO-CLONED-REPO>/scripts:$PATH```

## slurm.sh

Wraps sbatch SLURM command. Also supports srun and salloc in theory, but only sbatch is thoroughly tested.

Handles low-level SLURM switches and parameters that do not need to be exposed to the user.

Run ```slurm.sh --help``` for usage.

## simulation.sh.

Wraps slurm.sh. Handles static simulation parameters that do not need to be updated frequently, as well as generating a new simulation output directory for each run.

Run ```simulation.sh --help``` for usage.

## mini_regression.sh

Wraps simulations. Handles launching multiple simulations in parallel.

Run ```mini_regression.sh --help``` for usage.

