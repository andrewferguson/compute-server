#!/bin/bash
# Builds the kernel from source, installs it, and builds the fake_tsc module after reboot

# Redirect output to log file
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
GITHUB_USERNAME="$2"
MACHINE_NUM="$3"
INSTANCE_ID="$4"
USER_HOME="/users/$(whoami)"
echo "Number of machines in this experiments are ${MACHINE_NUM}"
kernel_repo="ujjwalpawar/chronos-kernel"
qdt="netsys-edinburgh/quick_deployment_tools"
tsc_repo="ujjwalpawar/fake_tsc"
kernel_link="https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com/${kernel_repo}.git"
qdt_link="https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com/${kernel_repo}.git"
tsc_link="https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com/${tsc_repo}.git"
VM_NAME="ins${INSTANCE_ID}vm"
INTERNAL_SUBNET=$((1 +INSTANCE_ID)) # 122,123,124,…
INTERNAL_IP="10.2.${INTERNAL_SUBNET}.2"
NET_GW_IP="10.2.${INTERNAL_SUBNET}.1"
RANGE_START="10.2.${INTERNAL_SUBNET}.2"
RANGE_END="10.2.${INTERNAL_SUBNET}.254"

################################################################################
# Step 1: Kernel Build
################################################################################
touch /local/.kernel_done
touch /local/.rebooted
touch /local/.tsc_done
if [ ! -f "/local/.kernel_done" ]; then
    step_log "Installing kernel build dependencies"
    sudo apt-get update
    sudo apt-get install -y build-essential git libncurses-dev bison flex libssl-dev libelf-dev dwarves ripgrep

    step_log "Cloning kernel repo to ~/chronos-kernel"
    git clone --quiet "${kernel_link}" "${USER_HOME}/chronos-kernel"
    cd "${USER_HOME}/chronos-kernel"

    step_log "Copying current kernel config to .config"
    cp "/boot/config-$(uname -r)" .config

    step_log "Disabling/enabling kernel config options"
    scripts/config --disable SYSTEM_TRUSTED_KEYS
    scripts/config --disable SYSTEM_REVOCATION_KEYS
    scripts/config --disable VIDEO_OV01A10
    scripts/config --enable NETFILTER_XTABLES
    scripts/config --enable NETFILTER_XT_MARK
    scripts/config --enable NETFILTER_XT_TARGET_MARK
    scripts/config --enable PREEMPT_RT_FULL
    scripts/config --disable DEBUG_INFO_BTF

    step_log "Running olddefconfig"
    make olddefconfig

    step_log "Building the kernel"
    make -j"$(nproc)"

    step_log "Installing kernel modules"
    sudo make INSTALL_MOD_STRIP=1 modules_install
    sudo make install

    step_log "Updating grub"
    sudo update-grub

    
    ################################################################################
    # Step 1.5: Configure tuned for core isolation (core 2–55)
    ################################################################################
    step_log "Installing tuned and configuring for CPU isolation (core 2–55)"
    sudo apt-get install -y tuned

    sudo ln -sf /boot/grub/grub.cfg /etc/grub2.cfg

    export line to grub.d/00_tuned
    echo 'echo "export tuned_params"' | sudo tee -a /etc/grub.d/00_tuned

    echo "isolated_cores=2-55" | sudo tee /etc/tuned/realtime-variables.conf

    sudo sed -i '/^cmdline_realtime=/d' /usr/lib/tuned/realtime/tuned.conf

    # If [bootloader] section does not exist, append it
    if ! grep -q "^\[bootloader\]" /usr/lib/tuned/realtime/tuned.conf; then
        echo -e "\n[bootloader]" | sudo tee -a /usr/lib/tuned/realtime/tuned.conf
    fi

    # Append the new cmdline_realtime under [bootloader]
    sudo sed -i '/^\[bootloader\]/a cmdline_realtime=+isolcpus=${managed_irq}${isolated_cores} nohz_full=${isolated_cores} rcu_nocbs=${isolated_cores} nosoftlockup' /usr/lib/tuned/realtime/tuned.conf

    # Activate realtime profile
    sudo tuned-adm profile realtime

    step_log "Mark kernel done and reboot"
    touch /local/.kernel_done
    touch /local/.rebooted
    sudo reboot
    exit 0
fi

################################################################################
# Step 2: After Reboot, build & insert fake_tsc
################################################################################

if [ -f "/local/.kernel_done" ] && [ -f "/local/.rebooted" ] && [ ! -f "/local/.tsc_done" ]; then
    step_log "After reboot: building and inserting fake_tsc module"
    rm -f /local/.rebooted

    cd "${USER_HOME}"
    if [ ! -d "fake_tsc" ]; then
        git clone "${tsc_link}" fake_tsc
    fi
    cd fake_tsc

    if [ -f init.c ]; then
            step_log "Compiling and running init.c"
            gcc init.c -o init

    fi

    if [ -f shared.c ]; then
        step_log "Compiling shared.c"
        gcc shared.c -o shared
    fi

    step_log "Building fake_tsc module"
    make

    step_log "Unloading existing KVM modules (if any)"
        sudo rmmod kvm_intel || true
        sudo rmmod kvm || true


    step_log "Inserting custom_tsc.ko"
    sudo insmod custom_tsc.ko
    sudo modprobe kvm
    sudo modprobe kvm_intel
    sudo ./init
    sudo ./init
    step_log "Re-loading KVM modules"
    sudo apt-get install -yqq libsctp-dev lksctp-tools  zlib1g-dev
    sudo modprobe sctp
    step_log "fake_tsc module inserted"
    sudo lsmod | grep custom_tsc || echo "⚠️ Warning: custom_tsc not in lsmod"
    sudo dmesg | tail -n 20
    cp /local/repository/scripts/slotcheckerservice.c ./
    gcc slotcheckerservice.c -o slotcheckerservice 
    touch /local/.tsc_done
fi

################################################################################
# Step 3: VM setup — uvt-kvm create ► virsh set MAC ► 固定 IP (DHCP host 条目)
################################################################################
# Preconditions
#   – /local/.tsc_done exists
#   – /local/.vm_setup_done NOT exists
################################################################################
if [ -f "/local/.tsc_done" ] && [ ! -f "/local/.vm_setup_done" ]; then
    step_log "Installing virtualization tools and creating VM (uvt-kvm + static MAC)"

    # 1. Packages
    sudo apt-get update
    sudo apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients \
                            bridge-utils virtinst uvtool
    
    step_log "Changing default storage location"
    sudo /local/repository/scripts/change_storage.sh
    # 2. Sync cloud image (once per host)
    step_log "Syncing Ubuntu cloud image"
    sudo uvt-simplestreams-libvirt sync --source https://cloud-images.ubuntu.com/daily/ release=focal arch=amd64
    sudo virsh net-start default
    # 3. Names & deterministic IP/MAC
    sudo virsh pool-destroy  uvtool 
    sudo virsh pool-edit     uvtool  

    sudo virsh pool-build   uvtool
    sudo virsh pool-start   uvtool
    sudo virsh pool-autostart uvtool
    sudo chown -R libvirt-qemu:kvm /storage/uvtool      # in case anything already exists
    sudo chmod 2770               /storage/uvtool       # setgid bit → new files get group=kvm

    sudo setfacl -d -m g:kvm:rwx  /storage/uvtool
    
    echo "/storage/uvtool/** rwk," | sudo tee /etc/apparmor.d/local/abstractions/libvirt-qemu
    sudo systemctl reload apparmor

    step_log "VM  = ${VM_NAME}"
    step_log "Int = ${INTERNAL_IP}"

    # 4. Create VM (uvt-kvm, DHCP 模式即可)
    if ! sudo uvt-kvm create "${VM_NAME}" \
            release=focal arch=amd64 \
            --cpu 23 --memory 54096 --password 1997 --disk 200; then
        echo "❌ uvt-kvm create failed, aborting"; exit 1
    fi

     step_log "Modifying /etc/libvirt/qemu/$VM_NAME.xml to patch CPU and clock settings"
            VM_XML="/etc/libvirt/qemu/${VM_NAME}.xml"
            TMP_XML="/tmp/${VM_NAME}.xml.modified"

            sudo cp "$VM_XML" "$VM_XML.bak"

            step_log "Deleting two lines after </features>"
            sudo awk '
            /<\/features>/ {
                print;
                skip = 2;
                next;
            }
            skip > 0 {
                skip--;
                next;
            }
            { print }
            ' "$VM_XML" > "$TMP_XML"

            step_log "Inserting new <cpu> and <clock> blocks"
            sudo sed -i "/<\/features>/a \
        <cpu mode='host-passthrough' check='none'>\\
          <feature policy='disable' name='rdtscp'/>\\
          <feature policy='disable' name='tsc-deadline'/>\\
        </cpu>\\
        <clock offset='localtime'>\\
          <timer name='rtc' present='no' tickpolicy='delay'/>\\
          <timer name='pit' present='no' tickpolicy='discard'/>\\
          <timer name='hpet' present='no'/>\\
          <timer name='kvmclock' present='yes'/>\\
        </clock>" "$TMP_XML"

step_log "pinning cpu"
        # Ensure <vcpu> = 54 and placement='static'
block=$(
  echo "  <iothreads>1</iothreads>"
  echo "  <cputune>"
  for i in $(seq 0 22); do
    printf "    <vcpupin vcpu='%d' cpuset='%d'/>\n" "$i" "$((i+2))"
  done
  echo "    <emulatorpin cpuset='23'/>"
  echo "    <iothreadpin iothread='1' cpuset='24'/>"
  echo "    <vcpusched vcpus='0'    scheduler='fifo' priority='1'/>"
  echo "    <vcpusched vcpus='1-22' scheduler='fifo' priority='1'/>"
  echo "    <emulatorsched scheduler='fifo' priority='1'/>"
  echo "    <iothreadsched iothreads='1' scheduler='fifo' priority='1'/>"
  echo "  </cputune>"
)
sudo sed -i "/<vcpu placement='static'>51<\/vcpu>/r /dev/stdin" "$TMP_XML" <<<"$block"

            step_log "Replacing $VM_NAME.xml with modified version and redefining domain"
            sudo mv "$TMP_XML" "$VM_XML"
            sudo virsh define "$VM_XML"

            sudo virsh destroy "$VM_NAME"
            sudo virsh start "$VM_NAME"


    # --------------------------------------------------------------------- #
        # 3. Waiting domifaddr return real MAC/IP
        # --------------------------------------------------------------------- #
        step_log "Waiting domifaddr for ${VM_NAME}"
        for i in {1..30}; do
            domif=$(sudo virsh domifaddr "$VM_NAME" 2>&1)
            if echo "$domif" | sudo grep -q 'ipv4'; then
                break
            fi
            sleep 2
        done
        step_log "domifaddr output" "$domif"

    REAL_MAC=$(echo "$domif" | awk '/ipv4/ {print $2}')

    if [ -z "$REAL_MAC" ] ; then
            echo "❌ domifaddr did not return MAC, aborting"; exit 1
        fi
################################################################################
# Step 3。5   virsh set MAC ► static IP (DHCP host 条目)
################################################################################
################################################################################

    step_log "Edit the default network"
    NET_XML="/etc/libvirt/qemu/networks/default.xml"

    if ! sudo grep -q "$REAL_MAC" "$NET_XML"; then
      step_log "Adding DHCP host entry for ${VM_NAME} in default network"
      sudo sed -i -E "
        # -- bridge / gateway ----------------------------------------------------
        0,/<ip address=/{
            s@<ip address='[0-9.]+' netmask='255\.255\.0\.0'>@<ip address='${NET_GW_IP}' netmask='255.255.0.0'>@
        }

        # -- DHCP range ----------------------------------------------------------
        /<range /{
            s@start='[0-9.]+'@start='${RANGE_START}'@
            s@end='[0-9.]+'@end='${RANGE_END}'@
        }

        # -- purge any old host entry for this VM --------------------------------
        /<dhcp>/,/<\/dhcp>/{
            /<host .*name='${VM_NAME}'.*\/>/d
        }

        # -- add fresh host reservation -----------------------------------------
        /<range /a\\
            <host mac='${REAL_MAC}' name='${VM_NAME}' ip='${INTERNAL_IP}'/>
        "  "$NET_XML"

    fi
    step_log "stopping ${VM_NAME} to change ip address"
    sudo virsh shutdown "${VM_NAME}"

    for i in {1..200}; do
        state=$(sudo virsh domstate "${VM_NAME}" 2>/dev/null) || true
        echo "⏳ Waiting for ${VM_NAME} to shut off... (${i}/20) → state: ${state}"
        sudo virsh shutdown "${VM_NAME}"
        [[ "$state" == "shut off" ]] && break
        sleep 1
    done

    if [[ "$state" != "shut off" ]]; then
        echo "⚠️  ${VM_NAME} did not shut off in time; forcing shutdown"
        sudo virsh destroy "${VM_NAME}"
        sleep 2
    fi
    step_log "Restarting libvirt default network"
    sudo virsh net-destroy default

    step_log "Restarting libvirtd service to apply changes"
    sudo service libvirtd restart

    sudo systemctl restart libvirtd

    sudo virsh net-start  default
    sleep 10
    # 8. start VM


    step_log "Starting ${VM_NAME} again"
    sudo virsh start "${VM_NAME}"
    for i in {1..200}; do
        state=$(sudo virsh domstate "${VM_NAME}" 2>/dev/null) || true
        echo "⏳ Waiting for ${VM_NAME} to shut off... (${i}/20) → state: ${state}"
        [[ "$state" == "running" ]] && break
        sleep 1
    done
    sleep 30
    domif_output2=$(sudo virsh domifaddr "${VM_NAME}" 2>&1)
    step_log "Assigned IP address from domifaddr for ${VM_NAME}" "${domif_output2}"

    # 9. Wait until DHCP assigns the fixed IP
    step_log "Waiting for ${VM_NAME} to get IP ${INTERNAL_IP}"
    for i in {1..30}; do
        ip_list=$(sudo virsh domifaddr "${VM_NAME}" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1)
        for ip in $ip_list; do
            if [[ "$ip" == "$INTERNAL_IP" ]]; then
                cur_ip="$ip"
                break 2  # Exit both loops
            fi
        done
        sleep 2
    done
    [[ "${cur_ip}" != "${INTERNAL_IP}" ]] && echo "⚠️  VM IP is ${cur_ip:-N/A}, expected ${INTERNAL_IP}"

    # 10. Done
#    sudo virsh net-destory default
#    sleep 2
#    sudo virsh net-start default
#    sleep 2
#    sudo virsh shutdown "${VM_NAME}"
#    sleep 5
#    sudo service libvirtd restart
#    sleep 5
#    sudo virsh start "${VM_NAME}"
    touch /local/.vm_setup_done
fi
#sudo virsh destroy "${VM_NAME}"
#sudo reboot
################################################################################
# Step 4: Exposed-IP alias  &  NAT rules (runs once per host)
################################################################################
# Preconditions
#   – /local/.vm_setup_done   exists  (VM created)
#   – /local/.net_setup_done  NOT     exists (NAT not yet written)
################################################################################
if [ -f "/local/.vm_setup_done" ] && [ ! -f "/local/.net_setup_done" ]; then
    step_log "Setting alias IP and NAT rules for this host"
    state=$(sudo virsh domstate "${VM_NAME}" 2>/dev/null) || true
    echo "⏳ Checking state of ${VM_NAME} to shut off... (${i}/20) → state: ${state}"
    [[ "$state" == "shut off" ]] && sudo virsh start ${VM_NAME}
    for i in {1..200}; do
        state=$(sudo virsh domstate "${VM_NAME}" 2>/dev/null) || true
        echo "⏳ Waiting for ${VM_NAME} to start... (${i}/20) → state: ${state}"
        [[ "$state" == "running" ]] && break
        sleep 1
    done
    cd  /local/repository/scripts
    step_log "Adding ips"
    sudo /local/repository/scripts/add-secondary.sh
    sleep 5
    step_log "Generating json"
    sudo /local/repository/scripts/generate_config.sh  $MACHINE_NUM
    sleep 5
    step_log "Adding IP TABLES"
    sudo /local/repository/scripts/set_ip.sh
    sleep 5
    step_log "Installing ssh pass"
    sudo apt-get -y install sshpass
    password="1997"
    SSH_OPTS="-oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
    step_log "create ssh keys"
    ssh-keygen -q -t rsa -N '' -f ~/.ssh/id_rsa
    step_log "Copying ssh keys"
    sshpass -p $password ssh-copy-id $SSH_OPTS ubuntu@${INTERNAL_IP}

    step_log "Copying script to add ip address"
    scp $SSH_OPTS /local/repository/scripts/add-secondary_vm.sh ubuntu@${INTERNAL_IP}:~/
    step_log "calling copied script"

    ssh $SSH_OPTS ubuntu@${INTERNAL_IP}  "sudo /home/ubuntu/add-secondary_vm.sh"
    touch /local/.net_setup_done
fi

################################################################################
# Step 5: Install k0s inside the VM
################################################################################
# Preconditions
#   – /local/.vm_setup_done exists   (the VM has been created and given a fixed IP)
#   – /local/.k0s_in_vm_done does NOT exist  (k0s has not yet been installed inside the VM)
################################################################################
################################################################################
# Step 5: Install k0s inside the VM
################################################################################
# Preconditions
#   – /local/.vm_setup_done exists   (the VM has been created and given a fixed IP)
#   – /local/.k0s_in_vm_done does NOT exist  (k0s has not yet been installed inside the VM)
################################################################################

if [ -f "/local/.vm_setup_done" ] && [ -f "/local/.net_setup_done" ] && [ ! -f "/local/.k0s_in_vm_done" ]; then
    step_log "Installing k0s inside VM ${VM_NAME} (${INTERNAL_IP})"

    # Install sshpass if not already installed
    if ! command -v sshpass >/dev/null 2>&1; then
        step_log "Installing sshpass"
        sudo apt-get install -y sshpass
    fi

    # 1. Copy the three k0s helper scripts into /tmp inside the guest
    step_log "Copying k0s install files to vm"
    scp $SSH_OPTS /local/repository/scripts/master_install_k0.sh ubuntu@"${INTERNAL_IP}":/tmp/ 
    scp $SSH_OPTS /local/repository/scripts/worker_install_k0.sh ubuntu@"${INTERNAL_IP}":/tmp/ 
    scp $SSH_OPTS /local/repository/scripts/common_k0.sh ubuntu@"${INTERNAL_IP}":/tmp/ 
    # 2. Worker VMs need the ubuntu private key so they can SSH back to the controller VM
    step_log "creating ssh keys"
    ssh $SSH_OPTS ubuntu@"${INTERNAL_IP}" "mkdir -p /home/ubuntu/.ssh && chmod 700 /home/ubuntu/.ssh"
    ssh $SSH_OPTS ubuntu@${INTERNAL_IP} "ssh-keygen -q -t rsa -N '' -f /home/ubuntu/.ssh/id_rsa"
    step_log "checking ssh keys"
    ssh $SSH_OPTS ubuntu@${INTERNAL_IP} "ls /home/ubuntu/.ssh/"
    
    # 3. Run the relevant install script inside the guest
    if [ "$INSTANCE_ID" -eq 0 ]; then
        # Controller VM
        ROLE_SCRIPT="/tmp/master_install_k0.sh"
        ssh $SSH_OPTS ubuntu@"${INTERNAL_IP}" "bash $ROLE_SCRIPT"
        ssh $SSH_OPTS ubuntu@"${INTERNAL_IP}" git clone --quiet "${qdt_link}"
    else
        # Worker VM
        ssh  $SSH_OPTS ubuntu@${INTERNAL_IP} "sudo apt -y update && sudo apt -y install sshpass"

        ssh  $SSH_OPTS ubuntu@${INTERNAL_IP} "sshpass -p 1997 ssh-copy-id $SSH_OPTS ubuntu@10.2.1.2"
        ROLE_SCRIPT="/tmp/worker_install_k0.sh"
        CONTROLLER_VM_IP="10.2.1.2"   # internal IP of the controller VM
        ssh $SSH_OPTS ubuntu@"${INTERNAL_IP}" "bash $ROLE_SCRIPT $CONTROLLER_VM_IP"
    fi
    sudo gcc -pthread slotcheckerservice.c -o slotcheckerservice
    sudo cp /local/repository/scripts/slotcheckerservice.service /etc/systemd/system/slotcheckerservice.service
    sudo systemctl daemon-reload
    sudo systemctl enable slotcheckerservice
    sudo systemctl start slotcheckerservice

    touch /local/.k0s_in_vm_done
fi
################################################################################
# Step 5: All done
################################################################################
step_log "All steps already completed. Nothing to do."
