# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Pure-bash tooling to run an unprivileged `sshd` inside a Slurm job and tunnel to it from a local machine through the login/submission node (e.g. for VSCode Remote-SSH on a compute node). No build system, tests, or dependencies beyond `ssh`/`scp` locally and `sbatch`/`squeue` on the cluster.

```bash
./connect.sh [-p LOCAL_PORT] [-c] [-f SUBMIT_FILE] <job-name> <user@login-node>
```

`connect.sh` must be run from the repo root: it uploads `entrypoint.sh` and the submit file by relative path.

## Architecture

Three scripts split across two machines:

- **`connect.sh`** (runs locally): looks for an existing job via `squeue -n <job-name>`; if none, creates `~/slurm_ssh_job_<job-name>/` on the login node, uploads the submit file, `entrypoint.sh`, and the first found `~/.ssh/id_{ed25519,rsa,ecdsa}.pub` as `key.pub`, then runs `sbatch --job-name=<job-name>` (overriding the `#SBATCH --job-name` in the file). It then polls the remote `job.out`, opens `ssh -NfL localhost:<local>:<node>:<port>` via the login node, and writes/replaces a `# BEGIN/END slurm-job-<name>` host block in `~/.ssh/config.d/slurm-jobs`. It kills any local process already holding the chosen port.
- **`job.slurm`** (default submit file): resource request; writes `job.out`/`job.err` in the job directory and calls `./entrypoint.sh`. Alternative submit files passed with `-f` must keep the `--output=job.out` path and invoke `./entrypoint.sh`.
- **`entrypoint.sh`** (runs on the compute node): `cd`s to its own directory (shared filesystem), generates host keys once, picks a random port with `shuf`, writes a user-owned `sshd_config` (no PAM, `StrictModes no`, `UsePrivilegeSeparation no`), and runs `/usr/sbin/sshd -D` in the foreground so the job lives as long as sshd.

### Implicit contract between `entrypoint.sh` and `connect.sh`

`connect.sh` scrapes `job.out` with `grep`/`sed`; changing any of these output lines in `entrypoint.sh` breaks connection:

- `Connect with: ssh ...` — readiness signal (polled every 5 s)
- `Starting SSHD on port <N>`
- `User: <name>` and `Host: <hostname>` at line start (first match wins; the diagnostics block also emits these)

`job_output.txt` is a sample captured `job.out` from a real run, useful as a reference for that format.
