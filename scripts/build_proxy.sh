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
NUM_MACHINE="$2"
GITHUB_USERNAME="$3"
kernel_repo="andrewferguson/phobos-proxy"
  sudo apt update 
  sudo apt-get install -yqq libsctp-dev lksctp-tools  zlib1g-dev
  sudo modprobe sctp
phobos_link="https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com/${kernel_repo}.git"
git clone --quiet "${phobos_link}" ~/phobos-proxy
cd ~/phobos-proxy
for (( i=0; i<NUM_MACHINE; i++ )); do
  DEST_NET=$((1 + i))
  GW_NET=$((1 + i))
  echo "Adding route: 10.2.${DEST_NET}.2 via 10.1.${GW_NET}.1"
  sudo ip route add 10.2."${DEST_NET}".2 via 10.1."${GW_NET}".1
done
make -j
sudo cp /local/repository/scripts/generate_conf.sh ~/
cd ~/
sudo chmod +x generate_conf.sh

