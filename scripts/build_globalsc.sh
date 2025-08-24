#!/bin/bash
exec >> /local/build.log
exec 2>&1

GITHUB_USERNAME="$1"
GITHUB_TOKEN="$2"
NUM_OUTER_NODES="$3"

# Setup ssh keys
geni-get key > ${HOME}/.ssh/id_rsa
chmod 600 ${HOME}/.ssh/id_rsa
ssh-keygen -y -f ${HOME}/.ssh/id_rsa > ${HOME}/.ssh/id_rsa.pub
grep -q -f ${HOME}/.ssh/id_rsa.pub ${HOME}/.ssh/authorized_keys || cat ${HOME}/.ssh/id_rsa.pub >> ${HOME}/.ssh/authorized_keys

# Clone and build the global SC
repo="ujjwalpawar/phobos-5g"
git_url="https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com/${repo}.git"
git clone --quiet "${git_url}" ~/phobos-5g
cd ~/phobos-5g
git checkout split
gcc -o global_slotchecker src/sc_global.c

# Generate the component IP list
cd ~/
for i in $(seq 1 $NUM_OUTER_NODES); do
  COMPONENT_IP="10.1.$i.1"
  echo $COMPONENT_IP >> ~/component_ips
done

# Generate the systemd service for the global sc
cat <<EOF | sudo tee /etc/systemd/system/globalsc.service
[Unit]
Description=Global Slot Checker Service
After=network.target

[Service]
ExecStart=/users/geniuser/phobos-5g/global_slotchecker 10.4.1.1 /users/geniuser/component_ips
Restart=no
User=root
WorkingDirectory=/users/geniuser/phobos-5g
KillSignal=SIGINT

[Install]
WantedBy=multi-user.target
EOF

# Ensure systemd service is ready to be started
sudo systemctl daemon-reload
sudo systemctl stop globalsc # dont start it now, else time dilation will start!

