import socket
from collections import defaultdict
import time

LISTEN_PORT = 5000

def main():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("", LISTEN_PORT))

    print(f"Listening on port {LISTEN_PORT}...\n")

    packet_count = defaultdict(int)
    total = 0
    start_time = time.time()

    try:
        while True:
            data, addr = sock.recvfrom(65535)
            src_ip, src_port = addr

            flow_id = f"{src_ip}:{src_port}"
            packet_count[flow_id] += 1
            total += 1

            # Print stats every 2 seconds
            if int(time.time() - start_time) % 2 == 0:
                print("\n---- Current Stats ----")
                for flow, count in packet_count.items():
                    percentage = (count / total) * 100 if total > 0 else 0
                    print(f"{flow} -> {count} packets ({percentage:.2f}%)")
                print(f"Total packets received: {total}")
                print("-----------------------")

    except KeyboardInterrupt:
        print("\nFinal Results:")
        for flow, count in packet_count.items():
            percentage = (count / total) * 100 if total > 0 else 0
            print(f"{flow} -> {count} packets ({percentage:.2f}%)")
        print(f"Total packets received: {total}")

if __name__ == "__main__":
    main()