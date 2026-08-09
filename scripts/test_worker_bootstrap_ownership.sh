#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_KERNEL_SCRIPT="${ROOT_DIR}/scripts/build_kernel.sh"
WORKER_SCRIPT="${ROOT_DIR}/scripts/worker_install_k0.sh"
COMMON_SCRIPT="${ROOT_DIR}/scripts/common_k0.sh"

grep -qF 'K0S_REQUIRED_PKGS="curl conntrack socat ebtables iptables iputils-ping nano iperf3 libsctp-dev lksctp-tools zlib1g-dev sshpass"' "${COMMON_SCRIPT}"

! grep -qF 'source /tmp/retry_helpers.sh && apt_get_update_soft && apt_get_retry install sshpass' "${BUILD_KERNEL_SCRIPT}"
! grep -qF 'sshpass -p 1997 ssh-copy-id $SSH_OPTS ubuntu@10.2.1.2' "${BUILD_KERNEL_SCRIPT}"

grep -qF 'install_deps' "${WORKER_SCRIPT}"
grep -qF 'install_k0s' "${WORKER_SCRIPT}"
grep -qF 'retry_cmd_until_token_file_ready' "${WORKER_SCRIPT}"
! grep -qF 'for (( ; ; )); do' "${WORKER_SCRIPT}"
