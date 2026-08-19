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
# The guest must be created with no password at all: passing --password is what
# makes cloud-init enable PasswordAuthentication in the guest.
! grep -qF -- '--password' "${BUILD_KERNEL_SCRIPT}"
grep -qF -- '--ssh-public-key-file "${CHRONOS_GUEST_AUTH_KEYS}"' "${BUILD_KERNEL_SCRIPT}"

# The unpatched, rdtscp-advertising domain must never be waited on -- it cannot
# boot on a custom_tsc host. It gets destroyed before the XML patch instead.
! grep -qF 'accept key-based SSH before VM patch/restart' "${BUILD_KERNEL_SCRIPT}"
! grep -qF 'cloud-init status --wait' "${BUILD_KERNEL_SCRIPT}"
! grep -qF 'ssh-keygen -A' "${BUILD_KERNEL_SCRIPT}"
grep -qF 'Stopping ${VM_NAME} before it boots on an unpatched CPU model' "${BUILD_KERNEL_SCRIPT}"

# Readiness is still gated, but only on the patched boot that can survive.
grep -qF 'never accepted key-based SSH on ${INTERNAL_IP} after restart' "${BUILD_KERNEL_SCRIPT}"
grep -qF 'enforce_guest_key_only_ssh "ubuntu@${INTERNAL_IP}"' "${BUILD_KERNEL_SCRIPT}"
! grep -qF 'ssh-keygen -q -t rsa -N' "${BUILD_KERNEL_SCRIPT}"
grep -qF 'scp $SSH_OPTS "${HOME}/.ssh/id_rsa" ubuntu@"${INTERNAL_IP}":/home/ubuntu/.ssh/id_rsa' "${BUILD_KERNEL_SCRIPT}"

grep -qF 'install_deps' "${WORKER_SCRIPT}"
grep -qF 'install_k0s' "${WORKER_SCRIPT}"
grep -qF 'retry_cmd_until_token_file_ready' "${WORKER_SCRIPT}"
grep -qF ': "${RETRY_BUDGET_SECS:=3600}"' "${WORKER_SCRIPT}"
! grep -qF 'sshpass' "${WORKER_SCRIPT}"
! grep -qF 'ssh-copy-id' "${WORKER_SCRIPT}"
grep -qF 'scp ${SCP_OPTS} "$remote" "$target"' "${WORKER_SCRIPT}"
! grep -qF 'for (( ; ; )); do' "${WORKER_SCRIPT}"

# The shared experiment key must be reachable by every account on the node, not
# just the one CloudLab runs startup services as.
KEY_SCRIPT="${ROOT_DIR}/scripts/experiment_ssh_key.sh"
GLOBALSC_SCRIPT="${ROOT_DIR}/scripts/build_globalsc.sh"
PROXY_SCRIPT="${ROOT_DIR}/scripts/build_proxy.sh"

grep -qF 'chown nobody:nogroup "${CHRONOS_SHARED_KEY}"' "${KEY_SCRIPT}"
grep -qF 'chmod 644 "${CHRONOS_SHARED_KEY}"' "${KEY_SCRIPT}"
grep -qF '/etc/ssh/ssh_config.d/50-chronos.conf' "${KEY_SCRIPT}"
grep -qF 'sudo bash -c ' "${KEY_SCRIPT}"
grep -qF '01-chronos-no-password.conf' "${KEY_SCRIPT}"
grep -qF "grep -qx 'passwordauthentication no'" "${KEY_SCRIPT}"

for script in "${BUILD_KERNEL_SCRIPT}" "${GLOBALSC_SCRIPT}" "${PROXY_SCRIPT}"; do
  grep -qF 'source /local/repository/scripts/experiment_ssh_key.sh' "${script}"
  grep -qF 'install_shared_experiment_key' "${script}"
  ! grep -qF 'geni-get key > ${HOME}/.ssh/id_rsa' "${script}"
done
