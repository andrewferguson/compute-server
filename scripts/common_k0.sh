#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# Redirect stdout/stderr to file
exec >> $LOG_FILE
exec 2>&1

LOG_DIR="$HOME"
K0S_VERSION="v1.27.13+k0s.0"
K0S_BIN="/usr/local/bin/k0s"

# Shared retry wrappers. On the outer/bare-metal nodes this file lives beside us in
# the repo; inside a guest VM it is copied next to us into /tmp by build_kernel.sh.
_CK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${_CK_DIR}/retry_helpers.sh" ]; then
  source "${_CK_DIR}/retry_helpers.sh"
elif [ -f /local/repository/scripts/retry_helpers.sh ]; then
  source /local/repository/scripts/retry_helpers.sh
else
  echo "FATAL: retry_helpers.sh not found next to common_k0.sh or in the repository" >&2
  exit 1
fi

# Packages every k0s node needs. install_deps verifies each is actually present.
K0S_REQUIRED_PKGS="curl conntrack socat ebtables iptables iputils-ping nano iperf3 libsctp-dev lksctp-tools zlib1g-dev"

log()  { echo -e "[\e[34mINFO\e[0m] $*"; }
fail() { echo -e "[\e[31mFAIL\e[0m] $*"; exit 1; }

install_deps() {
  # Retry the whole install (lock-tolerant) and then verify every required package
  # is genuinely installed, so a partial install can never be mistaken for success.
  log "Installing prerequisites"
  apt_get_update_soft
  apt_get_retry install -qq $K0S_REQUIRED_PKGS
  local pkg
  for pkg in $K0S_REQUIRED_PKGS; do
    dpkg -s "$pkg" >/dev/null 2>&1 || _retry_die "package failed to install: $pkg"
  done
  sudo modprobe sctp || true
  log "Enabling br_netfilter (which needs to be done manually now for some unknown reason...)"
  sudo modprobe br_netfilter
  echo "br_netfilter" | sudo tee /etc/modules-load.d/br_netfilter.conf
  log "Installing Helm"
  retry_pipe "install helm" \
    "curl -fsSL --connect-timeout ${DOWNLOAD_CONNECT_TIMEOUT} --max-time ${DOWNLOAD_ATTEMPT_TIMEOUT} https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
  command -v helm >/dev/null 2>&1 || _retry_die "helm missing after install"
}

install_k0s() {
  # Skip the download when the correct version is already installed.
  #
  # get.k0s.sh writes IN PLACE to $K0S_BIN. If k0sworker is running, that is the
  # binary it is executing, so the write fails with ETXTBSY ("Text file busy") --
  # and because the call below is wrapped in retry_pipe it does not fail fast, it
  # retries against RETRY_BUDGET_SECS. Observed on a real proxy power cycle:
  # attempt 122 and climbing, an hour of spinning, then the node reported failed,
  # while it was healthy and Ready in k8s the entire time.
  #
  # Compared without a pipe: this file runs under `set -o pipefail`, where
  # `k0s version | grep -q` can return 141 when grep exits first and k0s takes
  # SIGPIPE.
  local installed=""
  if [ -x "$K0S_BIN" ] || command -v k0s >/dev/null 2>&1; then
    installed="$(k0s version 2>/dev/null || true)"
    installed="${installed%%$'\n'*}"
  fi
  if [ "${installed}" = "${K0S_VERSION}" ]; then
    log "k0s ${K0S_VERSION} already installed; skipping download"
  else
  log "Installing k0s ($K0S_VERSION)"
  retry_pipe "install k0s binary" \
    "curl -sSLf --connect-timeout ${DOWNLOAD_CONNECT_TIMEOUT} --max-time ${DOWNLOAD_ATTEMPT_TIMEOUT} https://get.k0s.sh | sudo K0S_VERSION='${K0S_VERSION}' sh"
  command -v k0s >/dev/null 2>&1 || [ -x "$K0S_BIN" ] || _retry_die "k0s binary missing after install"
  fi
  # Download and install the standard CNI plugins
  sudo mkdir -p /opt/cni/bin
  retry_pipe "download cni plugins" \
    "curl -L --connect-timeout ${DOWNLOAD_CONNECT_TIMEOUT} --max-time ${DOWNLOAD_ATTEMPT_TIMEOUT} https://github.com/containernetworking/plugins/releases/download/v1.4.0/cni-plugins-linux-amd64-v1.4.0.tgz | sudo tar -xz -C /opt/cni/bin"
  sudo test -x /opt/cni/bin/bridge || _retry_die "cni plugins missing after extract"
}

