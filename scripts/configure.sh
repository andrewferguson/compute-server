#!/bin/bash

# Redirect output to log file
exec >> /local/configuration.log
exec 2>&1

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
sudo apt update

echo "Executing one-time configurations"

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
echo "Rebooting..."
echo ""
# Reboot to apply changes
sudo reboot