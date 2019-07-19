# slurm_simulation_toolkit
By Guillaume Perrault-Archambault

## Disclaimer
The scripts have mainly been tested only on Compute Canada and Beihang clusters, and almost exclusively  on GPU nodes.

Please open an issue if you find a bug or notice that the toolkit does not behave as intended.

## Introduction

This toolkit provides an automated command-line workflow for launching SLURM job regressions (```regression.sh```), monitoring these regressions (```regression_status.sh```), and post-processing regression logs to summarize results (using a custom hook in ```regression_status.sh```).

## Requirements

The scripts were originally designed and tested using bash 4.3.48, and SLURM 17.11.12. These and newer versions of bash and SLURM are supported.

Older versions of bash/SLURM will likely work, but are not officially supported.

## Currently supported clusters
* Graham
* Cedar
* Beluga
* Niagara
* Beihang Dell cluster (referred to as "Beihang" in the code)

## Install instructions
```git clone https://github.com/gobbedy/slurm_simulation_toolkit <PATH_TO_TOOLKIT>```

## Regression setup instructions
Every time you open a new shell, set and export the following environment variables:

 * ```SLURM_SIMULATION_TOOLKIT_HOME``` should be set to ```<PATH_TO_TOOLKIT>``` (the path to the installed toolkit).  
 * ```SLURM_SIMULATION_TOOLKIT_SOURCE_ROOT_DIR``` is the path to the root source directory. See the Regression Control File Syntax section for more details.  
 * ```SLURM_SIMULATION_TOOLKIT_REGRESS_DIR``` is the base directory beneath which simulation output directories and regression summary directories will be autogenerated. The default value in ```examples/example_master.rc``` is likely correct for most Compute Canada and Beihang users.  
 * ```SLURM_SIMULATION_TOOLKIT_JOB_RC_PATH``` is the path to an RC file which contains default SLURM job parameters. Since these parameters can be overridden from the command-line, creating your own RC is not required. In other words, the default value in ```examples/example_master.rc``` does not need to be modified.
 * ```SLURM_SIMULATION_TOOLKIT_GET_CLUSTER``` points to a script that outputs the name of the local cluster. The default script pointed to in ```example_master.rc``` should be correct for Beihang and Compute Canada users. 
 * ```SLURM_SIMULATION_TOOLKIT_SBATCH_SCRIPT_PATH``` is the path to the .sbatch file passed to the sbatch command. This file wraps the user's base script. The default script pointed to in ```example_master.rc``` is intended to be correct for most users, but will likely to not fit all usage models.
 * ```SLURM_SIMULATION_TOOLKIT_RESULTS_PROCESSING_FUNCTIONS``` is the path to a file containing two functions called by ```regression_status.sh``` for processing regression results. This can optionally be left unset, in which case the functions will not be called. An example can be found here ```examples/example_results_processing_functions.sh

You may set these variables by sourcing a master rc file in your shell.

An example master rc file setting all the above variables can be found here: ```<PATH_TO_TOOLKIT>/example_master.rc```

You may copy ```<PATH_TO_TOOLKIT>/example_master.rc``` to any desired location ```<DESIRED_PATH_TO_RC>``` and modify the file contents as desired.

Then simply run:
```source <PATH_TO_RC>```

WARNING: please do NOT store large amounts of data in the parent directory of your base script (including in any of its subdirectories), since this directory will be copied to the output directory for shapshotting.

For the same reason, please do NOT set SLURM_SIMULATION_TOOLKIT_REGRESS_DIR to any path under one of your source directories, otherwise it will constantly get copied into your output directories.

## Regression Control File Syntax
Any line whose first non-whitespace character is ```#``` is treated as a comment. Note that in-line comments are NOT supported (ie when ```#``` is not the first character)

Any line whose first non-whitespace character is ```@``` is treated as a loop variable line. The syntax for loop variable lines is described in the Loop Variable Syntax section.

Any line containing only whitespace characters are ignored.

All other lines are batch control lines. The syntax for these lines is described in the Batch Control Syntax lines.

### Batch Control Syntax
A batch control line has the following syntax:
```<RELATIVE PATH TO BASE SCRIPT> <BATCH OPTIONS> -- <BASE SCRIPT OPTIONS>```
 
```<RELATIVE PATH TO BASE SCRIPT>``` is the path of the user's script relative to $SLURM_SIMULATION_TOOLKIT_SOURCE_ROOT_DIR. In other words, the absolute path to the user's script is ```$SLURM_SIMULATION_TOOLKIT_SOURCE_ROOT_DIR/<RELATIVE PATH TO BASE SCRIPT>```
 
```<BATCH OPTIONS>``` are the options passed to the ```simulation_batch.sh``` script, such ```--num_simulations```. Run ```simulation_batch.sh --help``` for a description of all options.
 
 ```<BASE SCRIPT OPTIONS>``` are options passed down to the user's script.

### Loop Variable Syntax
A loop variable line has the following syntax
@<VAR1>[<VALUES1>],<VAR2>[<VALUES2>],<VAR3>[<VALUES3>],...,<VARN>[<VALUESN>]

where <VAR1>, <VAR2>, <VAR3>,...,<VARN> are loop variable names.
 
<VALUES1>, <VALUES2>, <VALUES3>,...,<VALUESN> are arrays of values. All <VALUES> arrays on the same line must have the same size.

<VALUES> arrays and can be specified in two different ways:
1. **<start>:<increment>:<stop>** where <start> is the first value, <increment> is the increment value, and <stop> is the last value. Note that if <start> is higher than <stop>, <increment> must be explicitly specified as negative.
2. **<val1>,<val2>,...,<valM>** where <val1>,<val2>,...,<valM> are unique values, with no ordering constraints.
 
All variables on the same line are looped simultaneously.

If multiple loop variable lines are specified before a batch control line, varialbles on previous lines are nested in later lines.

### Example Regression Control File

File: ```my_example.ctrl```
```
## EXAMPLE CONTROL FILE, FILENAME: my_example.ctrl

# simple batch (no loop variables)
mixup_fun/train.py --num_simulations 6 -- --dat_transform --dat_parameters 1.3 1.3

# batch loop using <start>:<increment>:<stop>
@alpha[1.3:0.2:1.9]
mixup_fun/train.py --num_simulations 6 -- --dat_transform --dat_parameters alpha alpha

# equivalent using <val1>,<val2>,...,<valM>
@alpha[1.3,1.5,1.7,1.9]
mixup_fun/train.py --num_simulations 6 -- --dat_transform --dat_parameters alpha alpha

# equivalent unrolled loop
mixup_fun/train.py --num_simulations 6 -- --dat_transform --dat_parameters 1.3 1.3
mixup_fun/train.py --num_simulations 6 -- --dat_transform --dat_parameters 1.5 1.5
mixup_fun/train.py --num_simulations 6 -- --dat_transform --dat_parameters 1.7 1.7
mixup_fun/train.py --num_simulations 6 -- --dat_transform --dat_parameters 1.9 1.9

# example of simultaneous loop
@alpha[1.3:0.2:1.9],beta[0.5,1.5,5.0,25.0]
mixup_fun/train.py --num_simulations 6 -- --dat_transform --dat_parameters alpha beta

# equivalent unrolled loop
mixup_fun/train.py --num_simulations 6 -- --dat_transform --dat_parameters 1.3 0.5
mixup_fun/train.py --num_simulations 6 -- --dat_transform --dat_parameters 1.5 1.5
mixup_fun/train.py --num_simulations 6 -- --dat_transform --dat_parameters 1.7 5.0
mixup_fun/train.py --num_simulations 6 -- --dat_transform --dat_parameters 1.9 25.0

# example of nested loop
@beta[0.5,1.5,5.0]
@alpha[1.3,1.5]
mixup_fun/train.py --num_simulations 6 -- --dat_transform --dat_parameters alpha beta

# equivalent unrolled loop
mixup_fun/train.py --num_simulations 6 -- --dat_transform --dat_parameters 1.3 0.5
mixup_fun/train.py --num_simulations 6 -- --dat_transform --dat_parameters 1.3 1.5
mixup_fun/train.py --num_simulations 6 -- --dat_transform --dat_parameters 1.3 5.0
mixup_fun/train.py --num_simulations 6 -- --dat_transform --dat_parameters 1.5 0.5
mixup_fun/train.py --num_simulations 6 -- --dat_transform --dat_parameters 1.5 1.5
mixup_fun/train.py --num_simulations 6 -- --dat_transform --dat_parameters 1.5 5.0
```
The above control file assumes that the user's base script is located here: ```$SLURM_SIMULATION_TOOLKIT_SOURCE_ROOT_DIR/mixup/train.py```

The user's script, in this example, accepts two arguments: ```--dat_transform```, and ```--dat_parameters <val1> <val2>```

Each setting is run 6 times. Assuming ```--num_proc_per_gpu 2``` (see Launching a Regression), this would result in 3 SLURM jobs for each batch.

It goes without saying that the above control file is heavily redundant, launching identical batches for the sake of showing different methods for doing so.

## Example: Launching a Regression

```regression.sh --max_jobs_in_parallel 8 --num_proc_per_gpu 2 --preserve_order --regresn_ctrl my_example.ctrl```

## Example: Launching a Batch of Jobs (TODO: update command and output)

```simulation_batch.sh --num_simulations 12 -- --epochs 200 --batch_size 128```

The above assumes that the user's base script (located wherever ```SLURM_SIMULATION_BASE_SCRIPT``` points to) accepts a ```--epochs <NUM_EPOCHS>``` option and a ```--batch_size <BATCH_SIZE>``` option.

Note that toolkit parameters (here ```--num_simulations 12```) are separated from base script parameters (here ```--epochs 200 --batch_size 128```) with ```--```.

Sample output:
```
RUNNING:
simulation_batch.sh --num_simulations 12 -- --epoch 200 --batch_size 128

JOB IDs FILE IN: /lustre03/project/6004260/gobbedy/regress/regression_summary/dat_Jun05_062358/job_manifest.txt
SLURM COMMANDS FILE: /lustre03/project/6004260/gobbedy/regress/regression_summary/dat_Jun05_062358/slurm_commands.txt
REGRESSION CANCELLATION SCRIPT: /lustre03/project/6004260/gobbedy/regress/regression_summary/dat_Jun05_062358/cancel_regression.sh
REGRESSION COMMAND FILE: /lustre03/project/6004260/gobbedy/regress/regression_summary/dat_Jun05_062358/regression_command.txt
SLURM LOGFILES MANIFEST: /lustre03/project/6004260/gobbedy/regress/regression_summary/dat_Jun05_062358/slurm_log_manifest.txt
SIMULATION LOGS MANIFEST: /lustre03/project/6004260/gobbedy/regress/regression_summary/dat_Jun05_062358/log_manifest.txt
HASH REFERENCE FILE: /lustre03/project/6004260/gobbedy/regress/regression_summary/dat_Jun05_062358/hash_reference.txt
HASH REFERENCE: beluga@638b8668
```

Run ```simulation_batch.sh --help``` for more details on usage.

## Description of each script
### slurm.sh

Wraps sbatch SLURM command. Also supports srun and salloc in theory, but only sbatch is thoroughly tested.

Handles low-level SLURM switches and parameters that do not need to be exposed to the user.

Run ```slurm.sh --help``` for usage.

### simulation.sh

Wraps ```slurm.sh```. Handles generating simulation output directory and copying source code to the output directory. The simulation will be run from within the output directory.

Run ```simulation.sh --help``` for usage.

### simulation_batch.sh

Wraps ```simulation.sh```. Handles launching multiple simulations in parallel. Will generate a regression summary directory containing job ID manifest, logfile manifest, slurm logfile manifest, slurm commands, regression command, hash reference file, and hash reference.

Run ```simulation_batch.sh --help``` for usage.

### regression_status.sh

Uses the summary results generated by ```mini_regression.sh``` to determine whether the regression has passed, failed, or is still running. If still running, breaks down by jobs that are completed, running, or pending.

For each job that has succeeded, will call the user's custom ```process_logfile``` function.

If the entire regression succeeded (completed with all jobs passing), will call the user's custom generate_summary function.

Run ```regression_status.sh --help``` for usage.

## Features

 * Parallel job launching: ```regression.sh``` can handle launching hundreds of jobs in parallel in seconds.
 * Sandbox simulations: all simulations are run in a separate autogenerated directories and do not conflict with each other (eg scripts may write to a file with the same name in their output directory). 
 * Snapshotting source code: The user's source code directory is copied to the autogenerated output, and it is this copied version which is executed. This flow ensures that users can continue editing their source code without affecting pending and running jobs.
 * Regression monitoring: ```regression_status.sh``` automatically reports the status of a regression (running, completed, failed) with a breakdown of each job.
 * Results processing: the user can add functions called by ```regression_status.sh``` to process their regression results.
 * Reproducible simulations: Snapshotting further ensures that simulations are fully reproducible, since all source code is snapshotted at time of the regression launch. The regression command, slurm commands and simulation output are all logged, allowing the user to retrieve any arguments and parameters used in a given simulation. 
 * Option to enforce a maximum number jobs in parallel for the current user -- useful for clusters in Beta testing without fairshare system
 * Argument cascading: arguments following ```--``` are cascaded down to the user's base script, ensuring that the user does not need to  modify the toolkit itself to pass down arguments.
 * Automatic generation of regression cancellation script: this autogenerated script kills the appropriate SLURM jobs if and when the user decides cancel their regression. This both saves the user's time in tracking down running jobs to cancel, as well as helps maximize the use of computer resources for other users.
 * Option to enforce a maximum of number of jobs in parallel for the current user. This is useful for SLURM systems that don't use a fairshare system (eg. in Beta testing phase of a new cluster.)
 * Option to run multiple simulations per GPU: this helps maximize use of compute resources when GPU memory exceeds the model's needs (eg I found that ResNet with 128 batch size uses fewer GPU hours when running 2 processes per GPU on a 32GB GPU).
  * Configurability: users can override default job parameters by supplying their own default job parameters, and use their own ```get_local_cluster.sh```. See  and ```SLURM_SIMULATION_TOOLKIT_JOB_RC_PATH``` and ```SLURM_SIMULATION_TOOLKIT_GET_CLUSTER``` in the install instructions.
