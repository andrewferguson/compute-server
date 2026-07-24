#!/usr/bin/env bash
#
# add-secondary-ips.sh
# Adds .3-.254/16 to whichever interface already has *.2/24.
# Run with sudo.
set -euo pipefail

# 1. Discover the interface that owns *.2
primary_if=$(ip -o -4 addr \
               | awk '$4 ~ /\.2\/16$/ {print $2; exit}')
[[ -z $primary_if ]] && {
  echo "Couldn’t find an interface with x.x.x.2/16" >&2
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

# Extract the current IP address of the interface
IP_ADDR=$(ip -4 addr show "$IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

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
  sudo ip route add "$DEST" via "$GATEWAY" dev "$IFACE"
done