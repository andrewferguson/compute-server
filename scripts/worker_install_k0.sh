#!/usr/bin/env bash
# Usage: sudo ./worker_install_k0s.sh <controller_ip>
set -euo pipefail
LOG_FILE="$HOME/k0s_worker.log"
EXPECTED_HOSTNAME="${EXPECTED_HOSTNAME:-}"
if [ ! -f "/tmp/common_k0.sh" ]; then
  cp /local/repository/scripts/common_k0.sh /tmp/common_k0.sh
fi
source /tmp/common_k0.sh

set_expected_hostname() {
  sudo hostnamectl hostname "${EXPECTED_HOSTNAME}"
  sudo hostname "${EXPECTED_HOSTNAME}"
}

hostname_is_settled() {
  local transient_hostname
  transient_hostname="$(hostnamectl --transient 2>/dev/null || true)"

  [ "$(hostname)" = "${EXPECTED_HOSTNAME}" ] \
    && [ "$(hostnamectl --static)" = "${EXPECTED_HOSTNAME}" ] \
    && { [ -z "${transient_hostname}" ] || [ "${transient_hostname}" = "${EXPECTED_HOSTNAME}" ]; }
}

ensure_expected_hostname() {
  if [ -z "${EXPECTED_HOSTNAME}" ]; then
    return 0
  fi

  until set_expected_hostname && hostname_is_settled
  do
    echo "Failed to settle hostname as ${EXPECTED_HOSTNAME}..."
    sleep "$delay"
  done

  echo "Hostname settled as $(hostname)"
}

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
ensure_expected_hostname
sudo k0s install worker --token-file  $HOME/token-file --kubelet-extra-args="--max-pods=243 --node-status-update-frequency=1s --resolv-conf=/run/systemd/resolve/resolv.conf" $LABEL_ARGS >>"$LOG_FILE"
sudo k0s start
