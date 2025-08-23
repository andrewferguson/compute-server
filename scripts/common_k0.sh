#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# Redirect stdout/stderr to file
exec >> $LOG_FILE
exec 2>&1

LOG_DIR="/home/ubuntu"
K0S_VERSION_CHANNEL="stable"
K0S_BIN="/usr/local/bin/k0s"

log()  { echo -e "[\e[34mINFO\e[0m] $*"; }
fail() { echo -e "[\e[31mFAIL\e[0m] $*"; exit 1; }

install_deps() {
  # Only complete once the dependencies have actually installed
  # Blame the stupid "unattended-upgrades" for this - it occasionally prevents apt install from working
  until apt list --installed | grep libsctp-dev; do
    install_deps_single
  done
}

install_deps_single() {
  log "Installing prerequisites"
  sudo apt-get update -qq || true
  sudo apt-get install -yqq curl conntrack socat ebtables iptables iputils-ping nano iperf3 libsctp-dev lksctp-tools zlib1g-dev || true
  sudo modprobe sctp || true
  log "Installing Helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >>"$LOG_FILE"
}

install_k0s() {
  log "Installing k0s ($K0S_VERSION_CHANNEL)"
  curl -sSLf https://get.k0s.sh | sudo bash -s -- "$K0S_VERSION_CHANNEL" >>"$LOG_FILE"
    # Download and install the standard CNI plugins
  sudo mkdir -p /opt/cni/bin
  curl -L https://github.com/containernetworking/plugins/releases/download/v1.4.0/cni-plugins-linux-amd64-v1.4.0.tgz \
    | sudo tar -xz -C /opt/cni/bin

}

wait_for_token() {         # $1 = controller_ip
  local ctl_ip="10.2.1.2"; local token=""
  log "Waiting for join token from $ctl_ip ..."
  for _ in {1..30}; do
      token=$(ssh -oStrictHostKeyChecking=no ubuntu@"$ctl_ip" cat /home/ubuntu/token-file 2>/dev/null || true)
      [[ -n "$token" ]] && { echo "$token"; return 0; }
      sleep 5
  done
  return 1
}


