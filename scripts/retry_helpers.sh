#!/usr/bin/env bash
# retry_helpers.sh — shared retry wrappers for the Chronos CloudLab bootstrap.
#
# Two classes of transient failure repeatedly break experiment creation:
#   1. apt-lock contention  — unattended-upgrades/apt-daily hold the dpkg/lists lock
#                             on a freshly-booted node, so a bare `apt-get` fails.
#   2. network-download timeouts — GitHub, cloud-images and package mirrors
#                             occasionally time out or reset mid-transfer.
# Both are transient, so every occurrence must retry until it genuinely succeeds
# rather than aborting immediately or silently continuing with a half-installed node.
#
# Policy (see iteration-3.md): each individual occurrence gets a bounded retry
# budget (default 5 minutes). Within that window it retries with backoff; if it
# still has not succeeded it HARD-FAILS LOUDLY (prints FATAL + exit 1) so the
# experiment surfaces as failed instead of hanging forever or looking healthy.
#
# Downloads use a per-attempt timeout that is shorter than the budget, so a single
# hung transfer cannot consume the whole budget (this is exactly what defeated the
# k0s download in iteration 3: one curl blocked for the full 300s and never retried).
#
# Source this file; do not execute it.

# Guard against double-sourcing (scripts may source it transitively).
if [ -n "${__CHRONOS_RETRY_HELPERS_SOURCED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
__CHRONOS_RETRY_HELPERS_SOURCED=1

# Per-occurrence retry budget, in seconds (bounded-but-large).
: "${RETRY_BUDGET_SECS:=300}"
# Delay between attempts, in seconds.
: "${RETRY_DELAY_SECS:=5}"
# Per-attempt download timeouts (kept < budget so multiple attempts fit).
: "${DOWNLOAD_CONNECT_TIMEOUT:=30}"
: "${DOWNLOAD_ATTEMPT_TIMEOUT:=180}"

_retry_log() { echo "[retry $(date '+%H:%M:%S')] $*" >&2; }

_retry_die() {
  _retry_log "FATAL: giving up on: $* (exhausted ${RETRY_BUDGET_SECS}s budget)"
  exit 1
}

# _retry_engine <desc> <cmd...>
# Runs the command, retrying with backoff until it succeeds or the budget expires.
# Returns 0 on success, 1 on budget exhaustion. Does not die (callers decide).
_retry_engine() {
  local desc="$1"; shift
  local deadline=$(( $(date +%s) + RETRY_BUDGET_SECS ))
  local attempt=0
  while :; do
    attempt=$((attempt + 1))
    if "$@"; then
      [ "$attempt" -gt 1 ] && _retry_log "OK after ${attempt} attempts: ${desc}"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      return 1
    fi
    _retry_log "attempt ${attempt} failed; retrying in ${RETRY_DELAY_SECS}s: ${desc}"
    sleep "$RETRY_DELAY_SECS"
  done
}

# retry_cmd <desc> <cmd...> — retry a plain command; die loudly on exhaustion.
retry_cmd() {
  local desc="$1"; shift
  _retry_engine "$desc" "$@" || _retry_die "$desc"
}

# apt_get_retry <apt-get args...> — lock-tolerant, retrying apt-get; die on exhaustion.
# DPkg::Lock::Timeout makes each attempt wait for the dpkg lock; the retry loop
# additionally covers the apt/lists lock (which returns non-zero rather than waiting).
apt_get_retry() {
  _retry_engine "apt-get $*" \
    sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 -y "$@" \
    || _retry_die "apt-get $*"
}

# apt_get_update_soft — like apt_get_retry update but non-fatal: a persistently
# failing `apt-get update` (e.g. one unreachable optional repo) should not abort
# the bootstrap on its own; the subsequent verified install is the real gate.
apt_get_update_soft() {
  _retry_engine "apt-get update" \
    sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 -y update \
    || _retry_log "apt-get update did not fully succeed within budget; continuing"
}

# retry_pipe <desc> <pipeline-string> — retry a shell pipeline under pipefail so a
# failure anywhere in the pipe (not just the last stage) triggers a retry.
retry_pipe() {
  local desc="$1" pipeline="$2"
  _retry_engine "$desc" bash -c "set -o pipefail; ${pipeline}" || _retry_die "$desc"
}

# download_file <url> <dest> — download a URL to a file with a bounded per-attempt
# timeout, retrying within budget; verifies the destination is non-empty. Uses sudo
# so it can write to system paths (e.g. /usr/bin).
_download_once() {
  local url="$1" dest="$2"
  sudo curl -fSL --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" --max-time "$DOWNLOAD_ATTEMPT_TIMEOUT" \
    -o "$dest" "$url" && sudo test -s "$dest"
}
download_file() {
  local url="$1" dest="$2"
  _retry_engine "download ${url} -> ${dest}" _download_once "$url" "$dest" \
    || _retry_die "download ${url}"
}

# git_clone_retry <url> <dest> [git args...] — remove any partial clone, then clone,
# retrying within budget; die on exhaustion.
#
# Forces HTTP/1.1 for the transfer: the transient failure that repeatedly skips a
# node's whole setup is GitHub's HTTP/2 framing bug ("curl 16 Error in the HTTP2
# framing layer" / "error reading section header 'shallow-info'"), which HTTP/1.1
# is immune to. The retry loop still covers ordinary network resets on top of this.
_git_clone_once() {
  local url="$1" dest="$2"; shift 2
  rm -rf "$dest" 2>/dev/null || sudo rm -rf "$dest" 2>/dev/null || true
  git -c http.version=HTTP/1.1 clone "$@" "$url" "$dest"
}
git_clone_retry() {
  local url="$1" dest="$2"; shift 2
  _retry_engine "git clone ${dest}" _git_clone_once "$url" "$dest" "$@" \
    || _retry_die "git clone ${dest}"
}
