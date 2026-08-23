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
pc.defineParameter("numGNB", "Number of gNB", portal.ParameterType.INTEGER, 1)
pc.defineParameter("numUE", "Number of UE", portal.ParameterType.INTEGER, 1)
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

# NOTE on repository-clone resilience: CloudLab clones this profile's git repo
# into /local/repository as startup "execution 0", guarded by an abort-on-failure
# check, BEFORE any service below runs. A transient failure of that clone (the
# GitHub HTTP/2 framing bug) therefore aborts the whole node before any profile
# service executes -- so it cannot be repaired by a service added here. Hardening
# that clone has to happen at the image/CloudLab level, not in these services.
# What IS handled here: in-script clones use git_clone_retry (HTTP/1.1 + retry),
# and verify_node.sh below turns a node that came up incomplete into a loud
# failure instead of a silent one.

# Machines
for i in range(0,params.machineNum+1):
    node = rspec.RawPC("node" + str(i))
    node.disk_image = os
    node.addService(PG.Execute(shell="bash", command=profileConfigs + "/local/repository/scripts/configure.sh"))
    command = "/local/repository/scripts/build_kernel.sh {} {} {} {} {} {} {}".format(
    params.token,           # $1 = token
    params.githubUser,      # $2 = GitHub username
    params.machineNum+1,    # $3 = machine number
    i,                      # $4 = instance index
    params.machinePNum,     # $5 = proxy node count
    params.numGNB,          # $6 = number of gNB
    params.numUE)           # $7 = number of UE
    node.addService(PG.Execute(shell="bash", command=command))
    # Fail-loud verification that this node's inner VM was created and joined k0s.
    node.addService(PG.Execute(shell="bash", command="/local/repository/scripts/verify_node.sh {}".format(i)))
    node.hardware_type = params.ManagerHardware if i == 0 else params.Hardware
    iface = node.addInterface()
    iface.addAddress(PG.IPv4Address("10.1."+str(i+1)+".1", netmask))
    network.addInterface(iface)

node = rspec.RawPC("Global-SC")
node.disk_image = os
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
    node.addService(PG.Execute(shell="bash", command=profileConfigs + "/local/repository/scripts/configure.sh"))
    command="/local/repository/scripts/build_proxy.sh {} {}".format(params.machineNum+1, i)
    node.addService(PG.Execute(shell="bash", command=command))
    node.hardware_type = params.ProxyHardware
    iface = node.addInterface()
    iface.addAddress(PG.IPv4Address("10.3."+str(i+1)+".1", netmask))
    network.addInterface(iface)


pc.printRequestRSpec(rspec)


