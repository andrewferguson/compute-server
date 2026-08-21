#!/usr/bin/env bash
#
# add-secondary-ips.sh
# Adds .3-.254/16 to whichever interface already has *.2/16, and adds the routes
# this guest needs to reach the rest of the experiment.
#
# Runs on EVERY guest boot via chronos-guest-net.service, not just at provision:
# guest addresses and routes are runtime-only and a VM restart discards them.
# It must therefore be re-runnable, which is why the routes use `ip route
# replace` (plain `add` fails with EEXIST, and under `set -e` that aborted the
# script before the 10.3/10.4 routes were ever added).
set -euo pipefail

# 1. Discover the interface that owns *.2, waiting for DHCP to finish. At boot
#    this unit can start before the lease is granted; without the wait the
#    script exits 1 and the guest comes up with no secondary addresses.
primary_if=""
for _ in $(seq 1 60); do
  primary_if=$(ip -o -4 addr | awk '$4 ~ /\.2\/16$/ {print $2; exit}')
  [[ -n $primary_if ]] && break
  sleep 2
done
[[ -z $primary_if ]] && {
  echo "Couldn't find an interface with x.x.x.2/16 after 120s" >&2
  exit 1
}

# 2. Derive the /24 network prefix (e.g. 192.168.10)
prefix=$(ip -o -4 addr show "$primary_if" \
           | awk '$4 ~ /\.2\/16$/ {sub(/\.2\/16/,"",$4); print $4}')

echo "Interface: $primary_if  —  Network: ${prefix}.0/16"

# 3. Add .3-.254
for i in $(seq 3 254); do
  ip addr add "${prefix}.${i}/16" dev "$primary_if" 2>/dev/null \
    && echo "Added ${prefix}.${i}" \
    || echo "⚠️  ${prefix}.${i} already present or failed"
done

IFACE="enp1s0"

# Extract the current IP address of the interface, taking the first: by this
# point the interface carries .2 through .254.
#
# Deliberately NOT piped into `head -1`. This script runs under `set -euo
# pipefail`, and head exits after one line while grep is still emitting 253 --
# grep then takes SIGPIPE, the pipeline reports 141, and set -e aborts the whole
# script before the routes below are ever added. Trim the first line in the
# shell instead, where nothing can close a pipe early.
IP_ADDR=$(ip -4 addr show "$IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
IP_ADDR=${IP_ADDR%%$'\n'*}

# Check if IP was found
if [[ -z "$IP_ADDR" ]]; then
    echo "No IP address found on interface $IFACE"
    exit 1
fi

# Derive the gateway IP assuming it is the .1 of the subnet (e.g., 10.2.1.1)
IFS='.' read -r o1 o2 o3 o4 <<< "$IP_ADDR"
GATEWAY="10.2.$o3.1"

# Add routes to the other experiment subnets: other inner VMs (10.2.0.0/16),
# proxy nodes (10.3.0.0/16), and the globalsc node (10.4.0.0/16). Without
# these, this VM can only ever reach its own outer node's bridge -- needed so
# the controller VM can SSH out to proxy-*/globalsc to distribute images.
for DEST in "10.2.0.0/16" "10.3.0.0/16" "10.4.0.0/16"; do
  echo "Adding route to $DEST via $GATEWAY on $IFACE"
  ip route replace "$DEST" via "$GATEWAY" dev "$IFACE"
done
