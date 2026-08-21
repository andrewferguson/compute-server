#!/bin/bash
exec >> /local/build.log
exec 2>&1
# Color output
GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'
if ! test -t 1; then
    GREEN=""
    BLUE=""
    NC=""
fi

function step_log() {
    echo ""
    echo "====================[ $1 ]===================="
    date
    if [ -n "$2" ]; then
        echo ""
        echo "$2"
    fi
    echo ""
}
NUM_OUTER_NODES="$1"
PROXY_NODE_ID="$2"

source /local/repository/scripts/retry_helpers.sh
apt_get_update_soft
apt_get_retry install -qq libsctp-dev lksctp-tools zlib1g-dev
sudo modprobe sctp
for (( i=0; i<NUM_OUTER_NODES; i++ )); do
  DEST_NET=$((1 + i))
  GW_NET=$((1 + i))
  echo "Adding route: 10.2.${DEST_NET}.0/24 via 10.1.${GW_NET}.1"
  sudo ip route replace 10.2."${DEST_NET}".0/24 via 10.1."${GW_NET}".1
done

# Setup ssh keys. install_shared_experiment_key also drops a node-local copy
# and a system ssh_config entry, so any account on this node can reach the inner
# VMs with a bare 'ssh 10.2.N.2' instead of needing the startup account's key.
source /local/repository/scripts/experiment_ssh_key.sh
materialize_experiment_key \
    || { echo "FATAL: could not materialize the experiment SSH key"; exit 1; }
install_shared_experiment_key \
    || { echo "FATAL: could not install the node-local shared experiment key"; exit 1; }

# Get the interface for this proxy machine
primary_if=$(ip -o -4 addr | awk '$4 ~ inet 10.3 {print $2; exit}')

# Add the IP addresses for the proxy instances
for i in $(seq 1 254); do
  sudo ip addr add "10.3.$(($PROXY_NODE_ID + 1)).$i/24" dev "$primary_if"
done

# Update the hostname (used as node name in k8s)
until sudo hostnamectl set-hostname "proxy-$PROXY_NODE_ID"
do
  echo "Failed to set hostname..."
  sleep 5
done

# Join the k8s cluster
bash /local/repository/scripts/worker_install_k0.sh
