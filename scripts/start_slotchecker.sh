#!/bin/bash

# Extract numeric ID from hostname, e.g. node1 -> 1.
# Uses `hostname -s`: the full CloudLab FQDN is node1.chronos-debug.test5g-pg0...
# so a bare `hostname` yields "1\n5\n0" here, which only ever worked because
# atoi() stops at the first newline.
C_ID=$(hostname -s | grep -o '[0-9]\+' | head -1)

# exec so systemd supervises the checker itself rather than this wrapper.
# No sudo: the unit already runs as root.
exec taskset -c 2 chrt -f 99 /local/chronos/bin/slotcheckerservice "$C_ID"
