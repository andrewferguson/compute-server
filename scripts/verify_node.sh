#!/usr/bin/env bash
# verify_node.sh <instance-id> — fail-loud post-setup verification for an
# inner-VM node (node0..machineNum).
#
# Runs as the FINAL startup service on every outer node that hosts an inner VM.
# Its purpose is to make a silently-incomplete node impossible: if the inner VM
# was never created, or was created but never joined the k0s cluster, this exits
# non-zero so CloudLab flags the node as failed instead of the experiment
# reporting "ready" while a controller/UE-hosting VM is actually missing. That
# silent mode is exactly what a transient /local/repository clone failure caused
# — the whole node was skipped and nothing noticed until the cluster was used.
#
# Every check targets THIS node's own inner VM only, so the verification is not
# racy against other nodes provisioning in parallel.
set -uo pipefail

INSTANCE_ID="${1:?usage: verify_node.sh <instance-id>}"
VM_NAME="ins${INSTANCE_ID}vm"
INTERNAL_IP="10.2.$((1 + INSTANCE_ID)).2"   # fixed inner IP assigned in build_kernel.sh
CONTROLLER_IP="10.2.1.2"                     # inner IP of the controller VM (ins0vm)
SSH_OPTS="-oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oConnectTimeout=15"
# How long to wait for the node to report Ready (CNI/kubelet registration lag).
: "${VERIFY_READY_TIMEOUT:=300}"

fail() { echo "❌ FATAL(verify ${VM_NAME}): $*" >&2; exit 1; }
log()  { echo "[verify ${VM_NAME}] $*"; }

# 1. The inner VM must exist and be running.
sudo virsh list --state-running --name 2>/dev/null | grep -qx "${VM_NAME}" \
    || fail "domain is not in running state (virsh)"
log "domain running ✓"

# 2. The k0s install/join step must have completed on this node (marker written
#    only after a successful in-guest install/join in build_kernel.sh).
[ -f /local/.k0s_in_vm_done ] || fail "k0s install/join step never completed (marker missing)"
log "k0s join step completed ✓"

# 3. The correct k0s service must be active inside the guest.
if [ "${INSTANCE_ID}" -eq 0 ]; then
    SVC=k0scontroller; NODE_NAME=controller
else
    SVC=k0sworker;     NODE_NAME="${VM_NAME}"
fi
ssh ${SSH_OPTS} ubuntu@"${INTERNAL_IP}" "systemctl is-active ${SVC}" 2>/dev/null | grep -qx active \
    || fail "${SVC} is not active inside the guest"
log "${SVC} active inside guest ✓"

# 4. Authoritative: the controller must report this node Ready within the budget.
WAIT="sudo k0s kubectl wait --for=condition=Ready node/${NODE_NAME} --timeout=${VERIFY_READY_TIMEOUT}s"
if [ "${INSTANCE_ID}" -eq 0 ]; then
    ssh ${SSH_OPTS} ubuntu@"${INTERNAL_IP}" "${WAIT}" \
        || fail "controller did not become Ready within ${VERIFY_READY_TIMEOUT}s"
else
    deadline=$((SECONDS + VERIFY_READY_TIMEOUT))
    while true; do
        remaining=$((deadline - SECONDS))
        [ "${remaining}" -gt 0 ] || fail "controller never observed ${NODE_NAME} register within ${VERIFY_READY_TIMEOUT}s"

        if out=$(ssh ${SSH_OPTS} ubuntu@"${INTERNAL_IP}" \
            "ssh ${SSH_OPTS} ubuntu@${CONTROLLER_IP} 'sudo k0s kubectl get node ${NODE_NAME} -o name'" 2>&1); then
            break
        fi

        if grep -q 'NotFound' <<<"${out}"; then
            sleep 5
            continue
        fi

        fail "could not query controller for ${NODE_NAME}: ${out}"
    done
    log "controller observed ${NODE_NAME} register ✓"

    remaining=$((deadline - SECONDS))
    [ "${remaining}" -gt 0 ] || fail "controller observed ${NODE_NAME} register but it did not become Ready within ${VERIFY_READY_TIMEOUT}s"
    WAIT="sudo k0s kubectl wait --for=condition=Ready node/${NODE_NAME} --timeout=${remaining}s"
    ssh ${SSH_OPTS} ubuntu@"${INTERNAL_IP}" "ssh ${SSH_OPTS} ubuntu@${CONTROLLER_IP} '${WAIT}'" \
        || fail "controller observed ${NODE_NAME} register but it did not become Ready within ${VERIFY_READY_TIMEOUT}s"
fi
log "controller reports ${NODE_NAME} Ready ✓"

echo "✅ verify OK: ${VM_NAME} is running and Ready in the k0s cluster"
