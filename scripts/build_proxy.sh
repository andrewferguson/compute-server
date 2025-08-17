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
GITHUB_TOKEN="$1"
NUM_OUTER_NODES="$2"
GITHUB_USERNAME="$3"
PROXY_INSTANCE_ID="$4"

sudo apt update
sudo apt-get install -yqq libsctp-dev lksctp-tools  zlib1g-dev
sudo modprobe sctp
for (( i=0; i<NUM_OUTER_NODES; i++ )); do
  DEST_NET=$((1 + i))
  GW_NET=$((1 + i))
  echo "Adding route: 10.2.${DEST_NET}.0/24 via 10.1.${GW_NET}.1"
  sudo ip route add 10.2."${DEST_NET}".0/24 via 10.1."${GW_NET}".1
done

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

# Add the interfaces for this proxy machine
primary_if=$(ip -o -4 addr | awk '$4 ~ inet 10.3 {print $2; exit}')
for i in $(seq 2 254); do
  ip addr add "10.3.{PROXY_INSTANCE_ID}.${i}/24" dev "$primary_if"
done

sudo cp /local/repository/scripts/generate_conf.sh ~/
cd ~/
sudo chmod +x generate_conf.sh

