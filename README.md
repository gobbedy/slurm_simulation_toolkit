Work in progress. This introduction is not complete and the code is not ready to be used.

# compute_canada_template_project
By Guillaume Perrault-Archambault

## Introduction

The goal of for new users to be able to clone this project, and with minimal changes, have an automated workflow for luanching, monitoring, post-processing parallel simulations.

## Currently supported clusters
* Graham
* Cedar
* Beluga
* Beihang Dell cluster (referred to as "Beihang" in the code)

## Run instructions
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

