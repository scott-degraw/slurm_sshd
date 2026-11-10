#!/bin/bash
set -euo pipefail

# Default values
REMOTE_HOST=""
BATCH_NAME=""
REQUESTED_PORT=""
SUBMIT_FILE="job.slurm"
CONNECT_FLAG=0
VSCODE_FLAG=0
VSCODE_DIR=""
NEW_JOB=0

# Output styling (colors only on a terminal, and never when NO_COLOR is set)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD=$'\033[1m' DIM=$'\033[2m' RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' BLUE=$'\033[34m'
    CYAN=$'\033[36m' RESET=$'\033[0m' IS_TTY=1
else
    BOLD="" DIM="" RED="" GREEN="" YELLOW="" BLUE="" CYAN="" RESET="" IS_TTY=0
fi
step() { printf '%s==>%s %s%s%s\n' "$BLUE$BOLD" "$RESET" "$BOLD" "$*" "$RESET"; }
info() { printf '    %s%s%s\n' "$DIM" "$*" "$RESET"; }
ok() { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$YELLOW$BOLD" "$RESET" "$*" >&2; }
die() {
    printf '%s✗ Error:%s %s\n' "$RED$BOLD" "$RESET" "$1" >&2
    shift
    for line in "$@"; do printf '  %s\n' "$line" >&2; done
    exit 1
}

usage() {
    echo "${BOLD}Usage:${RESET} $0 [options] <batch-name> <user@submission-node>"
    echo ""
    echo "${BOLD}Arguments:${RESET}"
    echo "  <batch-name>           Unique name for the job (e.g., 'dev-session')"
    echo "  <user@submission-node> SSH login for submission node"
    echo ""
    echo "${BOLD}Options:${RESET}"
    echo "  -f <FILE>   Path to a Slurm submit file (default: job.slurm)"
    echo "  -p <PORT>   Specify the local port for the tunnel (default: random)"
    echo "  -c          Automatically connect when ready"
    echo "  -v          Open a VSCode window connected to the job when ready"
    echo "  -d <DIR>    Absolute path on the execution node for VSCode to open (implies -v)"
    echo "  -h          Show this help message"
    echo ""
    exit 1
}

# Parse arguments using getopts
while getopts "f:p:cvd:h" opt; do
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
        v)
            VSCODE_FLAG=1
            ;;
        d)
            VSCODE_FLAG=1
            VSCODE_DIR="$OPTARG"
            ;;
        h)
            usage
            ;;
        \?)
            usage
            ;;
    esac
done

# Shift off the options and arguments processing by getopts
shift $((OPTIND -1))

# Check for required positional arguments
if [ $# -ne 2 ]; then
    printf '%s✗ Error:%s Missing required arguments.\n\n' "$RED$BOLD" "$RESET" >&2
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
    die "No public key found in standard locations (~/.ssh/id_{ed25519,rsa,ecdsa}.pub)." \
        "Generate one with 'ssh-keygen -t ed25519'."
fi

# Check for job files
[ -f "$SUBMIT_FILE" ] || die "Submit file not found: $SUBMIT_FILE"
[ -f "entrypoint.sh" ] || die "entrypoint.sh not found in current directory." "Run connect.sh from the repository root."
SUBMIT_FILE_BASENAME=$(basename "$SUBMIT_FILE")

# Determine Remote Directory and Batch Logic
REMOTE_DIR="slurm_ssh_job/${BATCH_NAME}"

echo ""
printf '%sslurm_sshd%s  %s%s%s on %s%s%s\n' "$BOLD" "$RESET" "$CYAN" "$BATCH_NAME" "$RESET" "$CYAN" "$REMOTE_HOST" "$RESET"
echo ""

# Reuse one authenticated connection for every ssh/scp call so polling doesn't trigger repeated logins (MFA,
# rate limits). Respect the user's own ControlPath if their ssh config already sets one for this host.
MUX_OPTS=""
if ! ssh -G "$REMOTE_HOST" 2>/dev/null | grep -q '^controlpath '; then
    MUX_OPTS="-o ControlMaster=auto -o ControlPath=~/.ssh/slurm_sshd-%C -o ControlPersist=10m"
fi

# Check if job is already running
step "Checking for an existing job"
# squeue -n <name> -h (no header) -o "%t %i" (state and job id)
JOB_CHECK=$(ssh -T $MUX_OPTS "$REMOTE_HOST" "squeue -n \"$BATCH_NAME\" -h -o \"%t %i\"" 2>/dev/null || true)

if [[ -n "$JOB_CHECK" ]]; then
    # e.g., "R 12345" or "PD 12346"
    JOB_STATE=$(echo "$JOB_CHECK" | awk '{print $1}' | head -n 1)
    JOB_ID=$(echo "$JOB_CHECK" | awk '{print $2}' | head -n 1)
    ok "Found job $JOB_ID (state $JOB_STATE), reconnecting"
else
    info "No job named '$BATCH_NAME' in the queue"
    NEW_JOB=1
fi

if [ "$NEW_JOB" == "1" ]; then
    step "Submitting a new job"
    ssh -T $MUX_OPTS "$REMOTE_HOST" "mkdir -p $REMOTE_DIR"
    scp -q $MUX_OPTS "$SUBMIT_FILE" entrypoint.sh "$REMOTE_HOST:$REMOTE_DIR/"
    scp -q $MUX_OPTS "$LOCAL_PUB_KEY" "$REMOTE_HOST:$REMOTE_DIR/key.pub"
    ok "Uploaded $SUBMIT_FILE_BASENAME, entrypoint.sh and $(basename "$LOCAL_PUB_KEY") to ~/$REMOTE_DIR"

    # Ensure entrypoint is executable, remove previous logs, run sbatch
    SUBMIT_CMD="cd $REMOTE_DIR && chmod +x entrypoint.sh && rm -f job.err job.out && sbatch --parsable --job-name=\"$BATCH_NAME\" $SUBMIT_FILE_BASENAME"
    SBATCH_OUT=$(ssh -T $MUX_OPTS "$REMOTE_HOST" "$SUBMIT_CMD 2>&1" | tr -d '\r') ||
        die "sbatch failed on $REMOTE_HOST:" "$SBATCH_OUT"
    # --parsable puts the job ID on the last line; anything before it is site notes/warnings
    while IFS= read -r line; do
        [ -n "$line" ] && info "$line"
    done <<<"$(sed '$d' <<<"$SBATCH_OUT")"
    JOB_ID=$(tail -n 1 <<<"$SBATCH_OUT" | cut -d ';' -f 1)
    ok "Submitted job $JOB_ID"
fi

step "Waiting for sshd to start"

# One call per poll: READY once sshd has printed its connection line, otherwise the job's queue state
LAST_STATE=""
while true; do
    STATE=$(ssh -T $MUX_OPTS "$REMOTE_HOST" \
        "grep -q 'Connect with: ssh' $REMOTE_DIR/job.out 2>/dev/null && echo READY || squeue -h -n \"$BATCH_NAME\" -o %T | head -n 1" |
        tr -d '\r') || STATE="ssh failed, retrying"
    [ "$STATE" == "READY" ] && break
    if [ -z "$STATE" ]; then
        [ "$IS_TTY" -eq 1 ] && echo ""
        die "Job '$BATCH_NAME' left the queue before sshd started." \
            "Check ~/$REMOTE_DIR/job.out and job.err on $REMOTE_HOST."
    fi
    if [ "$IS_TTY" -eq 1 ]; then
        printf '\r\033[K    %s%s, %dm%02ds elapsed%s' "$DIM" "$STATE" $((SECONDS / 60)) $((SECONDS % 60)) "$RESET"
    elif [ "$STATE" != "$LAST_STATE" ]; then
        info "$STATE"
    fi
    LAST_STATE="$STATE"
    sleep 10
done
[ "$IS_TTY" -eq 1 ] && [ -n "$LAST_STATE" ] && printf '\r\033[K'

JOB_INFO="$(ssh -T $MUX_OPTS "$REMOTE_HOST" "grep -E '^(User|Host): |Starting SSHD on port' $REMOTE_DIR/job.out" | tr -d '\r' || true)"
JOB_PORT="$(sed -n -E 's/.*Starting SSHD on port ([0-9]+).*/\1/p' <<<"$JOB_INFO" | head -n 1)"
JOB_USER="$(sed -n -E 's/^User: (.*)/\1/p' <<<"$JOB_INFO" | head -n 1)"
JOB_HOST="$(sed -n -E 's/^Host: (.*)/\1/p' <<<"$JOB_INFO" | head -n 1)"

[ -n "$JOB_PORT" ] || die "Could not determine the sshd port from ~/$REMOTE_DIR/job.out."
[ -n "$JOB_HOST" ] || die "Could not determine the execution node." \
    "Check ~/$REMOTE_DIR/job.out and job.err on $REMOTE_HOST."
if [ -z "$JOB_USER" ]; then
    warn "Could not determine the job user, falling back to local user '$USER'"
    JOB_USER="$USER"
fi
ok "sshd running on $JOB_HOST:$JOB_PORT as $JOB_USER"

# Use random local port or requested local port
if [ -n "$REQUESTED_PORT" ]; then
    LOCAL_PORT="$REQUESTED_PORT"
else
    LOCAL_PORT=$(awk 'BEGIN{srand();print int(rand()*(60000-2000))+2000 }')
fi

step "Opening tunnel"

# Check if local port is in use and kill valid process
if lsof -i :$LOCAL_PORT >/dev/null 2>&1; then
    PID_TO_KILL=$(lsof -t -i :$LOCAL_PORT)
    if [ -n "$PID_TO_KILL" ]; then
        warn "Port $LOCAL_PORT is in use, killing process $PID_TO_KILL"
        kill $PID_TO_KILL || kill -9 $PID_TO_KILL
        sleep 1
    fi
fi

# Start Local Tunnel directly to the execution node via the submit node
ssh -TNfL $MUX_OPTS "localhost:$LOCAL_PORT:$JOB_HOST:$JOB_PORT" "$REMOTE_HOST"
sleep 2
ok "localhost:$LOCAL_PORT → $REMOTE_HOST → $JOB_HOST:$JOB_PORT"

SSH_CMD="ssh -p $LOCAL_PORT -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $JOB_USER@localhost"

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
ok "Wrote host '$CONFIG_HOST' to ${SSH_CONFIG_FILE/#$HOME/~}"

echo ""
printf '%s%s● Job is ready%s\n' "$GREEN" "$BOLD" "$RESET"
echo ""
printf '  %-10s %s\n' "Job" "${JOB_ID:-?} on $JOB_HOST"
printf '  %-10s %s%s%s\n' "SSH" "$CYAN" "ssh $CONFIG_HOST" "$RESET"
printf '  %-10s %s%s%s\n' "VSCode" "$CYAN" "Remote-SSH: Connect to Host… → $CONFIG_HOST" "$RESET"
printf '  %-10s %s%s%s\n' "Stop" "$DIM" "ssh $REMOTE_HOST scancel --name=$BATCH_NAME" "$RESET"
echo ""

# Optional: Open VSCode connected to the job
if [ "$VSCODE_FLAG" -eq 1 ]; then
    if ! command -v code >/dev/null 2>&1; then
        warn "'code' not found in PATH. In VSCode, run 'Shell Command: Install 'code' command in PATH'."
    else
        if ! grep -qiE '^[[:space:]]*Include[[:space:]]+.*config\.d' "$HOME/.ssh/config" 2>/dev/null; then
            warn "~/.ssh/config has no 'Include config.d/*' line, so VSCode may not resolve $CONFIG_HOST."
            info "Add 'Include config.d/*' near the top of ~/.ssh/config (before any Host blocks)."
        fi
        step "Opening VSCode on $CONFIG_HOST${VSCODE_DIR:+:$VSCODE_DIR}"
        if [ -n "$VSCODE_DIR" ]; then
            code --remote "ssh-remote+$CONFIG_HOST" "$VSCODE_DIR"
        else
            code --remote "ssh-remote+$CONFIG_HOST"
        fi
    fi
fi

# Optional: Automatic connection
if [ "$CONNECT_FLAG" -eq 1 ]; then
    step "Connecting"
    eval $SSH_CMD
fi
