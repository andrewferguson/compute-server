#!/usr/bin/env bash
# Usage: sudo ./worker_install_k0s.sh <controller_ip>
set -euo pipefail
LOG_FILE="$HOME/k0s_worker.log"
if [ ! -f "/tmp/common_k0.sh" ]; then
  cp /local/repository/scripts/common_k0.sh /tmp/common_k0.sh
fi
source /tmp/common_k0.sh

install_deps
install_k0s

remote="ubuntu@10.2.1.2:~/token-file"
target="$HOME/token-file"         # where we want it locally
delay=5                           # seconds to wait between tries

# Delete the token file if it already exists
# (can happen if the script has been run before and failed)
[[ -f $target ]] && rm $target

# Infinite for-loop: for (;;);
for (( ; ; )); do
  [[ -f $target ]] && {            # stop if we already have it
    echo "✓ $target is present; done."
    break
  }

  echo "Attempting to copy token-file..."
  sshpass -p 1997 ssh-copy-id -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null ubuntu@10.2.1.2 || {
    echo "Unable to ssh to k8s control node..."
  }
  scp  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$remote" "$target" && {
    echo "✓ Copy succeeded."
    break
  }

  echo "⚠️  Copy failed or file not yet available; retrying in $delay s..."
  sleep "$delay"
done

log "Joining cluster with token"
LABEL_ARGS=""
if [[ "$HOSTNAME" == "ins"* ]]; then
  LABEL_ARGS='--labels "dilated=true"'
fi
sudo k0s install worker --token-file  $HOME/token-file --kubelet-extra-args="--max-pods=243 --node-status-update-frequency=1s" $LABEL_ARGS >>"$LOG_FILE"
sudo k0s start
