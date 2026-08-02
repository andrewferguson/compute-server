#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKER_SCRIPT="${ROOT_DIR}/scripts/worker_install_k0.sh"
GLOBALSC_SCRIPT="${ROOT_DIR}/scripts/build_globalsc.sh"

require_line() {
  local pattern="$1"
  local file="$2"
  grep -nF "$pattern" "$file" | cut -d: -f1 | tail -n1
}

worker_hostname_line="$(require_line 'ensure_expected_hostname' "${WORKER_SCRIPT}")"
worker_join_log_line="$(require_line 'log "Joining cluster with token"' "${WORKER_SCRIPT}")"
worker_install_line="$(require_line 'sudo k0s install worker' "${WORKER_SCRIPT}")"
worker_start_line="$(require_line 'sudo k0s start' "${WORKER_SCRIPT}")"

[[ -n "${worker_hostname_line}" ]]
[[ -n "${worker_join_log_line}" ]]
[[ -n "${worker_install_line}" ]]
[[ -n "${worker_start_line}" ]]
[[ "${worker_hostname_line}" -gt "${worker_join_log_line}" ]]
[[ "${worker_hostname_line}" -lt "${worker_install_line}" ]]
[[ "${worker_install_line}" -lt "${worker_start_line}" ]]

grep -qF 'EXPECTED_HOSTNAME="globalsc" bash /local/repository/scripts/worker_install_k0.sh' "${GLOBALSC_SCRIPT}"
! grep -qF 'set_expected_hostname()' "${GLOBALSC_SCRIPT}"
! grep -qF 'hostname_is_settled()' "${GLOBALSC_SCRIPT}"
