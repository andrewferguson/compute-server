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
outfile=${2:-nodes.json}    # destination file

# open the root object

for node in $(seq 1  $((nodes))); do
  left_net=$node
  right_net=$(( node + 99 ))

  # open this node’s object
  printf 'node%d: {' "$((node-1))" >> "$outfile"

  for host in $(seq 2 254); do
    left_ip="192.168.${left_net}.${host}"
    right_ip="192.168.${right_net}.${host}"
    # print a "key":"value" pair
    printf '    "%s": "%s"' "$left_ip" "$right_ip" >> "$outfile"
    # comma between pairs except after .254
    [[ $host -lt 254 ]] && printf ',' >> "$outfile"
  done
  printf '  }' >> "$outfile"
  printf ',\n' >> "$outfile"
done


echo "✅  Generated: $outfile"
