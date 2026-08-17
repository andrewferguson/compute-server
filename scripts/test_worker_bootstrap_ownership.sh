#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_KERNEL_SCRIPT="${ROOT_DIR}/scripts/build_kernel.sh"
WORKER_SCRIPT="${ROOT_DIR}/scripts/worker_install_k0.sh"
COMMON_SCRIPT="${ROOT_DIR}/scripts/common_k0.sh"

! grep -qF 'sshpass' "${COMMON_SCRIPT}"

! grep -qF 'source /tmp/retry_helpers.sh && apt_get_update_soft && apt_get_retry install sshpass' "${BUILD_KERNEL_SCRIPT}"
! grep -qF 'sshpass -p 1997 ssh-copy-id $SSH_OPTS ubuntu@10.2.1.2' "${BUILD_KERNEL_SCRIPT}"
! grep -qF 'apt_get_retry install sshpass' "${BUILD_KERNEL_SCRIPT}"
grep -qF -- '--password chronos' "${BUILD_KERNEL_SCRIPT}"
grep -qF -- '--ssh-public-key-file "${HOME}/.ssh/id_rsa.pub"' "${BUILD_KERNEL_SCRIPT}"
grep -qF 'cloud-init status --wait' "${BUILD_KERNEL_SCRIPT}"
! grep -qF 'ssh-keygen -q -t rsa -N' "${BUILD_KERNEL_SCRIPT}"
grep -qF 'scp $SSH_OPTS "${HOME}/.ssh/id_rsa" ubuntu@"${INTERNAL_IP}":/home/ubuntu/.ssh/id_rsa' "${BUILD_KERNEL_SCRIPT}"

grep -qF 'install_deps' "${WORKER_SCRIPT}"
grep -qF 'install_k0s' "${WORKER_SCRIPT}"
grep -qF 'retry_cmd_until_token_file_ready' "${WORKER_SCRIPT}"
! grep -qF 'sshpass' "${WORKER_SCRIPT}"
! grep -qF 'ssh-copy-id' "${WORKER_SCRIPT}"
grep -qF 'scp ${SCP_OPTS} "$remote" "$target"' "${WORKER_SCRIPT}"
! grep -qF 'for (( ; ; )); do' "${WORKER_SCRIPT}"
