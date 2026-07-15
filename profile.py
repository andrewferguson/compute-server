#!/usr/bin/env python

kube_description= \
    """
    Development Cluster with USRP
    """
kube_instruction= \
    """
    Author: Jon Larrea and Ujjwal Pawar
    """


import geni.portal as portal
import geni.rspec.pg as PG
import geni.rspec.igext as IG
import geni.rspec.emulab.spectrum as spectrum
import geni.rspec.emulab.pnext as pn
import math


pc = portal.Context()
rspec = PG.Request()

COMP_MANAGER_ID = "urn:publicid:IDN+emulab.net+authority+cm"

# Profile parameters.
pc.defineParameter("machineNum", "Number of gNB / UE Nodes", portal.ParameterType.INTEGER, 1)
pc.defineParameter("machinePNum", "Number of Proxy Nodes", portal.ParameterType.INTEGER, 1)
pc.defineParameter("Hardware", "Outer Node Hardware", portal.ParameterType.NODETYPE,"pc")
pc.defineParameter("ProxyHardware", "Proxy Machine Hardware", portal.ParameterType.NODETYPE,"pc")
pc.defineParameter("ManagerHardware", "k8s Controller Hardware", portal.ParameterType.NODETYPE,"pc")
pc.defineParameter("OS", "Operating System", portal.ParameterType.STRING,"ubuntu22",[("ubuntu18","ubuntu18"),("ubuntu20","ubuntu20"), ("ubuntu22", "ubuntu22")])

#GitHub parameters
pc.defineParameter("githubUser","GitHub Username",
                   portal.ParameterType.STRING,"")
pc.defineParameter("token", "GitHub Token",
                   portal.ParameterType.STRING, "")



params = pc.bindParameters()

#
# Give the library a chance to return nice JSON-formatted exception(s) and/or
# warnings; this might sys.exit().
#
pc.verifyParameters()



tour = IG.Tour()
tour.Description(IG.Tour.TEXT,kube_description)
tour.Instructions(IG.Tour.MARKDOWN,kube_instruction)
rspec.addTour(tour)


# Network
netmask="255.0.0.0"
network = rspec.Link("Network")
network.link_multiplexing = True
network.vlan_tagging = True
network.best_effort = True

if params.OS == 'ubuntu20':
    os = 'urn:publicid:IDN+emulab.net+image+emulab-ops:UBUNTU20-64-STD'
elif params.OS == 'ubuntu22':
    os = 'urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU22-64-STD'
else:
    os = 'urn:publicid:IDN+emulab.net+image+emulab-ops:UBUNTU18-64-STD'

# Variable that stores configuration scripts and arguments
profileConfigs = ""

# --- Resilient bootstrap of the profile repository ---------------------------
# CloudLab clones this profile's git repo into /local/repository before running
# the services below. That clone occasionally fails on a transient GitHub HTTP/2
# framing error ("curl 16 Error in the HTTP2 framing layer" / "error reading
# section header 'shallow-info'"). When it does, every service command below
# points at a script that does not exist, so the node is silently skipped -- no
# inner VM, no cluster join -- while the experiment still reports "ready".
#
# ensure_repo_cmd() is the very first service on every node. It is inline (it
# depends on nothing inside the repo), idempotent (a no-op when CloudLab's clone
# already succeeded), and it re-establishes /local/repository resiliently:
# HTTP/1.1 (immune to the framing bug) + bounded retries with backoff, cloning
# into a temp dir and swapping it into place so a partial clone can't wedge it.
# If the repo is genuinely unreachable it hard-fails loudly (exit 1) so the node
# is flagged failed rather than skipped.
REPO_URL = "https://github.com/andrewferguson/compute-server.git"
REPO_REF = "split-agent"

def ensure_repo_cmd():
    return (
        'set -u; '
        'SENT=/local/repository/scripts/configure.sh; '
        'if [ -x "$SENT" ]; then echo "[bootstrap] repository present; skipping"; exit 0; fi; '
        'echo "[bootstrap] /local/repository missing or incomplete; re-cloning ' + REPO_URL + ' @ ' + REPO_REF + '"; '
        'sudo mkdir -p /local; '
        'for i in 1 2 3 4 5; do '
        '  sudo rm -rf /local/repository.tmp; '
        '  sudo git -c http.version=HTTP/1.1 clone --branch ' + REPO_REF + ' ' + REPO_URL + ' /local/repository.tmp && break; '
        '  echo "[bootstrap] clone attempt $i failed; backing off $((i*15))s"; sleep $((i*15)); '
        'done; '
        'if [ ! -x /local/repository.tmp/scripts/configure.sh ]; then '
        '  echo "FATAL(bootstrap): could not clone ' + REPO_URL + ' @ ' + REPO_REF + ' after 5 attempts"; exit 1; '
        'fi; '
        'sudo rm -rf /local/repository; sudo mv /local/repository.tmp /local/repository; '
        'echo "[bootstrap] repository restored at /local/repository"'
    )

# Machines
for i in range(0,params.machineNum+1):
    node = rspec.RawPC("node" + str(i))
    node.disk_image = os
    node.addService(PG.Execute(shell="bash", command=ensure_repo_cmd()))
    node.addService(PG.Execute(shell="bash", command=profileConfigs + "/local/repository/scripts/configure.sh"))
    command = "/local/repository/scripts/build_kernel.sh {} {} {} {}".format(
    params.token,           # $1 = token
    params.githubUser,      # $2 = GitHub username
    params.machineNum+1,    # $3 = machine number
    i)                      # $4 = instance index
    node.addService(PG.Execute(shell="bash", command=command))
    # Fail-loud verification that this node's inner VM was created and joined k0s.
    node.addService(PG.Execute(shell="bash", command="/local/repository/scripts/verify_node.sh {}".format(i)))
    node.hardware_type = params.ManagerHardware if i == 0 else params.Hardware
    iface = node.addInterface()
    iface.addAddress(PG.IPv4Address("10.1."+str(i+1)+".1", netmask))
    network.addInterface(iface)

node = rspec.RawPC("Global-SC")
node.disk_image = os
node.addService(PG.Execute(shell="bash", command=ensure_repo_cmd()))
node.addService(PG.Execute(shell="bash", command=profileConfigs + "/local/repository/scripts/configure.sh"))
command="/local/repository/scripts/build_globalsc.sh {}".format(params.machineNum+1)
node.addService(PG.Execute(shell="bash", command=command))
node.hardware_type = params.ProxyHardware
iface = node.addInterface()
iface.addAddress(PG.IPv4Address("10.4.1.1", netmask))
network.addInterface(iface)

for i in range(0,params.machinePNum):
    node = rspec.RawPC("Proxy" + str(i))
    node.disk_image = os
    node.addService(PG.Execute(shell="bash", command=ensure_repo_cmd()))
    node.addService(PG.Execute(shell="bash", command=profileConfigs + "/local/repository/scripts/configure.sh"))
    command="/local/repository/scripts/build_proxy.sh {} {}".format(params.machineNum+1, i)
    node.addService(PG.Execute(shell="bash", command=command))
    node.hardware_type = params.ProxyHardware
    iface = node.addInterface()
    iface.addAddress(PG.IPv4Address("10.3."+str(i+1)+".1", netmask))
    network.addInterface(iface)


pc.printRequestRSpec(rspec)


