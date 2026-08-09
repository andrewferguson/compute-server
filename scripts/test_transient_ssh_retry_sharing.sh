#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RETRY_HELPERS_SCRIPT="${ROOT_DIR}/scripts/retry_helpers.sh"
VERIFY_SCRIPT="${ROOT_DIR}/scripts/verify_node.sh"
WORKER_SCRIPT="${ROOT_DIR}/scripts/worker_install_k0.sh"

grep -qF 'is_retryable_controller_transport_error()' "${RETRY_HELPERS_SCRIPT}"

! grep -qF 'is_retryable_controller_transport_error() {' "${VERIFY_SCRIPT}"
grep -qF 'source /local/repository/scripts/retry_helpers.sh' "${VERIFY_SCRIPT}"
grep -qF 'is_retryable_controller_transport_error "${out}"' "${VERIFY_SCRIPT}"

grep -qF 'is_retryable_controller_transport_error "${ssh_copy_output}"' "${WORKER_SCRIPT}"
grep -qF 'is_retryable_controller_transport_error "${scp_output}"' "${WORKER_SCRIPT}"
