#!/usr/bin/env bash
# Usage: sudo ./worker_install_k0s.sh <controller_ip>
set -euo pipefail
CTL_IP=${1:? "controller IP required"}
LOG_FILE="/home/ubuntu/k0s_worker.log"
source /tmp/common_k0.sh

install_deps
install_k0s

remote="ubuntu@10.2.1.2:~/token-file"
target="/home/ubuntu/token-file"         # where we want it locally
delay=5                           # seconds to wait between tries

# Infinite for-loop: for (;;);
for (( ; ; )); do
  [[ -f $target ]] && {            # stop if we already have it
    echo "✓ $target is present; done."
    break
  }

  echo "Attempting to copy token-file..."
  sshpass -p 1997 ssh-copy-id -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null ubuntu@10.2.1.2
  scp  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$remote" "$target" && {
    echo "✓ Copy succeeded."
    break
  }

  echo "⚠️  Copy failed or file not yet available; retrying in $delay s..."
  sleep "$delay"
done

log "Joining cluster with token"
sudo k0s install worker --token-file  /home/ubuntu/token-file>>"$LOG_FILE"
sudo k0s start
