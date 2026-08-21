#!/usr/bin/env bash
# gen-node-maps.sh  <node-count>  [output-file]
#
# Example:
#   sudo bash gen-node-maps.sh 4        # → nodes.json
#   sudo bash gen-node-maps.sh 3  map.json
#
# Result (truncated):
# {
#   "node1": {
#     "192.168.1.2": "192.168.10.2",
#     ...
#     "192.168.1.254": "192.168.10.254"
#   },
#   "node2": {
#     "192.168.2.2": "192.168.11.2",
#     ...
#   },
#   ...
# }
set -euo pipefail

nodes=${1:-1}               # how many node blocks to emit
# Destination file. Defaults to the persistent location rather than the CWD:
# this used to land in /local/repository/scripts, which CloudLab re-clones on
# every boot, so the map vanished and set_ip.sh silently produced no rules.
outfile=${2:-${CHRONOS_NODES_JSON:-/local/chronos/etc/nodes.json}}

mkdir -p "$(dirname "$outfile")"

# Truncate first. Every write below appends, so without this a second run would
# append a whole duplicate set of node blocks and corrupt the file for set_ip.sh.
: > "$outfile"

# open the root object

for node in $(seq 1  $((nodes))); do
  left_net=$node
  right_net=$(( node ))

  # open this node’s object
  printf 'node%d: {' "$((node-1))" >> "$outfile"

  for host in $(seq 2 254); do
    left_ip="10.1.${left_net}.${host}"
    right_ip="10.2.${right_net}.${host}"
    # print a "key":"value" pair
    printf '    "%s": "%s"' "$left_ip" "$right_ip" >> "$outfile"
    # comma between pairs except after .254
    [[ $host -lt 254 ]] && printf ',' >> "$outfile"
  done
  printf '  }' >> "$outfile"
  printf ',\n' >> "$outfile"
done


echo "✅  Generated: $outfile"
