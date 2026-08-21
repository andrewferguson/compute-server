#!/usr/bin/env bash
# Usage: sudo ./worker_install_k0s.sh <controller_ip>
set -euo pipefail
LOG_FILE="$HOME/k0s_worker.log"
EXPECTED_HOSTNAME="${EXPECTED_HOSTNAME:-}"
: "${RETRY_BUDGET_SECS:=3600}"
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

delay=5                           # seconds to wait between tries

# Installing and joining k0s is once-only work, but this script is invoked from
# build_proxy.sh / build_globalsc.sh, which the CloudLab startup service re-runs
# on EVERY boot. Re-running it cannot succeed and does not fail quickly:
#
#   install_k0s pipes upstream get.k0s.sh into sh, and that writes in place to
#   /usr/local/bin/k0s -- the binary the running k0sworker is executing. The
#   write fails with ETXTBSY ("Text file busy"), and because it is wrapped in
#   retry_pipe it retries against RETRY_BUDGET_SECS (3600s). Observed on a real
#   power cycle: attempt 122 and climbing, an hour of spinning, and the node
#   finally reported failed -- while it was healthy and Ready in k8s the whole
#   time, because the k0sworker unit persists and auto-starts on its own.
#
# Gate on real state rather than a marker file: k0s binary present, unit known
# to systemd, and unit enabled.
if [ -x "$K0S_BIN" ] \
   && systemctl list-unit-files k0sworker.service >/dev/null 2>&1 \
   && systemctl is-enabled --quiet k0sworker 2>/dev/null; then
    log "k0s worker already installed and enabled; skipping install/join"
    # Emulab resets the hostname on every boot (observed: proxy0 -> proxy-0), and
    # for Global-SC this script is the only thing that pins it back to the name
    # k0s registered under. Must still run even on the skip path. No-ops when
    # EXPECTED_HOSTNAME is empty, which is the case for the inner-VM workers.
    ensure_expected_hostname
    sudo systemctl start k0sworker || true

    # Safety net for nodes installed before --hostname-override existed, and for
    # any other case where the kubelet came up under the wrong node name. When
    # that happens the API server rejects it with "is not allowed to modify
    # node" and it never renews its lease -- which the 50000s
    # node-monitor-grace-period hides, leaving the node falsely Ready while pods
    # scheduled onto it hang Pending forever.
    #
    # Deliberately CONDITIONAL. An unconditional restart would be actively
    # harmful on a node that registered correctly and has since picked up a
    # transient DHCP hostname: Global-SC ends up static=globalsc but
    # transient=global-sc, and restarting there would re-register it under the
    # wrong name and cause exactly the failure this is meant to prevent.
    #
    # Journal written to a file rather than piped into grep: this script runs
    # under `set -o pipefail`, where `journalctl | grep -q` returns 141 when grep
    # exits first and journalctl takes SIGPIPE.
    k0s_boot_journal="$(mktemp)"
    sudo journalctl -u k0sworker -b --no-pager >"${k0s_boot_journal}" 2>/dev/null || true
    if grep -q "is not allowed to modify node" "${k0s_boot_journal}"; then
        log "kubelet registered under the wrong node name; restarting now the hostname is settled"
        sudo systemctl restart k0sworker || true
    fi
    rm -f "${k0s_boot_journal}"

    log "k0sworker is $(systemctl is-active k0sworker 2>&1)"
    exit 0
fi

install_deps
install_k0s

remote="ubuntu@10.2.1.2:~/token-file"
target="$HOME/token-file"         # where we want it locally
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
# --hostname-override pins the node name at install time, when the hostname is
# known to be correct (ensure_expected_hostname ran just above, and for proxies
# build_proxy.sh set it before calling us).
#
# Without it the kubelet takes its node name from the OS hostname *at every
# start*, and on a reboot k0sworker starts from its persisted unit long before
# the startup service renames the host -- so it tries to register under Emulab's
# name (e.g. proxy0.chronos-agent.test5g-pg0.utah.cloudlab.us) while its client
# certificate says system:node:proxy-0. The Node authorizer refuses, since a node
# credential may only modify its own node object:
#
#   "Unable to register node with API server" err="nodes \"proxy0...\" is
#    forbidden: node \"proxy-0\" is not allowed to modify node \"proxy0...\""
#
# The kubelet is then wedged forever: it never renews the proxy-0 lease, and
# because k0s.yaml sets node-monitor-grace-period to 50000s (~14h) the node still
# reads Ready. The scheduler places pods on it and they hang Pending indefinitely
# -- observed as core-0 stuck Pending for 15 minutes with no events at all.
NODE_NAME_OVERRIDE="$(hostname -s)"
sudo k0s install worker --token-file  $HOME/token-file --kubelet-extra-args="--max-pods=243 --node-status-update-frequency=1s --resolv-conf=/run/systemd/resolve/resolv.conf --hostname-override=${NODE_NAME_OVERRIDE}" $LABEL_ARGS >>"$LOG_FILE"
sudo k0s start
