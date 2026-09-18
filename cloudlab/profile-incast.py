"""N-to-1 incast testbed for RoCEv2 / NVMe-over-Fabrics congestion control
(NSF CISE CRII #2450832).

One "target" node exports a null_blk namespace over nvmet-rdma. N "initiator"
nodes connect with nvme-rdma and WRITE concurrently. Writes (not reads) are what
create true incast: N senders at line rate converge on the target's single port,
oversubscribing the switch egress toward the target N:1, which is where PFC
pause frames and ECN marking actually engage.

Reads would put the bottleneck on the target's own egress instead, which
throttles at the host NIC and never builds a switch queue -- that is why the
2-node 1:1 read test on 2026-09-01 produced zero pause frames at 89% of line
rate. See cloudlab/README.md.

null_blk backing means concurrent multi-host writes are harmless (the device
discards them), so no real storage is at risk.

All nodes sit on one LAN: target 10.10.1.1, initiators 10.10.1.2 .. .1+N.
"""

import geni.portal as portal
import geni.rspec.pg as pg
import geni.rspec.emulab  # noqa: F401

pc = portal.Context()

pc.defineParameter(
    "hwtype", "Hardware type",
    portal.ParameterType.NODETYPE, "c6525-25g",
    longDescription="c6525-25g (Utah): AMD EPYC, ConnectX-5 25 GbE -- the cheap "
                    "venue for incast. c6525-100g is the 100 GbE sibling.")
pc.defineParameter(
    "numInitiators", "Number of initiators (senders converging on the target)",
    portal.ParameterType.INTEGER, 4,
    longDescription="Oversubscription ratio at the target port. 4 initiators on "
                    "25 GbE offer ~100 Gb/s into a 25 Gb/s port = 4:1.")
pc.defineParameter(
    "osimage", "OS image",
    portal.ParameterType.IMAGE,
    "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU22-64-STD")
pc.defineParameter(
    "linkbw", "LAN bandwidth (Kbps)",
    portal.ParameterType.INTEGER, 25000000,
    [(25000000, "25 Gb/s"), (100000000, "100 Gb/s"), (0, "Any (mapper chooses)")])
pc.defineParameter(
    "sameSwitch", "Keep all nodes on one switch (single congestion point)",
    portal.ParameterType.BOOLEAN, True,
    longDescription="Keeps the oversubscription at a single, known switch port. "
                    "Turn off only if the mapper cannot satisfy it.")
pc.defineParameter(
    "installTools", "Install RDMA/NVMe tooling at boot",
    portal.ParameterType.BOOLEAN, True)

params = pc.bindParameters()
if params.numInitiators < 1 or params.numInitiators > 16:
    pc.reportError(portal.ParameterError(
        "numInitiators must be between 1 and 16", ["numInitiators"]))
pc.verifyParameters()

request = pc.makeRequestRSpec()

SETUP = ("sudo bash -c 'DEBIAN_FRONTEND=noninteractive apt-get update -q && "
         "DEBIAN_FRONTEND=noninteractive apt-get install -yq rdma-core ibverbs-utils "
         "rdmacm-utils infiniband-diags perftest nvme-cli fio mstflint ethtool libaio1 "
         "> /local/setup-apt.log 2>&1'")

lan = request.LAN("roce-lan")
if params.linkbw > 0:
    lan.bandwidth = params.linkbw
if params.sameSwitch:
    lan.setNoInterSwitchLinks()

names = ["target"] + ["initiator%d" % i for i in range(1, params.numInitiators + 1)]
for idx, name in enumerate(names):
    node = request.RawPC(name)
    node.hardware_type = params.hwtype
    node.disk_image = params.osimage
    iface = node.addInterface("if%d" % idx)
    iface.addAddress(pg.IPv4Address("10.10.1.%d" % (idx + 1), "255.255.255.0"))
    lan.addInterface(iface)
    if params.installTools:
        node.addService(pg.Execute(shell="bash", command=SETUP))

pc.printRequestRSpec(request)
