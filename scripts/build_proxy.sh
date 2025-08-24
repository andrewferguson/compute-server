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
GITHUB_USERNAME="$1"
GITHUB_TOKEN="$2"
NUM_OUTER_NODES="$3"
NUM_GNB_PER_NODE="$4"
PROXY_NODE_ID="$5"
NUM_PROXY_ON_THIS_NODE="$6"
FIRST_PROXY_ID="$7"
TOTAL_NUM_UE="$8"

sudo apt update
sudo apt-get install -yqq libsctp-dev lksctp-tools  zlib1g-dev
sudo modprobe sctp
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

# 4G
repo="andrewferguson/phobos-proxy"
git_url="https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com/${repo}.git"
git clone --quiet "${git_url}" ~/phobos-proxy
cd ~/phobos-proxy
make -j
cd ~/

# 5G
repo="ujjwalpawar/phobos-5g"
git_url="https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com/${repo}.git"
git clone --quiet "${git_url}" ~/phobos-5g
cd ~/phobos-5g
git checkout split
make -j
cd ~/

# Global slot checker
cd ~/phobos-5g
gcc -o global_slotchecker src/sc_global.c

# Get the interface for this proxy machine
primary_if=$(ip -o -4 addr | awk '$4 ~ inet 10.3 {print $2; exit}')

mkdir ~/run_proxy
mkdir ~/gnb_ids
mkdir ~/gnb_ips

counter=1
for i in $(seq $FIRST_PROXY_ID $(($FIRST_PROXY_ID + $NUM_PROXY_ON_THIS_NODE - 1))); do
  # Calculate the IP of the proxy instance and the gNB it connects to
  PROXY_IP="10.3.$(($PROXY_NODE_ID + 1)).$counter"
  GNB_IP="10.2.$(($i / $NUM_GNB_PER_NODE + 1)).$(($i % $NUM_GNB_PER_NODE + 2))"

  # Add the IP address for the proxy instance
  sudo ip addr add "$PROXY_IP/24" dev "$primary_if"

  # Create the run script for the proxy instance
  echo "#!/bin/bash" > "$HOME/run_proxy/$i.sh"
  echo "$HOME/phobos-5g/build/proxy $TOTAL_NUM_UE --chronos5g $HOME/gnb_ips/$i $HOME/gnb_ids/$i $i $PROXY_IP 10.4.1.1" >> "$HOME/run_proxy/$i.sh"
  chmod +x "$HOME/run_proxy/$i.sh"

  # Create the config files for the proxy instance
  echo "$GNB_IP" > "$HOME/gnb_ips/$i"
  echo "$i" > "$HOME/gnb_ids/$i"

  # Create the systemd service for the proxy instance
  # Generate the systemd service for the global sc
  cat <<EOF | sudo tee "/etc/systemd/system/proxy$i.service"
[Unit]
Description=Proxy $i
After=network.target

[Service]
ExecStart=/users/geniuser/run_proxy/$i.sh
Restart=no
User=root
WorkingDirectory=/users/geniuser/phobos-5g
KillSignal=SIGINT

[Install]
WantedBy=multi-user.target
EOF

  # Ensure systemd service is ready to be started
  sudo systemctl daemon-reload
  sudo systemctl stop proxy$i # dont start it now

  # Log what has been done
  echo "Proxy $i ($PROXY_IP), connecting to gNB $i ($GNB_IP), supporting $TOTAL_NUM_UE UEs"
  ((counter++))
done

