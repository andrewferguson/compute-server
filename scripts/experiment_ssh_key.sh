#!/bin/bash
# Shared experiment SSH key handling for every Chronos outer node.
#
# CloudLab generates one SSH key pair per experiment, retrievable with
# `geni-get key`. Every node in the experiment gets the same pair, which is what
# lets the outer nodes and the inner VMs talk to each other without passwords.
#
# The problem this file solves is that the key was previously materialized only
# into $HOME/.ssh/id_rsa of whichever account CloudLab happens to run the
# startup services as (geniuser), at mode 0600. That works for the bootstrap
# scripts and for nobody else: a human logged in as their own CloudLab account
# cannot read it, so `ssh ubuntu@10.2.1.2` fell back to password auth.
#
# The fix is a single node-local copy that every account can use, plus a
# system-wide ssh_config entry so no flags are needed at all.

: "${SSH_OPTS:=-oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null}"

CHRONOS_KEY_DIR="/local/chronos"
CHRONOS_SHARED_KEY="${CHRONOS_KEY_DIR}/experiment_key"
CHRONOS_GUEST_AUTH_KEYS="${CHRONOS_KEY_DIR}/guest_authorized_keys"
CHRONOS_SSH_CONFIG="/etc/ssh/ssh_config.d/50-chronos.conf"

# Pull this experiment's key pair out of CloudLab and into the calling account's
# ~/.ssh, which is what the bootstrap scripts themselves use.
materialize_experiment_key() {
    mkdir -p "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"

    geni-get key > "${HOME}/.ssh/id_rsa" || return 1
    [ -s "${HOME}/.ssh/id_rsa" ] || return 1
    chmod 600 "${HOME}/.ssh/id_rsa"

    ssh-keygen -y -f "${HOME}/.ssh/id_rsa" > "${HOME}/.ssh/id_rsa.pub" || return 1
    [ -s "${HOME}/.ssh/id_rsa.pub" ] || return 1

    touch "${HOME}/.ssh/authorized_keys"
    grep -q -f "${HOME}/.ssh/id_rsa.pub" "${HOME}/.ssh/authorized_keys" \
        || cat "${HOME}/.ssh/id_rsa.pub" >> "${HOME}/.ssh/authorized_keys"
}

# Publish the experiment key at a node-local path that every account on the node
# can actually use, and wire it into the system ssh_config so that a bare
# `ssh 10.2.1.2` works for anyone without -i, without sudo, and without a
# password.
install_shared_experiment_key() {
    [ -s "${HOME}/.ssh/id_rsa" ] || return 1

    sudo mkdir -p "${CHRONOS_KEY_DIR}"
    sudo chmod 755 "${CHRONOS_KEY_DIR}"
    sudo cp "${HOME}/.ssh/id_rsa" "${CHRONOS_SHARED_KEY}"

    # Owned by 'nobody' deliberately. OpenSSH only enforces its "permissions are
    # too open" check when the *calling* user owns the key file -- see
    # sshkey_perm_ok(), which is guarded by `st.st_uid == getuid()`. A key owned
    # by an account nobody logs in as is therefore readable and usable at mode
    # 0644 by every real account on the node, root included. Owning it as root
    # would break it for root; owning it as geniuser would break it for the
    # bootstrap scripts themselves.
    sudo chown nobody:nogroup "${CHRONOS_SHARED_KEY}"
    sudo chmod 644 "${CHRONOS_SHARED_KEY}"

    # 10.2.*.* is exclusively inner-VM space (outer nodes are 10.1/10.3/10.4),
    # so this block cannot capture traffic meant for anything else.
    sudo mkdir -p /etc/ssh/ssh_config.d
    sudo tee "${CHRONOS_SSH_CONFIG}" >/dev/null <<EOF
# Installed by Chronos (scripts/experiment_ssh_key.sh). Lets any account on this
# node reach the inner VMs with a bare 'ssh 10.2.N.2'.
Host 10.2.*.*
    User ubuntu
    IdentityFile ${CHRONOS_SHARED_KEY}
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF
    sudo chmod 644 "${CHRONOS_SSH_CONFIG}"
}

# Build the authorized_keys set to inject into the inner VM at create time: the
# experiment key (used by the bootstrap scripts and by VM-to-VM traffic) plus
# every human key CloudLab installed on this node.
#
# Injecting the human keys is what makes `ssh -J <outer> ubuntu@10.2.N.2` work
# from a laptop. ProxyJump authenticates to the final hop with the keys on the
# *client*, so the node-local key above cannot help there; the guest has to
# trust the operator's own key directly.
#
# This mirrors the trust boundary CloudLab already established on the outer node
# -- those same accounts have passwordless sudo here -- so it grants nothing new.
build_guest_authorized_keys() {
    [ -s "${HOME}/.ssh/id_rsa.pub" ] || return 1

    local tmp
    tmp="$(mktemp)" || return 1

    cat "${HOME}/.ssh/id_rsa.pub" >> "${tmp}"

    # The glob has to expand as root: /users/<account> is mode 0700, so the
    # startup account cannot even traverse into another user's .ssh.
    # CloudLab's authorized_keys files also carry '#' banners and a legacy
    # RSA1 "<bits> <exp> <modulus>" line, hence the filter to real key lines.
    sudo bash -c 'cat /users/*/.ssh/authorized_keys 2>/dev/null' \
        | grep -E '^(ssh-|ecdsa-|sk-)' >> "${tmp}" || true

    # Deduplicate on the key material itself, not the whole line, so the same
    # key carried with different trailing comments collapses to one entry.
    awk '!seen[$2]++' "${tmp}" | sudo tee "${CHRONOS_GUEST_AUTH_KEYS}" >/dev/null
    rm -f "${tmp}"

    sudo chmod 644 "${CHRONOS_GUEST_AUTH_KEYS}"

    # Never let a missing /users mount turn into a VM with no way in at all.
    if ! sudo grep -qE '^(ssh-|ecdsa-|sk-)' "${CHRONOS_GUEST_AUTH_KEYS}"; then
        echo "WARNING: no usable public keys collected, falling back to the experiment key alone"
        sudo cp "${HOME}/.ssh/id_rsa.pub" "${CHRONOS_GUEST_AUTH_KEYS}"
        sudo chmod 644 "${CHRONOS_GUEST_AUTH_KEYS}"
    fi
}

# Make the guest key-only, and prove it rather than assume it.
#
# The filename matters: sshd takes the *first* value it sees while reading
# /etc/ssh/sshd_config.d/*.conf in lexical order, so this has to sort ahead of
# cloud-init's own 50-cloud-init.conf to win.
enforce_guest_key_only_ssh() {
    local target="$1"

    ssh ${SSH_OPTS} -oConnectTimeout=10 "${target}" \
        "sudo sh -c 'printf \"PasswordAuthentication no\nKbdInteractiveAuthentication no\n\" > /etc/ssh/sshd_config.d/01-chronos-no-password.conf && systemctl restart ssh'" \
        || return 1

    ssh ${SSH_OPTS} -oConnectTimeout=10 "${target}" \
        "sudo sshd -T | grep -qx 'passwordauthentication no'" \
        || return 1
}
