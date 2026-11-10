#!/bin/bash
#SBATCH --job-name=sshd_session
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --output=job.out
#SBATCH --error=job.err

./entrypoint.sh
