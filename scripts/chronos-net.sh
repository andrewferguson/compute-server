#!/bin/bash
# Boot-time wrapper for the host network setup (chronos-net.service).
#
# Waits for the two things Emulab sets up asynchronously, both of which
# network-online.target does NOT imply:
#
#   1. The experimental vlan* interface with an IPv4 address. add-secondary.sh
#      derives everything from it; run too early it finds no interface, adds no
#      aliases, and exits 0 -- a silent no-op.
#   2. The final hostname. set_ip.sh keys off `hostname -s` to decide which
#      block in nodes.json is local. Run while the hostname is still "localhost"
#      it matches nothing, treats every block as remote, and writes the local
#      node's DNAT rules backwards.
#
# Observed on a real power cycle: unit started at 10:44:01 with the hostname set
# to <localhost> at 10:43:56 and the vlan interface not confirmed up until
# 10:44:16, producing 0 aliases and 1518 NAT rules instead of 254 and 1265.
set -uo pipefail

WAIT_TIMEOUT="${CHRONOS_NET_WAIT_TIMEOUT:-300}"
CHRONOS_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[chronos-net] $*"; }

elapsed=0
while true; do
    vlan_iface=$(ip -o -4 addr show | awk '$2 ~ /^vlan/ {print $2; exit}')
    short_host=$(hostname -s)

    if [ -n "$vlan_iface" ] && [[ "$short_host" =~ ^node[0-9]+$ ]]; then
        log "ready after ${elapsed}s: iface=${vlan_iface} hostname=${short_host}"
        break
    fi

    if [ "$elapsed" -ge "$WAIT_TIMEOUT" ]; then
        log "FATAL: after ${WAIT_TIMEOUT}s still not ready (iface='${vlan_iface:-none}' hostname='${short_host}')"
        log "Refusing to run: add-secondary.sh would add nothing and set_ip.sh would write reversed rules."
        exit 1
    fi

    sleep 5
    elapsed=$((elapsed + 5))
done

log "Restoring host secondary IPs"
"${CHRONOS_BIN}/add-secondary.sh" || { log "FATAL: add-secondary.sh failed"; exit 1; }

log "Restoring NAT rules"
"${CHRONOS_BIN}/set_ip.sh" || { log "FATAL: set_ip.sh failed"; exit 1; }

log "done"
