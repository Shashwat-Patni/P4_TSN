# End-Semester Report: QoS-based Priority Queuing and Traffic Classification on Tofino ASIC

**Shashwat Patni**
f20230390@goa.bits-pilani.ac.in
SOP 2025-26

---

## Abstract

This report covers the full arc of the project from midsem to end-sem. The first half documents the successful implementation of QoS-based priority queuing on the Intel Tofino 1 ASIC using a P4 programmable data plane and the BFRT Python API to configure the fixed-function Traffic Manager. The key observation was that different traffic classes can be steered into separate queues with independent buffer and scheduling guarantees, demonstrating that a Tofino switch can enforce true per-class QoS entirely at line rate. The second half surveys the landscape of network traffic classification techniques — the problem that must be solved before QoS can be applied automatically — with emphasis on statistical/behavioral methods and Deep Packet Inspection (DPI). We conclude by narrowing the project scope to a practical next step: identifying a small set of target applications from live flows using a mixture of statistical and DPI techniques.

---

## Part 1: QoS Priority Queuing on Tofino ASIC (Midsem Work)

### 1.1 Introduction and Problem Decomposition

The goal of this project is to enable automatic QoS-based priority queuing on the Tofino ASIC. The system can be decomposed into two distinct problems:

1. **Traffic Manager (TM) Configuration** — how to configure the fixed-function TM component of the switch to enforce per-class queuing, buffering, and scheduling guarantees.
2. **P4-based Traffic Classification** — how to use the P4 programmable data plane to inspect packet headers, identify the traffic class (QoS level), and map it to the architecture-specific ICOS (Ingress Class of Service) value so the TM can act on it.

This midsem work covers Point 1 end-to-end and demonstrates Point 2 with a concrete P4 program that classifies DSCP EF (Expedited Forwarding) traffic as real-time.

### 1.2 Tofino Traffic Manager Architecture

The Traffic Manager on Tofino 1 sits between the ingress and egress pipelines. It is a **fixed-function** component — it cannot be programmed with P4 — but it is highly configurable via the BFRT (Barefoot Runtime) control plane API. The TM handles:

- **Classification and Marking** — using CoS, priority, and other packet fields set by the ingress pipeline.
- **Policing and Remarking** — admission decisions and DSCP remarking.
- **Admission Control** — input port buffer management using Priority Propagation Groups (PPGs).
- **Multicast Replication and Source Port Filtering**.
- **Queue Admission Control** — per-queue buffer limits.
- **Queuing and Scheduling** — strict priority and deficit weighted round-robin (DWRR) schedulers.
- **Scheduling and Shaping** — minimum/maximum rate guarantees per queue.
- **Egress Modification** and ECN marking.

The ingress pipeline writes QoS metadata (specifically `ig_tm_md.qid` and `ig_tm_md.ingress_cos`) which the TM reads to steer packets into the right queue. This is the coupling point between the P4 program and the Traffic Manager.

### 1.3 Getting Started: Full Setup Walkthrough

This section documents every step needed to go from a cold switch to a running P4 program with an active BFRT control plane session, incorporating procedures established across multiple prior SOP reports (Mohammed Ashraf & Chaitanya Joshi; Shivam).

#### Step 0: Physical Access — Connecting to the Switch

The Tofino 1 switch exposes two access paths: a **BMC console port** (serial) and an **OOB Ethernet port**.

**Serial / BMC Console (initial / recovery access):**
Connect the BMC Console port on the front panel to a laptop using a USB cable. Windows Device Manager will show a new `USB Serial Port (COMx)` entry. Open PuTTY, select `Serial` connection type, enter the COM port number and baud rate `9600`, and open the session.

- If the switch OS is already running you will land directly in the Ubuntu shell.
- If not, you will land on the BMC prompt. From there, power on the switch OS using:

```bash
wedge_power.sh          # power on the switch OS
sol.sh                  # enter the switch OS serial-over-LAN session
```

Use `Ctrl+X` to exit the SOL session back to the BMC.

**SSH access (normal working path):**
The switch OS maintains a persistent reverse SSH tunnel to the lab's antserver. Once the switch OS is running, connect directly from the antserver:

```bash
ssh -p 9999 developer@switch
```

This is the standard working path for day-to-day use. The reverse tunnel is set up as:
```
-R 0.0.0.0:9999:localhost:22
```
which forwards antserver port 9999 back to port 22 (SSH) on the switch OS.



---

#### Step 1: Set SDE Path Variables (after every reboot)

After any reboot, SDE environment variables (`$SDE`, `$SDE_INSTALL`) are not set automatically. Verify this first:

```bash
echo $SDE
```

If the output is empty, source the path script:

```bash
cd ~/scripts
source set_sde_path
```

This must be done once per login/reboot before any compile, build, or run step will work.

---

#### Step 2: Place and Compile the P4 Program

**Directory structure:** P4 code must follow the convention:

```
~/code/<p4-program-name>/<p4-program-name>.p4
```

For this project: `~/code/RealTIME/RealTIME.p4`

**Compile** using the Barefoot P4 compiler (`bf-p4c`):

```bash
cd ~/code/RealTIME
$SDE_INSTALL/bin/bf-p4c RealTIME.p4
```

The compiler targets the TNA architecture.

---

#### Step 3: Build and Install the Compiled Program

```bash
cd ~/scripts
source p4build_command_param RealTIME
make
make install
```


---

#### Step 4: Load Kernel Modules

Before running the daemon, load the required kernel module:

```bash
cd ~/scripts
source load_program.sh
```




---

#### Step 5: Load and Run the P4 Program (switch daemon)

Start the switch daemon with the compiled program. Run it in the background so the terminal remains available for control-plane work:

```bash
cd $SDE
./run_switchd.sh -p RealTIME 
```


Press Enter to get your prompt back. The daemon continues running in the background.


---

#### Step 6: Enable Physical Ports via UCLI

The switch daemon starts with all physical ports **disabled** by default. Ports must be explicitly enabled before traffic flows or the TM can be exercised. This is done inside the BFShell UCLI .

First, check which physical ports have cables connected:

```
bfshell> ucli
bf-sde> bf_pltfm qsfp show
```

This lists all physical ports that have cables inserted. Note the `port` column — this is the physical port number, which is different from the virtual (dev_port) number used by P4 and BFRT.

Then navigate to the port manager and inspect current status:

```
bf-sde> pm
bf-sde.pm> show
```

**Understanding the `pm show` columns:**

```
PORT | MAC  | D_P | P/PT | SPEED | FEC | AN  | KR  | RDY | ADM | OPR | LPBK | FRAMES RX | FRAMES TX
29/0 | 3/0  |  24 | 0/24 | 100G  | RS  | Au  | Au  | --- | DIS | DWN | NONE |     0     |     0
32/0 | 2/0  |  16 | 0/16 | 100G  | RS  | Au  | Au  | --- | DIS | DWN | NONE |     0     |     0
```

| Column | Meaning |
|---|---|
| `PORT` | Physical port / breakout lane (e.g., `29/0` = port 29, lane 0) |
| `D_P` | **Virtual dev_port number** — this is what P4 and BFRT use, not the physical number |
| `ADM` | Admin state: `DIS` = disabled, `ENB` = enabled |
| `OPR` | Operational state: `UP` = link up and passing packets, `DWN` = no link |
| `FRAMES RX/TX` | Packet counters — useful for verifying traffic is flowing |

> **Important:** BFRT and P4 code use the `D_P` (virtual dev_port) number, not the physical port label. For example, port `29/0` has dev_port `24`. Always cross-reference `pm show` when writing table entries or TM configuration commands.

**Adding and enabling a port** — the three-command sequence:

```
# 1. Add the port at the correct speed with FEC setting
bf-sde.pm> port-add <port_str> <speed> <fec>
# 2. Set auto-negotiation
bf-sde.pm> an-set <port_str> 2
# 3. Enable the port
bf-sde.pm> port-enb <port_str>
```

The `<port_str>` uses the format `<physical-port>/<lane>`, or `-` as a wildcard for all lanes (e.g., `29/-` means all breakout lanes of port 29). Speeds supported: `1G, 10G, 25G, 40G, 100G, 200G, 400G`. FEC is generally `NONE`.

Example (port 19):

```
bf-sde.pm> port-add 19/- 10G NONE
bf-sde.pm> an-set 19/- 2
bf-sde.pm> port-enb 19/-
bf-sde.pm> show
```

To enable the internal CPU Ethernet port (port 33, 1G):

```
bf-sde.pm> port-add 33/- 1G NONE
bf-sde.pm> an-set 33/- 2
bf-sde.pm> port-enb 33/-
```




To exit UCLI and return to BFShell:
```
bf-sde> exit
bfshell>
```


---

#### Step 7: Access the BFRT Control Plane

There are two equivalent ways to issue control-plane commands — the **interactive BFShell Python session** (used for TM configuration in this project) and the **gRPC Python client** (useful for scripted/automated control).

**BFShell navigation tips (from Shivam's report):**
- Press `Tab` at any prompt to list all available sub-commands or objects at that level.
- Type `..` to go up one level in the hierarchy.
- To exit BFShell entirely: `Ctrl+\`

**Option A — Interactive BFShell BFRT Python (used in this project):**

Exit the UCLI with `exit`, return to the BFShell prompt, and start the interactive Python session:

```
bfshell> bfrt_python
```

Tables are accessed hierarchically:

```python
bfrt.<p4-program-name>.pipe.<control-block-name>.<table-name>
```

For example, to navigate to the `ipv4_lpm` table in the `Ingress` control block of the `RealTIME` program:

```python
bfrt.RealTIME.pipe.Ingress.ipv4_lpm
```

Common table operations (use `dump` to list all current entries, `info` to see table size and schema):

```python
# Add a new entry
<table>.add_with_<action-name>(<key>, <parameter>)

# Modify an existing entry
<table>.mod_with_<action-name>(<key>, <parameter>)

# Set the default action
<table>.set_default_with_<action-name>(<key>, <parameter>)

# Delete a specific entry
<table>.delete(<key>)
```

All TM configuration commands in Sections 1.4–1.6 are issued from this prompt.

**Option B — gRPC Python client (from Mohammed & Chaitanya's prior work):**

From any machine with network access to the switch (typically the switch OS itself), connect programmatically:

```python
import grpc
import bfrt_grpc.bfruntime_pb2 as bfruntime_pb2
import bfrt_grpc.client as bfrt_client

# Connect to the BFRT gRPC server on port 50052
interface = bfrt_client.ClientInterface(
    grpc_addr='localhost:50052',
    client_id=0,
    device_id=0
)
print('Connected to BF Runtime Server')

# Get the running program info and bind to it
bfrt_info = interface.bfrt_info_get()
print('The target runs the program ', bfrt_info.p4_name_get())
interface.bind_pipeline_config(bfrt_info.p4_name_get())
```

This gRPC path is the basis for the `bfrt_starter.py` pattern used in prior SOP work and is also how programmatic table management (add/delete/update/read entries) is done from external control-plane scripts. To run such a script while the switchd is running in the background:

```bash
cd $SDE
./run_switchd.sh -p RealTIME &
# (press Enter to get prompt back)
python3 bfrt_starter.py
```

---

#### Step 8: Navigate to the TM Namespace

Within the interactive BFShell Python session, the Traffic Manager is accessed under a separate namespace from P4 tables:

```python
bfrt.tf1.tm.<tab>
```

Use tab-completion to explore available TM sub-tables. All TM configuration objects live under `bfrt.tf1.tm` (or `bfrt.tf2.tm` depending on chip variant). The key sub-namespaces used in this project are:

| Namespace | Purpose |
|---|---|
| `bfrt.tf1.tm.port.cfg` | Per-port QID mapping and port group info |
| `bfrt.tf1.tm.ppg.cfg` | Ingress Priority Propagation Group (buffer + ICoS) |
| `bfrt.tf1.tm.queue.buffer` | Egress queue buffer allocation |
| `bfrt.tf1.tm.queue.sched_shaping` | Queue min/max rate shaping |
| `bfrt.tf1.tm.queue.sched_cfg` | Queue scheduler priority and enable flags |

### 1.4 Understanding the QID-to-Queue Mapping

Before configuring queues, it is important to understand how the P4 pipeline's `qid` metadata value maps to actual physical queues on the egress port. This is retrieved per egress dev_port:

```python
bfrt.tf1.tm.port.cfg.get(dev_port=138)
```

Sample output:
```
Entry key:
    dev_port              : 0x0000008A
Entry data:
    pg_id                 : 0x02
    pg_port_nr            : 0x02
    port_queues_count     : 0x08
    ingress_qid_map       : [0, 1, 2, 3, 4, 5, 6, 7, 0, 1, 2, ...]
    egress_qid_queues     : [16, 17, 18, 19, 20, 21, 22, 23, ...]
```

This tells us that if the P4 program sets `ig_tm_md.qid = 4`, that packet will be placed in physical queue 4 of the egress pipeline. The `pg_id` field (port group ID) is needed for all subsequent queue buffer and scheduling configuration commands.

### 1.5 Configuring Real-Time Traffic — Ingress Side

Real-time traffic (e.g., VoIP, video conferencing) requires guaranteed buffer space and cannot share the default pool with best-effort traffic. The configuration proceeds in three steps.

#### Step 1: Assign the Ingress Port to a Priority Propagation Group (PPG)

By default, all ingress ports belong to the Default Priority Group (DPG). We create a dedicated PPG for real-time traffic and bind our ingress port (dev_port 16) to it:

```python
bfrt.tf2.tm.ppg.cfg.add_with_dev_port(
    pipe=0,
    ppg_id=1,
    dev_port=16
)
```

- `dev_port=16` is the ingress port receiving real-time traffic.
- `ppg_id=1` is the new PPG identifier; it must be unique and is referenced in all subsequent steps.

#### Step 2: Configure Guaranteed Ingress Buffer

Once the port is assigned to the PPG, configure the guaranteed buffer. This ensures that when congestion occurs at the ingress, real-time packets are not dropped even before they reach the egress queue.

Verifying the current PPG state:
```
Entry data (action : dev_port):
    dev_port           : 0x00000010
    pfc_enable         : False
    icos_0 ... icos_7  : False (all)
    guaranteed_cells   : 0x00000000
    hysteresis_cells   : 0x00000080
    pool_id            : IG_APP_POOL_0
    pool_max_cells     : 0x00000000
    dynamic_baf        : DISABLE
```

Apply the guaranteed buffer:

```python
bfrt.tf2.tm.ppg.cfg.mod_with_dev_port(
    pipe=0,
    ppg_id=1,
    guaranteed_cells=20
)
```

> **Note:** The guaranteed minimum buffer size must be chosen with the RX MTU in mind. If `guaranteed_cells` is too small for the maximum packet size on this link, packets will be dropped even without shared pool exhaustion.

#### Step 3: Map ICoS to the PPG

The ingress CoS value (`icos`) is what the P4 program writes into `ig_tm_md.ingress_cos`. We associate ICoS 4 with our PPG, so any packet the P4 program marks with ICoS 4 will be steered into this priority group:

```python
bfrt.tf2.tm.ppg.cfg.mod_with_dev_port(
    pipe=0,
    ppg_id=1,
    icos_4=True
)
```

### 1.6 Configuring Real-Time Traffic — Egress Side

On the egress side, the goal is to give the real-time queue a small, dedicated buffer (so it is not starved by best-effort traffic) and a guaranteed minimum transmission rate.

#### Step 1: Inspect Current Queue Buffer State

```python
bfrt.tf2.tm.queue.buffer.get(pipe=0, pg_id=3, pg_queue=4)
```

```
Entry data (action : shared_pool):
    guaranteed_cells  : 0x00000024
    hysteresis_cells  : 0x00000020
    tail_drop_enable  : True
    pool_id           : EG_APP_POOL_0
    pool_max_cells    : 0x0000002B
    dynamic_baf       : 80%
```

The `pg_id=3` and `pg_queue=4` correspond to queue 4 of port group 3, which is the queue the P4 program targets when it sets `qid=4`.

#### Step 2: Set Minimal Egress Buffer for Real-Time Queue

For real-time traffic we want to minimize buffering (to minimize latency) and disable shared pool access (to prevent it from being blocked by best-effort traffic):

```python
bfrt.tf2.tm.queue.buffer.mod_with_buffer_only(
    pipe=0,
    pg_id=3,
    pg_queue=4,
    guaranteed_cells=20
)
```

Using `mod_with_buffer_only` automatically sets `pool_max_cells=0`, disabling shared pool usage for this queue entirely.

#### Step 3: Set a Guaranteed Minimum Rate (Traffic Shaping)

The current default shaping state before modification:
```
Entry data:
    unit            : BPS
    provisioning    : UPPER
    min_rate        : 0x00000000
    min_burst_size  : 0x00004000
    max_rate        : 0x05F5E0FF
    max_burst_size  : 0x00004000
```

Apply a minimum guaranteed rate of 100 Mbps for the real-time queue:

```python
bfrt.tf2.tm.queue.sched_shaping.mod(
    pipe=0,
    pg_id=3,
    pg_queue=4,
    min_rate=100000000
)
```

#### Step 4: Enable Minimum Rate and Set HIGH Priority

```python
bfrt.tf2.tm.queue.sched_cfg.mod(
    pipe=0,
    pg_id=3,
    pg_queue=4,
    min_rate_enable=True,
    min_priority='HIGH'
)
```

Before this command, the scheduling configuration shows `min_priority: LOW` and `min_rate_enable: False`. After this command, the real-time queue is given `HIGH` scheduling priority and the minimum rate guarantee is active. 
### 1.7 The P4 Program: RealTIME.p4

The P4 program ([RealTIME.p4](RealTIME.p4)) implements the data-plane side of the QoS pipeline. It targets the **TNA (Tofino Native Architecture)** via `tna.p4` and P4_16.

#### Header Definitions

The parser handles three header types:

- `ethernet_h` — standard Ethernet header with EtherType.
- `vlan_tag_h` — 802.1Q VLAN tag, including the 3-bit `pri` field (PCP) and 12-bit `vid`.
- `ipv4_h` — full IPv4 header including the `diffserv` (DSCP+ECN) byte.

#### Ingress Parser

The parser implements a standard state machine: `start → parse_ethernet → (parse_vlan_tag →) parse_ipv4 → accept`. It gracefully handles both tagged and untagged frames.

#### Ingress Control Logic

The core QoS logic is in the `Ingress` control block:

```p4
apply {
    if (hdr.ipv4.isValid()) {

        /* Step 1: forwarding */
        ipv4_lpm.apply();

        /* Step 2: default QoS (normal traffic) */
        ig_tm_md.qid = 0;
        ig_tm_md.ingress_cos = 0;
        ig_tm_md.packet_color = 0;

        /* Step 3: classify realtime traffic */
        bit<6> dscp = hdr.ipv4.diffserv[7:2];

        if (dscp == 46) {   // EF traffic
            ig_tm_md.qid = 7;
            ig_tm_md.ingress_cos = 7;
        }
    }
}
```

**What this does:**
1. All IPv4 packets are first forwarded via an LPM table (`ipv4_lpm`) that maps destination addresses to output ports.
2. Every packet receives a default QoS assignment of `qid=0`, `ingress_cos=0` — placing it in the normal best-effort queue with no special treatment.
3. The DSCP field is extracted from bits `[7:2]` of the `diffserv` byte (the DSCP occupies the upper 6 bits). If the DSCP value is **46** (the IETF Expedited Forwarding codepoint), the packet is reclassified to `qid=7` and `ingress_cos=7`, directing it to the highest-priority queue managed by the TM configuration above.

The `ipv4_lpm` table has a default action of `set_output(CPU_PORT)`, sending unknown destinations to the CPU for control-plane learning.

#### Egress Pipeline

The egress pipeline in this program is intentionally minimal — an empty `Egress` control block and a straightforward deparser that re-emits all parsed headers. All QoS enforcement happens in the Traffic Manager between ingress and egress; no per-packet modification is needed at egress for this use case.

### 1.8 Testing with Scapy: Sending Test Traffic

To verify the P4 program and TM configuration, test traffic was generated using Scapy-based Python scripts from a connected host.

#### The Send Script

[send.py](send.py) sends a small burst of UDP packets to the switch. It accepts an optional command-line argument to switch between normal and real-time traffic modes:

```bash
# Send normal traffic (DSCP = 0)
python3 send.py

# Send real-time traffic (DSCP EF = 46)
python3 send.py realtime
```

The key detail is how DSCP EF is encoded into the IP `tos` field: since DSCP occupies the upper 6 bits of the TOS byte, DSCP 46 maps to `tos = 46 << 2 = 184`. The script constructs a raw Ethernet frame (`Ether() / IP(...) / UDP(...) / Raw(...)`) and sends it directly on the wire via `sendp`, bypassing the host OS routing stack — important when the host is directly cabled to the Tofino port.

#### The Dual-Flow Send Script

[dual_send.py](scapy/dual_send.py) sends two UDP flows simultaneously using Python threads and a `threading.Barrier` to synchronize their start times. The two flows use different source ports (`4001` and `4002`) and send for a configurable duration:

```bash
python3 dual_send.py <src_ip> <dst_ip> <msg1> <msg2> <interface> <duration_sec>
```

This is the primary script used to demonstrate queue separation: one flow can be marked with DSCP EF and the other left at DSCP 0, sending simultaneously so the TM's priority scheduling is exercised under concurrent load.

#### The Receive Script

[receive.py](scapy/receive.py) runs on the destination host and uses Scapy to sniff incoming packets on a specified interface. For each received IP packet it prints the source IP, destination IP, raw TOS value, and computed DSCP — and flags any packet with DSCP 46 as real-time. This provides a quick sanity check that the switch is not stripping or rewriting the DSCP markings end-to-end.

#### Forwarding Table Entries

For test traffic to be forwarded through the switch, entries must be added to the `ipv4_lpm` table in the P4 control plane. These are added from the BFShell BFRT Python session while the switch daemon is running:

```python
# Add a host route for the destination test IP
bfrt.RealTIME.pipe.Ingress.ipv4_lpm.add_with_set_output(
    dst_addr="10.0.0.2",
    prefix_len=32,
    port=138        # dev_port of the egress interface — cross-reference with pm show
)
```

Replace `10.0.0.2` and `prefix_len` with the actual test destination address, and `port` with the `D_P` (dev_port) value shown for the egress interface in `pm show`. Without this entry, the default action sends all packets to the CPU port and no traffic reaches the egress queue being tested.

### 1.9 Observations

Running the P4 program and configuring the TM as described above, we observed the following:

- **Traffic class separation is effective.** Packets with DSCP EF (46) were steered into queue 7, while all other IPv4 traffic landed in queue 0. Different traffic priority classes can be treated independently using the Traffic Manager.

- **The Traffic Manager enforces differentiated treatment.** The EF queue was configured with a guaranteed minimum rate (100 Mbps) and `HIGH` min-priority scheduling, while best-effort traffic used queue 0 with default parameters.

- **Buffer guarantees are configurable per queue.** With `pool_max_cells=0` set via `mod_with_buffer_only` on the EF queue, the queue operates from its dedicated `guaranteed_cells=20` reservation rather than the shared egress pool.

- **The BFRT Python API is the control point.** All TM configuration is runtime-changeable without reloading the P4 program. Queue weights, rate limits, and buffer allocations can be adjusted live.

---

## Part 2: Network Traffic Classification (Post-Midsem Work)

### 2.1 Motivation: Closing the Classification Loop

The P4 and TM work demonstrated that the switch can enforce any number of priority classes — but only if packets arrive pre-marked with the correct DSCP value. In practice, end hosts do not reliably self-mark traffic. To make QoS enforcement automatic, the switch must itself identify what application a flow belongs to and assign the appropriate priority. This is the traffic classification problem.

### 2.2 Survey of Classification Techniques

The field organizes naturally into technique families, from oldest to newest:

| Family | Examples | Works on Encrypted Traffic? |
|---|---|---|
| Port-based | IANA ports, ACLs | No (broken) |
| Deep Packet Inspection (DPI) | NBAR2, nDPI, Suricata | Partial |
| Protocol decoding | HTTP Host:, TLS SNI | Partial |
| Statistical / behavioral | Packet size, IAT, burst analysis | Yes |
| Flow-level ML | Random Forest, XGBoost, KNN | Yes |
| First-N packet methods | Bernaille (2006) | Yes |
| TLS / QUIC fingerprinting | JA3, JA4, JA4+ | Yes (handshake only) |
| Deep learning | CNN, LSTM, ET-BERT | Yes |
| Knowledge distillation | Mousika, ETKD, NetKD | Yes |
| In-network ML inference | IIsy, Leo, Planter, Synecdoche | Yes |
| Graph-based | BLINC, GraphDApp, GNN | Yes |

**Port-based classification** — the oldest and simplest technique, matching on the TCP/UDP 5-tuple — has largely broken down. Most modern applications multiplex over HTTPS (port 443), use dynamic or ephemeral ports, or deliberately obfuscate their assignment (P2P, malware). It remains useful only as a fast-path first filter in tightly controlled environments.

**Protocol decoding** (e.g., parsing the HTTP `Host:` header or the TLS SNI field in the Client Hello) extends beyond raw port matching into the application layer. TLS SNI has been the single most useful plaintext signal for classifying HTTPS flows, but it is being eroded by Encrypted Client Hello (ECH, RFC 9180), which encrypts the SNI. This forces the field toward the encryption-resilient approaches below.

**TLS/QUIC fingerprinting** (JA3, JA4+) exploits the fact that even when payload is encrypted, the TLS handshake itself is partially observable. JA3 hashes five fields from the Client Hello (version, cipher suites, extensions, elliptic curves, EC point formats) into a 32-character fingerprint. JA3 is increasingly unreliable because modern browsers randomize extension ordering. Its successor, **JA4**, sorts fields before hashing, neutralizing permutation evasion. Modern WAFs (Cloudflare, Akamai) correlate JA4 with JA4T (TCP fingerprint) and JA4H (HTTP fingerprint) to detect inconsistencies. However, once ECH is universally deployed, all handshake-based techniques will lose their visibility into the destination service.

**In-network ML inference** (IIsy, Leo, Planter, Synecdoche) represents the newest frontier: compiling trained classifiers — typically decision trees or random forests — into P4 match-action table entries that run at line rate on the switch ASIC itself. This is the long-term direction for integrating classification with QoS enforcement on Tofino.

### 2.3 Statistical and Behavioral Classification (In Depth)

Statistical methods operate exclusively on packet/flow metadata — sizes, timing, directions, counts — without ever touching payload. They are inherently encryption-agnostic and are therefore the most important family for modern encrypted networks.

#### 2.3.1 Per-Packet Features

**Packet size** is one of the most discriminating features in the classification literature. Different application types produce characteristic size distributions:

- VoIP (G.711): fixed ~200-byte packets due to codec frame size.
- Video streaming: packets frequently near the MTU (1500 bytes) during buffer-fill bursts.
- ACK-only TCP segments: 60 bytes.
- Interactive/gaming: small, frequent packets.

Internet traffic is empirically bimodal — "mice" (small control/ACK packets) and "elephants" (near-MTU data packets). This distribution alone provides a coarse but fast classifier.

**TCP flag patterns** — the sequence and frequency of SYN, ACK, FIN, PSH, RST flags — are characteristic of different application behaviors.

**Upstream/downstream asymmetry:** Web browsing is highly asymmetric (small HTTP requests, large responses). VoIP and gaming are symmetric. The down-up byte ratio is a strong feature for distinguishing these classes.

#### 2.3.2 Inter-Arrival Time (IAT)

IAT — the temporal gap between consecutive packets of a flow — is one of the most powerful features for encrypted-traffic classification. Application classes produce dramatically different IAT signatures:

- **VoIP:** Tight, regular IAT (~20 ms, 50 packets/sec). The IAT distribution is nearly a delta function at the codec frame period.
- **Video streaming (adaptive, e.g., DASH/HLS):** Bursts of low-IAT packets during buffer fill, followed by long quiet periods. Bimodal IAT distribution.
- **Gaming:** Low, consistent IAT (30–60 ms) with jitter spikes during action events.
- **Web browsing:** Highly variable — bursts during page load, long idle intervals while the user reads.
- **Bulk file transfer:** Steady stream at the connection's congestion-window-limited rate.

Standard statistical features derived from IAT sequences: mean, median, standard deviation, skew, min/max, and percentiles (p10, p25, p75, p90). The Moore benchmark dataset uses 249 such statistical features. A practical caveat: IAT measurement requires hardware-assisted timestamping; software-timestamped IAT suffers from OS scheduling jitter that degrades classification accuracy.

#### 2.3.3 Packet Rate Analysis

Packet rate (packets per unit time) is related to IAT but expressed in the frequency domain. It supports coarse classification:

- **Constant bit rate (CBR):** VoIP, fixed-rate video — low variance in packet rate over a sliding window.
- **Variable bit rate (VBR):** Adaptive streaming (DASH, HLS) — periodic step changes in packet rate corresponding to ABR algorithm decisions.
- **Bursty/bulk:** File downloads, backups — rate saturates the congestion window.
- **Sparse/interactive:** SSH, telnet, gaming control — sparse stream punctuated by user input events.

#### 2.3.4 Burst Analysis

A burst is a sequence of consecutive packets whose inter-arrival times are below a threshold (typically 10 ms–2 s). Burst-level features are especially powerful for mobile traffic (where the cellular network encrypts below the transport layer). Useful features: burst sizes, burst durations, inter-burst durations, instantaneous downlink throughput within bursts, and packet count per burst. Random Forest classifiers built on burst features achieve ~95% accuracy on real cellular networks; voice and video calling are easiest to identify, audio streaming hardest (long inter-burst silences make burst features sparse).

#### 2.3.5 Flow-Level Features and First-N Packet Methods

A flow is defined by the 5-tuple (src IP, dst IP, src port, dst port, protocol). Flow-level features summarize the entire flow: total packets, total bytes, flow duration, idle time, average packet size, average IAT, down-up byte ratio, and segment size statistics.

Bernaille et al. (2006) showed that examining just the sizes of the **first 5 TCP data packets** is sufficient to identify the application with high accuracy. This "first-N packet" approach enables very early classification — before the application has revealed its full behavior. Modern variants use the first 10–20 packets and augment sizes with IAT and direction features.

#### 2.3.6 Classical ML on Statistical Features

With statistical features extracted at flow level, standard supervised classifiers achieve strong results:

- **Random Forest:** High accuracy, handles class imbalance; ~95% on burst features.
- **XGBoost/GBDT:** Top accuracy on tabular features; used in IIsy ensembles.
- **Decision Tree (C4.5/C5.0):** Interpretable; maps directly to P4 match-action tables (see Mousika, IIsy).
- **Shallow Neural Network:** NetScrapper ANN achieves 99.86% on 53 application classes.
- **C5.0 with packet rate + data rate + IAT statistics:** 99% recall and precision across 17 applications (Jenefa & Moses).

The critical insight for this project is that **decision trees trained on statistical features can be compiled directly to P4 match-action table entries and run in-network at line rate** (IIsy, Planter, Leo), closing the loop from classification to QoS enforcement without any CPU involvement.

### 2.4 Deep Packet Inspection (In Depth)

DPI examines packet payload bytes for known signatures or protocol-layer patterns. It operates at OSI layers 4–7 and can make highly confident, fine-grained application identifications — but only when traffic is not encrypted.

#### 2.4.1 The Core Mechanism

The fundamental DPI operation is signature matching against payload bytes at known offsets. Classic examples:

- HTTP: ASCII string `GET `, `POST `, or `HEAD ` at offset 0 of the TCP payload.
- BitTorrent: `\x13BitTorrent protocol` at the start of the handshake.

#### 2.4.2 Cisco NBAR2

Network Based Application Recognition 2 (NBAR2) is Cisco's flagship DPI engine, embedded in IOS/IOS-XE since 2000. It uses Protocol Description Language Modules (PDLMs) — downloadable rule files — to describe each application. NBAR2 supports 1500+ applications with less than 1% unclassified traffic. It integrates multiple mechanisms in order: port matching → payload signatures → behavioral heuristics. Protocol Packs are distributed independently of the IOS release train for rapid signature updates. SD-AVC cloud services enable first-packet classification by aggregating telemetry across a fleet of devices.

**Limitations:** Cannot inspect encrypted payloads (HTTPS, IPsec). Only examines the first ~400 bytes of payload. Requires Cisco Express Forwarding (CEF).

#### 2.4.3 Palo Alto App-ID

App-ID applies up to four mechanisms in sequence: (1) port + 5-tuple matching, (2) application payload signatures, (3) protocol decoding (parsing HTTP/SSH internals), and (4) heuristics for evasive applications. App-ID supports parent/child application relationships (e.g., `facebook-video` as a child of `facebook-base`) and maintains per-session state across the full application lifecycle.

#### 2.4.4 Open-Source: nDPI, Suricata, Zeek

- **nDPI** (used inside ntopng) is the de facto open-source DPI library, supporting 250+ protocols with continuous community updates. It parses TLS SNI fields and QUIC initial handshake CRYPTO frames to classify encrypted sessions where handshake metadata remains visible.
- **Suricata** is a rule-based IDS/IPS with DPI as part of its detection engine.
- **Zeek (formerly Bro)** takes a higher-level approach, parsing protocol semantics into structured event logs rather than matching raw bytes.
- **libprotoident** is a lightweight DPI library that uses only the first 4 bytes of payload in each direction — trading some accuracy for very low computational overhead.

#### 2.4.5 The Encryption Problem

DPI is increasingly limited by encryption. With TLS 1.3, QUIC (HTTP/3), and the upcoming Encrypted Client Hello (ECH), even the handshake metadata that DPI tools relied on is becoming opaque. ECH encrypts the SNI field of the Client Hello, removing the last reliable plaintext indicator of destination service identity. This fundamentally forces any DPI-dependent classifier to fall back on statistical/behavioral features or TLS fingerprinting for flows it cannot decrypt.

#### 2.4.6 Deep Learning for Payload Inspection

For scenarios where DPI is feasible (unencrypted or decrypted traffic), deep learning methods can automate feature extraction from raw bytes:

- **Deep Packet (Lotfollahi et al., 2020):** treats the first N bytes of a packet as a 1D image and applies a 1D-CNN. Combines packet-level CNN with stacked autoencoders for both application identification and traffic type characterization (browsing vs. streaming vs. P2P).
- **ET-BERT (Lin et al., WWW 2022):** pre-trains a BERT-style transformer on large volumes of unlabeled traffic, treating packet bytes as tokens. Fine-tuned for classification, it achieves state-of-the-art on five encrypted traffic tasks. Removing pre-training causes a 37.57% F1 drop, demonstrating the value of unsupervised pre-training on raw traffic.
- **RNN/LSTM:** models the temporal sequence of packet sizes and IATs. Useful for applications with long-range temporal dependencies.

These models are too large to run in the switch data plane directly, but they motivate the knowledge distillation approach (e.g., Mousika) where a large teacher model is distilled into a decision tree deployable on Tofino.

### 2.5 Narrowing Scope: Identifying a Few Apps via a Mixture of Techniques

After surveying the full landscape, we have converged on a focused, practical approach that is tractable within the constraints of the Tofino hardware and the available data.

#### 2.5.1 The Scope Decision

Rather than attempting to classify all possible application classes from scratch, we scope down to **identifying a small, well-defined set of target applications from live flows**. The candidate set includes high-value, QoS-sensitive applications with distinctive traffic signatures:

- **VoIP / video conferencing** (e.g., Zoom, WebRTC) — latency-sensitive, real-time, symmetric, fixed-IAT.
- **Video streaming** (e.g., YouTube, Netflix) — throughput-sensitive, adaptive bitrate, bursty, asymmetric.
- **Interactive gaming** — low-latency, small packets, symmetric.
- **Bulk file transfer / backup** — best-effort, large flows, saturating.

This set is small enough to label confidently, distinct enough to separate with statistical features, and covers the most important QoS differentiation cases.

#### 2.5.2 The Proposed Mixture of Techniques

No single technique is sufficient on its own. We propose a **two-stage pipeline**:

**Stage 1 — DPI / Protocol Decoding (Fast Path):**
For flows that are not yet fully encrypted (or for which handshake metadata is visible), apply lightweight DPI first:
- **TLS SNI parsing** (via nDPI or libprotoident): If the SNI is present in the Client Hello, the destination hostname identifies the application with high confidence. This fast path handles a significant fraction of flows.
- **QUIC CRYPTO frame parsing**: QUIC's initial packet contains the SNI in plaintext; nDPI can extract it.
- **Port-based pre-filter**: As a zero-cost initial filter, known well-behaved applications (DNS on 53, NTP on 123) are classified immediately without deeper inspection.

**Stage 2 — Statistical Classification (Fallback / Verification):**
For flows where DPI is blind (fully encrypted, ECH, DSCP already stripped), or to cross-validate the DPI result:
- Extract **first-N packet features** (sizes and directions of the first 10–15 packets) as soon as the flow begins.
- Compute **IAT statistics** (mean, std, min/max, percentiles) over a short measurement window.
- Compute **burst features** (burst count, burst size distribution, inter-burst gap) where applicable.
- Feed these features into a **lightweight decision tree or Random Forest** classifier trained on labeled captures of the target applications.

The two stages are complementary: DPI provides high-confidence labels where it can see payload; statistical classification handles the encrypted residual. Combining both stages also enables **cross-validation** — if DPI says Zoom but statistics look like bulk transfer, a flag is raised for further analysis.


---

## Part 3: Next Steps

The immediate next step is to implement the proposed two-stage classifier and integrate it with the QoS pipeline demonstrated in Part 1.

**Concretely:**

1. **Capture and label training data** for the target application set (VoIP, video streaming, gaming, bulk transfer) using controlled traffic generation.

2. **Implement SNI extraction in the P4 parser** — extend the parser state machine to reach into the TLS Client Hello payload and extract the SNI field for flows on port 443. This provides the fast-path DPI label directly in the data plane.

3. **Extract statistical features in the P4 data plane** — use register arrays to accumulate per-flow packet size statistics and IAT estimates for the first N packets of each new flow (identified by 5-tuple hashing).

4. **Train a decision tree classifier** on labeled flow features and compile it to P4 match-action table entries using the IIsy/Planter toolchain.

5. **Wire the classifier output to the TM** — once the application class is determined, write the appropriate `ig_tm_md.qid` and `ig_tm_md.ingress_cos` values so the Traffic Manager enforces the right QoS policy for that class, exactly as demonstrated in the midsem TM configuration work.

6. **Evaluate end-to-end** — measure per-class latency and throughput under congestion to verify that classified real-time flows receive their guaranteed treatment.

---

## Acronyms

| Term | Expansion |
|---|---|
| TM | Traffic Manager |
| PPG | Priority Propagation Group |
| DPG | Default Priority Group |
| PFC | Priority Flow Control |
| ICOS / ICoS | Ingress Class of Service |
| QID | Queue ID |
| DSCP | Differentiated Services Code Point |
| EF | Expedited Forwarding (DSCP 46) |
| TNA | Tofino Native Architecture |
| BFRT | Barefoot Runtime |
| DPI | Deep Packet Inspection |
| IAT | Inter-Arrival Time |
| SNI | Server Name Indication |
| ECH | Encrypted Client Hello |
| CBR | Constant Bit Rate |
| VBR | Variable Bit Rate |
| DASH | Dynamic Adaptive Streaming over HTTP |
| MAT | Match-Action Table |
| LPM | Longest Prefix Match |
