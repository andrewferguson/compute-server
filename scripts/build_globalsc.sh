#!/bin/bash
exec >> /local/build.log
exec 2>&1

NUM_OUTER_NODES="$1"

# Add the routes to the inner nodes
for (( i=0; i<NUM_OUTER_NODES; i++ )); do
  DEST_NET=$((1 + i))
  GW_NET=$((1 + i))
  echo "Adding route: 10.2.${DEST_NET}.0/24 via 10.1.${GW_NET}.1"
  sudo ip route add 10.2."${DEST_NET}".0/24 via 10.1."${GW_NET}".1
done

# Setup ssh keys. install_shared_experiment_key also drops a node-local copy
# and a system ssh_config entry, so any account on this node can reach the inner
# VMs with a bare 'ssh 10.2.N.2' instead of needing the startup account's key.
source /local/repository/scripts/experiment_ssh_key.sh
materialize_experiment_key \
    || { echo "FATAL: could not materialize the experiment SSH key"; exit 1; }
install_shared_experiment_key \
    || { echo "FATAL: could not install the node-local shared experiment key"; exit 1; }

# Join the k8s cluster
EXPECTED_HOSTNAME="globalsc" bash /local/repository/scripts/worker_install_k0.sh
