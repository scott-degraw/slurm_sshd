# Slurm SSHD Wrapper

This repository provides a set of scripts to launch a lightweight SSH server (SSHD) inside a Slurm job and establish a secure tunnel connection to it from your local machine, proxying through the submission/login node.

## Features

- **Automated Job Submission**: Checks for existing jobs with a specific job name or submits a new one using `sbatch`.
- **Proxy Tunneling**: Establishes a direct SSH tunnel from your local machine to the execution node by proxying through the submission node.
- **VSCode Ready**: Outputs a configuration snippet for easy integration with VSCode Remote SSH.
- **Persistence**: Reconnects to existing sessions if the job is still running in the queue or on a node.

## Prerequisites

- Local machine: SSH client, `bash`.
- Submission Node: `sbatch`, `squeue` available in PATH.
- **Network Environment**: The execution nodes must be reachable from the submission node via SSH.

## Usage

### 1. Clone the Repository

```bash
git clone https://github.com/scott-degraw/slurm_sshd.git
cd slurm_sshd
```

### 2. Connect to a Job

Run the `connect.sh` script with a unique job name and your submission node login:

```bash
./connect.sh <job-name> <user@login-node>
```

**Example:**
```bash
./connect.sh my-dev-session scott@login.example.com
```

### Options

| Flag       | Description                                      |
| :--------- | :----------------------------------------------- |
| `-p <PORT>`| Specify the local port for the tunnel (default: random) |
| `-c`       | Automatically connect via SSH when ready         |
| `-f <FILE>`| Specify a custom Slurm submit file (default: job.slurm) |
| `-h`       | Show help message                                |

### Example with Options

Connect to `login.example.com`, use local port `8888`, and auto-connect:

```bash
./connect.sh -p 8888 -c my-dev-session scott@login.example.com
```

## How it Works

1.  **Job Check**: The script checks if a Slurm job with the specified name matches your input using `squeue`.
2.  **Submission**:
    - If no job runs, it creates a directory `slurm_ssh_job_<job-name>` on the remote host.
    - Uploads `job.slurm`, `entrypoint.sh`, and your local public key (`~/.ssh/id_*.pub`).
    - Submits the job via `sbatch`.
3.  **Startup**: The job runs `entrypoint.sh`, which generates host keys, starts `sshd` on a random port, and outputs connection details.
4.  **Tunnels**:
    - `connect.sh` waits for the job to print the port number and execution hostname.
    - Establishes a tunnel from your localhost proxying through the submit node directly to the execution node.
5.  **Connection**: Outputs the compiled SSH command to connect, and creates a VSCode SSH config snippet.

## Troubleshooting

-   **"No public key found"**: Ensure you have an SSH key pair (`ssh-keygen -t ed25519`).
-   **"Error: Could not determine internal Job Host"**: This implies the Slurm job crashed or failed to write output. Check `job.err` and `job.out` in the `slurm_ssh_job_<name>` directory on the login node.
