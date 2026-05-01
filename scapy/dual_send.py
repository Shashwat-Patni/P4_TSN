from scapy.all import *
import sys
import threading
import time

args = sys.argv[1:]

if len(args) != 6:
    print("usage dual_send_time.py <src_ip> <dst_ip> <msg1> <msg2> <interface> <duration_sec>")
    exit(1)

src_ip = args[0]
dst_ip = args[1]
msg1 = args[2]
msg2 = args[3]
iface = args[4]
duration = float(args[5])

barrier = threading.Barrier(2)


def send_flow(msg, sport):
    # Synchronize both flows
    barrier.wait()

    start_time = time.time()
    end_time = start_time + duration
    count = 0

    print(f"Flow (sport={sport}) starting...")

    while time.time() < end_time:
        p = Ether() / \
            IP(dst=dst_ip, src=src_ip, ttl=64) / \
            UDP(sport=sport, dport=5000) / \
            (msg + "_seq_" + str(count))

        sendp(p, iface=iface, verbose=False)
        count += 1

    print(f"Flow (sport={sport}) sent {count} packets")


t1 = threading.Thread(target=send_flow, args=(msg1, 4001))
t2 = threading.Thread(target=send_flow, args=(msg2, 4002))

print("Starting both flows simultaneously...")

t1.start()
t2.start()

t1.join()
t2.join()

print("Both flows finished.")
