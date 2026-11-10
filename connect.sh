#!/bin/bash
set -euo pipefail

# Default values
REMOTE_HOST=""
BATCH_NAME=""
REQUESTED_PORT=""
SUBMIT_FILE="job.slurm"
CONNECT_FLAG=0
NEW_JOB=0

usage() {
    echo "Usage: $0 [options] <batch-name> <user@submission-node>"
    echo ""
    echo "Arguments:"
    echo "  <batch-name>          Unique name for the job (e.g., 'dev-session')"
    echo "  <user@submission-node> SSH login for submission node"
    echo ""
    echo "Options:"
    echo "  -f <FILE>   Path to a Slurm submit file (default: job.slurm)"
    echo "  -p <PORT>   Specify the local port for the tunnel (default: random)"
    echo "  -c          Automatically connect when ready"
    echo "  -h          Show this help message"
    echo ""
    exit 1
}

# Parse arguments using getopts
while getopts "f:p:ch" opt; do
    case $opt in
        f)
            SUBMIT_FILE="$OPTARG"
            ;;
        p)
            REQUESTED_PORT="$OPTARG"
            ;;
        c)
            CONNECT_FLAG=1
            ;;
        h)
            usage
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            usage
            ;;
    esac
done

# Shift off the options and arguments processing by getopts
shift $((OPTIND -1))

# Check for required positional arguments
if [ $# -ne 2 ]; then
    echo "Error: Missing required arguments."
    usage
fi

BATCH_NAME="$1"
REMOTE_HOST="$2"

# Detect Public Key
LOCAL_PUB_KEY=""
POSSIBLE_KEYS=(
    "$HOME/.ssh/id_ed25519.pub"
    "$HOME/.ssh/id_rsa.pub"
    "$HOME/.ssh/id_ecdsa.pub"
)

for key in "${POSSIBLE_KEYS[@]}"; do
    if [ -f "$key" ]; then
        LOCAL_PUB_KEY="$key"
        break
    fi
done

if [ -z "$LOCAL_PUB_KEY" ]; then
    echo "Error: No public key found in standard locations (~/.ssh/id_{ed25519,rsa,ecdsa}.pub)."
    echo "Please generate one with 'ssh-keygen -t ed25519' or provide one manually."
    exit 1
fi

# Check for job files
if [ ! -f "$SUBMIT_FILE" ]; then
    echo "Error: Submit file not found: $SUBMIT_FILE"
    exit 1
fi
if [ ! -f "entrypoint.sh" ]; then
    echo "Error: entrypoint.sh not found in current directory."
    exit 1
fi
SUBMIT_FILE_BASENAME=$(basename "$SUBMIT_FILE")

# Determine Remote Directory and Batch Logic
REMOTE_DIR="slurm_ssh_job_${BATCH_NAME}"
echo "Using batch name: $BATCH_NAME"

# Check if job is already running
# We use squeue to check for a running job with this job name
echo "Checking for existing job..."
# squeue -n <name> -h (no header) -o "%t %i" (state and job id)
JOB_CHECK=$(ssh "$REMOTE_HOST" "squeue -n \"$BATCH_NAME\" -h -o \"%t %i\"" 2>/dev/null || true)

if [[ -n "$JOB_CHECK" ]]; then
    # e.g., "R 12345" or "PD 12346"
    JOB_STATE=$(echo "$JOB_CHECK" | awk '{print $1}' | head -n 1)
    JOB_ID=$(echo "$JOB_CHECK" | awk '{print $2}' | head -n 1)
    echo "Found existing job: ID $JOB_ID, State $JOB_STATE"
    echo "Reconnecting to existing job..."
else
    echo "No running job found. Starting new one..."
    NEW_JOB=1
fi

if [ "$NEW_JOB" == "1" ]; then
    # Create remote directory
    echo "Creating remote directory: $REMOTE_DIR on $REMOTE_HOST"
    ssh "$REMOTE_HOST" "mkdir -p $REMOTE_DIR"

    # Upload files
    echo "Uploading files..."
    scp "$SUBMIT_FILE" entrypoint.sh "$REMOTE_HOST:$REMOTE_DIR/"
    scp "$LOCAL_PUB_KEY" "$REMOTE_HOST:$REMOTE_DIR/key.pub"

    # Submit job
    echo "Submitting job..."
    # Ensure entrypoint is executable, remove previous logs, run sbatch
    SUBMIT_CMD="cd $REMOTE_DIR && chmod +x entrypoint.sh && { rm job.{err,out} || true; } && sbatch --job-name=\"$BATCH_NAME\" $SUBMIT_FILE_BASENAME"
    ssh "$REMOTE_HOST" "$SUBMIT_CMD"
fi

echo "Waiting for job to be ready..."

# Wait for connection string and user info
while ! ssh "$REMOTE_HOST" "grep -m1 'Connect with: ssh' $REMOTE_DIR/job.out &>/dev/null"; do
    sleep 5
done

JOB_PORT="$(ssh $REMOTE_HOST "sed -n -E 's/.*Starting SSHD on port ([0-9]+).*/\1/p' $REMOTE_DIR/job.out 2>/dev/null" | head -n 1 | tr -d '\r')"
JOB_USER="$(ssh $REMOTE_HOST "sed -n -E 's/^User: (.*)/\1/p' $REMOTE_DIR/job.out 2>/dev/null" | head -n 1 | tr -d '\r')"
JOB_HOST="$(ssh $REMOTE_HOST "sed -n -E 's/^Host: (.*)/\1/p' $REMOTE_DIR/job.out 2>/dev/null" | head -n 1 | tr -d '\r')"

if [ -z "$JOB_PORT" ]; then
    echo "Error: Could not determine Job Port."
    exit 1
fi

if [ -z "$JOB_USER" ]; then
    echo "Warning: Could not determine Job User directly, falling back to local user."
    JOB_USER="$USER"
fi

if [ -z "$JOB_HOST" ]; then
    echo "Error: Could not determine internal Job Host."
    exit 1
fi

echo "Job Execution Node: $JOB_HOST"
echo "Job Port: $JOB_PORT"
echo "Job User: $JOB_USER"

# Use random local port or requested local port
if [ -n "$REQUESTED_PORT" ]; then
    LOCAL_PORT="$REQUESTED_PORT"
else
    LOCAL_PORT=$(awk 'BEGIN{srand();print int(rand()*(60000-2000))+2000 }')
fi

# Check if local port is in use and kill valid process
if lsof -i :$LOCAL_PORT >/dev/null 2>&1; then
    echo "Port $LOCAL_PORT is in use. Killing process..."
    PID_TO_KILL=$(lsof -t -i :$LOCAL_PORT)
    if [ -n "$PID_TO_KILL" ]; then
        kill $PID_TO_KILL || kill -9 $PID_TO_KILL
        echo "Killed process $PID_TO_KILL"
        sleep 1
    fi
fi

echo "Setting up direct tunnel through submission node..."
echo "Localhost:$LOCAL_PORT -> via ssh($REMOTE_HOST) -> JobNode($JOB_HOST):$JOB_PORT"

# Start Local Tunnel directly to the execution node via the submit node
echo "Starting tunnel..."
ssh -NfL "localhost:$LOCAL_PORT:$JOB_HOST:$JOB_PORT" "$REMOTE_HOST"
sleep 2

SSH_CMD="ssh -p $LOCAL_PORT -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $JOB_USER@localhost"

echo ""
echo "==================================================="
echo "                  JOB IS READY                     "
echo "==================================================="
echo "A tunnel has been established to the execution node."
echo ""
echo "1. Connect via Command Line:"
echo "   $SSH_CMD"
echo ""
echo "2. Connect via VSCode (Remote - SSH):"
echo "   - Open VSCode"
echo "   - Press F1, type 'Remote-SSH: Connect to Host...'"
echo "   - Select 'slurm-job-$BATCH_NAME'"
echo "==================================================="

# Generate VSCode Config
CONFIG_HOST="slurm-job-$BATCH_NAME"
SSH_CONFIG_DIR="$HOME/.ssh/config.d"
SSH_CONFIG_FILE="$SSH_CONFIG_DIR/slurm-jobs"

# Create the config directory if it doesn't exist
mkdir -p "$SSH_CONFIG_DIR"
chmod 700 "$SSH_CONFIG_DIR"

# Build the new host block
NEW_BLOCK="# BEGIN slurm-job-$BATCH_NAME
Host $CONFIG_HOST
    HostName localhost
    Port $LOCAL_PORT
    User $JOB_USER
    UserKnownHostsFile /dev/null
    StrictHostKeyChecking no
# END slurm-job-$BATCH_NAME"

# Update or append the block for this batch name in the config file
if [ -f "$SSH_CONFIG_FILE" ] && grep -q "# BEGIN slurm-job-$BATCH_NAME" "$SSH_CONFIG_FILE"; then
    # Use a temporary file and sed to replace the block
    # This is more robust than awk -v for multi-line variables on Mac
    printf "%s\n" "$NEW_BLOCK" > "${SSH_CONFIG_FILE}.new"
    sed -n "/# BEGIN slurm-job-$BATCH_NAME/,/# END slurm-job-$BATCH_NAME/!p" "$SSH_CONFIG_FILE" >> "${SSH_CONFIG_FILE}.new"
    mv "${SSH_CONFIG_FILE}.new" "$SSH_CONFIG_FILE"
else
    if [ -s "$SSH_CONFIG_FILE" ]; then
        echo "" >> "$SSH_CONFIG_FILE"
    fi
    echo "$NEW_BLOCK" >> "$SSH_CONFIG_FILE"
fi
chmod 600 "$SSH_CONFIG_FILE"

echo ""
echo "SSH config written to: $SSH_CONFIG_FILE"
echo "You can now connect with:  ssh $CONFIG_HOST"
echo ""

# Optional: Automatic connection
if [ "$CONNECT_FLAG" -eq 1 ]; then
    echo "Connecting..."
    eval $SSH_CMD
fi
