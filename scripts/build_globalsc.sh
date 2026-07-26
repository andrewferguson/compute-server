#!/bin/bash
exec >> /local/build.log
exec 2>&1

NUM_OUTER_NODES="$1"
EXPECTED_HOSTNAME="globalsc"

set_expected_hostname() {
  sudo hostnamectl hostname "${EXPECTED_HOSTNAME}" --static
  sudo hostnamectl hostname "${EXPECTED_HOSTNAME}" --transient
}

hostname_is_settled() {
  [ "$(hostname)" = "${EXPECTED_HOSTNAME}" ] \
    && [ "$(hostnamectl --static)" = "${EXPECTED_HOSTNAME}" ] \
    && [ "$(hostnamectl --transient)" = "${EXPECTED_HOSTNAME}" ]
}

# Add the routes to the inner nodes
for (( i=0; i<NUM_OUTER_NODES; i++ )); do
  DEST_NET=$((1 + i))
  GW_NET=$((1 + i))
  echo "Adding route: 10.2.${DEST_NET}.0/24 via 10.1.${GW_NET}.1"
  sudo ip route add 10.2."${DEST_NET}".0/24 via 10.1."${GW_NET}".1
done

# Setup ssh keys
geni-get key > ${HOME}/.ssh/id_rsa
chmod 600 ${HOME}/.ssh/id_rsa
ssh-keygen -y -f ${HOME}/.ssh/id_rsa > ${HOME}/.ssh/id_rsa.pub
grep -q -f ${HOME}/.ssh/id_rsa.pub ${HOME}/.ssh/authorized_keys || cat ${HOME}/.ssh/id_rsa.pub >> ${HOME}/.ssh/authorized_keys

until set_expected_hostname && hostname_is_settled
do
  echo "Failed to settle hostname as ${EXPECTED_HOSTNAME}..."
  sleep 5
done

echo "Hostname settled as $(hostname)"

# Join the k8s cluster
bash /local/repository/scripts/worker_install_k0.sh
