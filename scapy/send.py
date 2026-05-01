from scapy.all import *

import sys

iface = "enp1s0"   # change to your interface
dst_ip = "10.0.0.2"

mode = "normal"
if len(sys.argv) > 1:
    mode = sys.argv[1]

# DSCP EF = 46 → TOS = 46 << 2 = 184
if mode == "realtime":
    tos = 46 << 2
    print("Sending REALTIME traffic (DSCP=46)")
else:
    tos = 0
    print("Sending NORMAL traffic")

pkt = Ether() / IP(dst=dst_ip, tos=tos) / UDP(dport=1234) / Raw("HelloTofino")

sendp(pkt, iface=iface, count=10, inter=0.5)
