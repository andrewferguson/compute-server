#!/bin/bash

# Redirect output to log file
exec >> /local/configuration.log
exec 2>&1

# Every node needs its experimental vlan interface (the tagged "Network" link
# from profile.py) to reach the rest of the cluster. Emulab occasionally fails
# to bring this up (a CloudLab L1/switch-port link flake) with no error of its
# own, and none of the later steps check for it, so a node can silently finish
# startup while islanded from the fabric. Check for it first, before anything
# else runs.
NET_CHECK_TIMEOUT=180
echo "Checking for experimental vlan interface (timeout ${NET_CHECK_TIMEOUT}s)..."
elapsed=0
while true; do
    vlan_iface=$(ip -o -4 addr show | awk '$2 ~ /^vlan/ {print $2; exit}')
    if [ -n "$vlan_iface" ]; then
        echo "Experimental interface up: $(ip -o -4 addr show dev "$vlan_iface")"
        break
    fi
    if [ "$elapsed" -ge "$NET_CHECK_TIMEOUT" ]; then
        echo "FATAL: no vlan* interface with an IPv4 address appeared within ${NET_CHECK_TIMEOUT}s."
        echo "Emulab never brought up this node's experimental fabric link (likely a CloudLab L1/switch-port flake); this node cannot reach the rest of the cluster. Aborting startup."
        exit 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
done

if [ -f "/local/.rebooted" ]; then
    # Configurations that are required after rebooting
    echo "Executing after-reboot configurations"

    echo "Done!"
    date
    touch /local/.rebooted
    echo "Rebooting..."
    exit 0
fi

# Updating APT repos for installation scripts
source /local/repository/scripts/retry_helpers.sh
apt_get_update_soft

echo "Executing one-time configurations"


# Creating extra storage in /storage
/local/repository/scripts/setup-disk.sh


# Configurations that require reboot

# Optional configurations
# They are defined as env variables through profile.py
# Example: 
#   PROFILE_CONF_COMMAND_<COMMAND NAME>='command or script to run'
#   PROFILE_CONF_COMMAND_<COMMAND NAME>_ARGS='args'

# Get profile config envs
PROFILE_CONFIG_COMMANDS=$(set | grep "PROFILE_CONF_COMMAND_" | awk -F "=" '{print $1}')

# Filter commands
declare -a COMMAND_LIST=()
for s in ${PROFILE_CONFIG_COMMANDS[@]}
do
    if [[ $s != *_ARGS ]]; then
        COMMAND_LIST+=("$s")
    fi
done

# Execute commands with args
for cmd in "${COMMAND_LIST[@]}"
do
    ARGS="${cmd}_ARGS"
    echo "Executing: $(eval echo \${$cmd}) $(eval echo \${$ARGS})"
    bash -c "$(eval echo \${$cmd}) $(eval echo \${$ARGS})"
done

echo "Done!"
date
touch /local/.rebooted
sudo chmod u+x /local/repository/scripts/build_proxy.sh
if [ ! -f "/local/.noreboot" ]; then
    echo "Rebooting..."
    echo ""
    # Reboot to apply changes
    sudo reboot
fi