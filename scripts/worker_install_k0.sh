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
SCP_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

is_token_file_not_ready_error() {
  grep -Fqi 'scp: /home/ubuntu/token-file: No such file or directory' <<<"${1}"
}

retry_cmd_until_token_file_ready() {
  local deadline=$(( $(date +%s) + RETRY_BUDGET_SECS ))
  local scp_output=""

  while :; do
    [[ -f $target ]] && {
      echo "✓ $target is present; done."
      return 0
    }

    echo "Attempting to copy token-file..."
    if scp_output=$(scp ${SCP_OPTS} "$remote" "$target" 2>&1); then
      echo "✓ Copy succeeded."
      return 0
    fi

    if is_retryable_controller_transport_error "${scp_output}" || is_token_file_not_ready_error "${scp_output}"; then
      if [ "$(date +%s)" -ge "${deadline}" ]; then
        _retry_log "token fetch last error: ${scp_output}"
        _retry_die "fetch worker token-file"
      fi
      _retry_log "token file not ready or transient controller SSH failure; retrying in ${delay}s"
      sleep "${delay}"
      continue
    fi

    echo "${scp_output}" >&2
    fail "could not fetch worker token-file with the shared experiment key"
  done
}

# Delete the token file if it already exists
# (can happen if the script has been run before and failed)
[[ -f $target ]] && rm $target

retry_cmd_until_token_file_ready

log "Joining cluster with token"
LABEL_ARGS=""
if [[ "$HOSTNAME" == "ins"* ]]; then
  LABEL_ARGS='--labels "dilated=true"'
fi
ensure_expected_hostname
sudo k0s install worker --token-file  $HOME/token-file --kubelet-extra-args="--max-pods=243 --node-status-update-frequency=1s --resolv-conf=/run/systemd/resolve/resolv.conf" $LABEL_ARGS >>"$LOG_FILE"
sudo k0s start
