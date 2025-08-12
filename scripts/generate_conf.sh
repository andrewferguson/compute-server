#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Usage:  ./make_ips.sh <filename> <machine_count> <repeat_count>
# Example ./make_ips.sh iplist.txt 5 3
#   → iplist.txt  : 5 IPs (192.168.10.2-14.2) repeated 3×
#   → component   : 5 component IPs (192.168.1.1-5.1)
# -----------------------------------------------------------------------------

set -euo pipefail

# ---- argument checks --------------------------------------------------------
if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <filename> <machine_count> <repeat_count>" >&2
  exit 1
fi

filename=$1
machine_count=$2
repeat_count=$3

for arg in "$machine_count" "$repeat_count"; do
  if ! [[ $arg =~ ^[0-9]+$ ]] || [[ $arg -lt 1 ]]; then
    echo "Error: <machine_count> and <repeat_count> must be positive integers." >&2
    exit 1
  fi
done

# ---- build blocks -----------------------------------------------------------
ip_block=$(
  for ((i=0; i<machine_count; i++)); do
    printf '192.168.%d.2\n' $((100 + i))
  done
)

component_block=$(
  for ((i=1; i<=machine_count; i++)); do
    printf '192.168.%d.1\n' "$i"
  done
)

# ---- write primary IP list --------------------------------------------------
: > "$filename"                # truncate/create
for ((r=0; r<repeat_count; r++)); do
  echo -e "$ip_block" >> "$filename"
done

# ---- write component list ---------------------------------------------------
echo -e "$component_block" > component

echo "Created '$filename' with $machine_count IPs repeated $repeat_count time(s)."
echo "Created 'component' with $machine_count component IP(s)."
