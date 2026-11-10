#!/bin/bash

# Ensure we are in the directory containing this script (Shared FS fix)
cd "$(dirname "$0")"

# Generate host keys if not present
if [ ! -f ssh_host_rsa_key ]; then
    ssh-keygen -f ssh_host_rsa_key -N '' -t rsa
    ssh-keygen -f ssh_host_ecdsa_key -N '' -t ecdsa
    ssh-keygen -f ssh_host_ed25519_key -N '' -t ed25519
fi

# Get a random port
PORT=$(shuf -i 2000-65000 -n 1)

# Create SSHD config
cat <<EOF > sshd_config
Port $PORT
HostKey $(pwd)/ssh_host_rsa_key
HostKey $(pwd)/ssh_host_ecdsa_key
HostKey $(pwd)/ssh_host_ed25519_key
AuthorizedKeysFile $(pwd)/authorized_keys
PidFile $(pwd)/sshd.pid
LogLevel DEBUG3
StrictModes no
UsePAM no
PrintMotd no
CheckMail no
UseDNS no
UsePrivilegeSeparation no
UseLogin no
PermitTTY yes
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

# Move authorized keys into place
ls -l key.pub
cp key.pub authorized_keys
chmod 600 authorized_keys

# Diagnostics for permission denied errors
echo "=== Node Diagnostics ===" >> job.out
echo "User: $(whoami)" >> job.out
echo "Host: $(hostname)" >> job.out
echo "Shell: $SHELL" >> job.out
echo "ID: $(id)" >> job.out
echo "pwd: $(pwd)" >> job.out
ls -la /bin/bash >> job.out 2>&1
echo "========================" >> job.out

echo "User: $(whoami)"
echo "Host: $(hostname)"

# Start SSHD (with debug output to job.out)
echo "Starting SSHD on port $PORT"
/usr/sbin/sshd -e -D -f $(pwd)/sshd_config 2>&1 | tee -a job.out &
PID=$!

# Print connection info
echo "Connect with: ssh -p $PORT $(whoami)@$(hostname)"

# Wait for SSHD to exit
wait $PID
