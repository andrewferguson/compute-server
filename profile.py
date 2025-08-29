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
pc.defineParameter("numberGNB", "Number of gNB", portal.ParameterType.INTEGER, 1)
pc.defineParameter("numberUE", "Number of UE", portal.ParameterType.INTEGER, 1)
pc.defineParameter("proxyPerNode", "Number of Proxy per Node", portal.ParameterType.INTEGER, 1)
pc.defineParameter("Hardware", "Outer Node Hardware", portal.ParameterType.NODETYPE,"pc")
pc.defineParameter("ProxyHardware", "Proxy Machine Hardware", portal.ParameterType.NODETYPE,"pc")
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

# Calculate the number of gNB per node
gNBPerNode = int(math.ceil(params.numberGNB / params.machineNum))

# Machines
for i in range(0,params.machineNum):
    node = rspec.RawPC("node" + str(i))
    node.disk_image = os
    node.addService(PG.Execute(shell="bash", command=profileConfigs + "/local/repository/scripts/configure.sh"))
    command = "/local/repository/scripts/build_kernel.sh {} {} {} {} {} {} {}".format(
    params.token,           # $1 = token
    params.githubUser,      # $2 = GitHub username
    params.machineNum,      # $3 = machine number
    i,                      # $4 = instance index
    params.numberGNB,       # $5 = number of gNB
    gNBPerNode,             # $6 = number of gNB per node
    params.proxyPerNode)    # $7 = number of proxy per node
    node.addService(PG.Execute(shell="bash", command=command))
    node.hardware_type = params.Hardware
    iface = node.addInterface()
    iface.addAddress(PG.IPv4Address("10.1."+str(i+1)+".1", netmask))
    network.addInterface(iface)

node = rspec.RawPC("GlobalSC")
node.disk_image = os
node.addService(PG.Execute(shell="bash", command=profileConfigs + "/local/repository/scripts/configure.sh"))
command="/local/repository/scripts/build_globalsc.sh {}".format(params.machineNum)
node.addService(PG.Execute(shell="bash", command=command))
node.hardware_type = params.ProxyHardware
iface = node.addInterface()
iface.addAddress(PG.IPv4Address("10.4.1.1", netmask))
network.addInterface(iface)

machinePNum = int(math.ceil(params.numberGNB / params.proxyPerNode))
for i in range(0,machinePNum):
    node = rspec.RawPC("Proxy" + str(i))
    node.disk_image = os
    node.addService(PG.Execute(shell="bash", command=profileConfigs + "/local/repository/scripts/configure.sh"))
    command="/local/repository/scripts/build_proxy.sh {} {}".format(params.machineNum, i)
    node.addService(PG.Execute(shell="bash", command=command))
    node.hardware_type = params.ProxyHardware
    iface = node.addInterface()
    iface.addAddress(PG.IPv4Address("10.3."+str(i+1)+".1", netmask))
    network.addInterface(iface)


pc.printRequestRSpec(rspec)


