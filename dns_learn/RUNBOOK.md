# dns_learn — bring-up runbook

End-to-end steps for the DNS-learning experiment on the lab Tofino-1
(Edgecore Wedge100BF-32X, SDE 9.13.3): power-on, antserver tunnel, build, ports,
BfRt setup, the learner, and what to do on pc1 and pc2.

**Where the steps come from.** Sections 2–6 follow the procedures already documented
and working in the `P4_TSN` repo (`STARTUP.txt`, `Antserver_setup.txt`,
`end_sem_report.md` §1.3, and the Mohammed/Chaitanya and Shivam reports). Sections 7
onward are the new experiment and have **not** been run on the switch yet — §15 lists
exactly what is unproven.

**Reading the code blocks.** Every block is labelled with the machine it runs on:
`[BMC]`, `[antserver]`, `[switch T1]` / `[switch T2]` / `[switch T3]` (three separate SSH
sessions to the switch), `[pc1]`, `[pc2]`. Lines starting `bfshell>`, `bf-sde>` or
`bf-sde.pm>` are typed at that prompt, not in bash.

---

## 0. Files assumed to be in place

| Machine | Path | Files |
| --- | --- | --- |
| switch | `~/code/dns_learn/` | `dns_learn.p4` |
| switch | `~/dns_learn/cp/` | `setup_bfrt.py`, `dnsparse.py`, `dns_learner.py`, `hello_bfrt.py`, `compare_truth.py` |
| pc1 | `~/dns_learn/test/` | `gen_dns.py` |
| pc2 (Stage 3 only) | `~/dns_learn/cp/` | `dnsparse.py`, `dns_learner.py`, `hello_bfrt.py`, `compare_truth.py` |
| pc2 (Stage 3 only) | `~/sde_client/lib/python3/site-packages/tofino/` | copy of the switch's `$SDE_INSTALL/lib/python3*/site-packages/tofino/` |

`dnsparse.py` must sit in the same folder as the other `cp/` scripts. Nothing needs
`pip install` on the switch or pc1 — everything is Python standard library plus the
`bfrt_grpc` client that ships with the SDE.

> `setup_bfrt.py` was revised on 30 Sep 2026 (ports are no longer added by the script;
> collector defaults to dev_port 66). Re-copy it. An older copy still works but prints
> two harmless `port add ... ->` error lines.

---

## 1. Topology, stages, and the values you fill in

```
                         ┌───────────────── Tofino ─────────────────┐
 pc1 (client) ───────────┤ CLIENT_PORT                              │
                         │                      CPU port 33 ────────┼──► dev_port 66 ──► enp4s0f0
 pc2 ────────────────────┤ UPLINK_PORT (Stage 1)                    │    (on the switch's own Linux)
                         │ COLLECTOR_PORT (Stage 3)                 │
 campus L2 switch ───────┤ UPLINK_PORT (Stage 2/3, needs a new cable)│
                         └──────────────────────────────────────────┘
 switch MGMT ──► L2 switch ──► campus   (SSH only, reached through the antserver tunnel)
```

The experiment is done in three stages. Do them in order; each adds one unknown.

| Stage | Traffic | Other side of pc1 (`UPLINK_PORT`) | Collector (`COLLECTOR_PORT`) | Learner runs on |
| --- | --- | --- | --- | --- |
| **1** lab-contained | crafted DNS from `gen_dns.py` | pc2 | 66 → `enp4s0f0` | switch |
| **2** live DNS | real `dig` to the campus resolver | campus uplink | 66 → `enp4s0f0` | switch |
| **3** remote collector | either | campus uplink (or an unused port) | pc2's port | pc2 |

Stage 1 works with the cabling you already use for RealTIME and nothing leaves the lab.

Fill these in as you go (section that tells you each value in brackets):

| Value | Meaning | Yours |
| --- | --- | --- |
| `<P1>` | pc1's port string in ucli, e.g. `19/0` [§6] | |
| `<D1>` | pc1's dev_port (`D_P`). Earlier RealTIME tests used **139** — confirm [§6] | |
| `<P2>` | pc2's port string [§6] | |
| `<D2>` | pc2's dev_port. Earlier RealTIME tests used **138** — confirm [§6] | |
| `<SPEED>` | speed you normally add those ports at, e.g. `10G` [§6] | |
| `<pc1-nic>` | pc1's interface cabled to the Tofino [§10] | |
| `<pc2-nic>` | pc2's interface cabled to the Tofino [§10] | |
| `<resolver>` | campus DNS resolver seen by pc1 (Stage 2) [§12] | |

---

## 2. Power on the switch

From `STARTUP.txt` and `end_sem_report.md` Step 0.

1. Connect the laptop to the **BMC Console** port with the USB cable.
2. Windows Device Manager → Ports → note `USB Serial Port (COMx)`.
3. PuTTY → connection type **Serial**, line `COMx`, speed **9600** → Open.
4. If you land in an Ubuntu shell, the switch OS is already up — skip to §3.
   If you land on the BMC prompt:

```
[BMC]
wedge_power.sh on
sol.sh
```

Ubuntu boots; log in as `developer`. `Ctrl+X` leaves the SOL session back to the BMC.

---

## 3. Antserver tunnel

From `Antserver_setup.txt`. The switch has no inbound path from campus (its address is
filtered by the campus router), so the switch dials out and you come back down that
connection.

Start the tunnel **from the switch console** (the serial/SOL session from §2). Skip this
if `ssh -p 9999 developer@localhost` on antserver already works.

```
[switch, serial console]
ssh -R 0.0.0.0:9999:localhost:22 -fN f20212909@antserver.csis.bits-goa.ac.in
```

Then reach the switch through antserver:

```
[laptop]
ssh f20212909@antserver.csis.bits-goa.ac.in

[antserver]
ssh -p 9999 developer@localhost
```

Open **three** such sessions. They are called T1, T2 and T3 below:

| Session | Used for |
| --- | --- |
| **T1** | `run_switchd.sh` and its `bfshell>` prompt. Stays open the whole time. |
| **T2** | runtime setup, checks, `tcpdump` |
| **T3** | the learner |

Copying a file to the switch later (note the capital `-P`):

```
[antserver]
scp -P 9999 <file> developer@localhost:~/dns_learn/
```

---

## 4. SDE path variables — in every switch session

From `end_sem_report.md` Step 1. Environment variables are per shell, so do this in T1,
T2 **and** T3.

```
[switch T1, T2, T3]
echo $SDE
cd ~/scripts
source set_sde_path
echo $SDE $SDE_INSTALL
```

---

## 5. Compile, build, load, run

From `end_sem_report.md` Steps 2–5, with `dns_learn` in place of `RealTIME`.

```
[switch T1]
cd ~/code/dns_learn
$SDE_INSTALL/bin/bf-p4c dns_learn.p4
```

> **This is the first thing that has never been run.** If `bf-p4c` reports errors, stop
> and send the output — do not work around it. Likely spots: the `Counter<>` declaration,
> the `mirror.emit<mirror_h>(...)` call, the `if` blocks around `digest.pack` in the
> ingress deparser.

```
[switch T1]
cd ~/scripts
source p4build_command_param dns_learn
make
make install

cd ~/scripts
source load_program.sh

cd $SDE
./run_switchd.sh -p dns_learn
```

You are now at `bfshell>` in T1. Leave it there. Do not press `Ctrl+\` or `Ctrl+C` in T1
until the experiment is over — that stops the daemon and wipes all runtime config.

Compile and build are needed once, and again only when `dns_learn.p4` changes. After a
reboot you only need §4, `source load_program.sh` and `run_switchd.sh`.

---

## 6. Port setup (ucli)

From `end_sem_report.md` Step 6 and the Mohammed/Chaitanya report (CPU port).
All ports are disabled when the daemon starts.

Bring pc1's and pc2's interfaces up first (§10, first block) or the ports will not show
`OPR UP`.

```
[switch T1]
bfshell> ucli
bf-sde> bf_pltfm qsfp show
bf-sde> pm
bf-sde.pm> show
```

`bf_pltfm qsfp show` lists the physical ports with a cable. In `pm show`, `PORT` is the
port string you type in ucli and **`D_P` is the dev_port** that P4 and BfRt use.

Add the two host ports exactly as you do for RealTIME (same port strings, speed and FEC),
then the CPU port:

```
[switch T1]
bf-sde.pm> port-add <P1> <SPEED> NONE
bf-sde.pm> an-set <P1> 2
bf-sde.pm> port-enb <P1>

bf-sde.pm> port-add <P2> <SPEED> NONE
bf-sde.pm> an-set <P2> 2
bf-sde.pm> port-enb <P2>

bf-sde.pm> port-add 33/- 1G NONE
bf-sde.pm> an-set 33/- 2
bf-sde.pm> port-enb 33/-

bf-sde.pm> show
```

Check in the `show` output:

- pc1's and pc2's rows: `ADM ENB`, `OPR UP`. Write their `D_P` into the table in §1.
- a port-33 row with `D_P` **66**, `OPR UP`. This is the internal 1G link to the switch's
  own CPU; on the Linux side it is interface **`enp4s0f0`**. (dev_port 64 → `enp4s0f1`
  is CPU→pipeline only and is not used here.)

Leave ucli:

```
[switch T1]
bf-sde.pm> ..
bf-sde> exit
bfshell>
```

---

## 7. BfRt runtime setup

The P4 program only defines empty tables. This step writes their contents. It must be
redone every time switchd is restarted.

Edit the three dev_ports at the top of the script:

```
[switch T2]
nano ~/dns_learn/cp/setup_bfrt.py
```

```python
CLIENT_PORT    = <D1>      # pc1
UPLINK_PORT    = <D2>      # Stage 1: pc2
COLLECTOR_PORT = 66        # CPU Ethernet port -> enp4s0f0
MANAGE_PORTS   = False     # ports were added in ucli
```

Apply it:

```
[switch T2]
$SDE/run_bfshell.sh -b ~/dns_learn/cp/setup_bfrt.py
```

It ends with `--- dns_learn configured ---`. If `run_bfshell.sh -b` is not accepted on
this SDE, do the same thing from T1 instead:

```
[switch T1]
bfshell> bfrt_python
exec(open('/home/developer/dns_learn/cp/setup_bfrt.py').read())
```

What the script writes:

| Object | Entries | Effect |
| --- | --- | --- |
| `Ingress.forward` | `<D1>`→`<D2>`, `<D2>`→`<D1>` | the switch behaves like a cable between the two ports |
| `Ingress.dns_monitor` | both ports, mirror session 5 | DNS on these ports is digested / mirrored |
| `bfrt.mirror.cfg` | session 5 → dev_port 66 | where the full copy of each DNS response goes |
| `Ingress.app_class` | cleared | the learner fills this |

Confirm (T1, inside `bfrt_python`):

```
[switch T1]
bfrt.dns_learn.pipe.Ingress.forward.dump(table=True)
bfrt.dns_learn.pipe.Ingress.dns_monitor.dump(table=True)
bfrt.mirror.cfg.dump()
```

If a name is rejected, `bfrt.dns_learn.info()` lists the real ones.

---

## 8. Collector interface and gRPC check

```
[switch T2]
ip link show enp4s0f0
sudo ip link set enp4s0f0 up promisc on
```

`promisc on` is required: a mirrored copy starts with an 8-byte marker (`d5 d5` + a
timestamp) that the NIC reads as a destination MAC, so without promiscuous mode every
copy is silently discarded.

Now prove the gRPC path before running the learner:

```
[switch T2]
cd ~/dns_learn
python3 cp/hello_bfrt.py
```

Expected: five `PASS` lines (import, connect, schema, counter read, table write) and an
**install latency** figure. Keep that number — it is one of the experiment's results.

---

## 9. Start the learner (on the switch)

```
[switch T3]
cd ~/dns_learn
sudo env SDE_INSTALL=$SDE_INSTALL python3 cp/dns_learner.py \
     --iface enp4s0f0 --grpc localhost:50052 \
     --policy '\.googlevideo\.com$' '\.zoom\.us$' --out run1
```

(`sudo` is needed for the raw socket. `env SDE_INSTALL=...` is used instead of `sudo -E`
because sudo strips some variables even with `-E`.)

It prints a status line every 5 s:

```
mirrored=.. parsed=.. bindings=.. q_dig=.. r_dig=.. installed=.. deleted=.. err=..
```

Output files appear in `~/dns_learn/run1/`: `bindings.csv`, `events.csv`, `installs.csv`.

---

## 10. pc1 and pc2 — Stage 1 (lab-contained)

Bring the interfaces up (do this before §6 so the ports come up):

```
[pc1]
ip -br link
sudo ip link set <pc1-nic> up

[pc2]
ip -br link
sudo ip link set <pc2-nic> up
```

pc2 only has to be link-up in this stage. Optionally watch the forwarded frames arrive,
which proves the forwarding table:

```
[pc2]
sudo tcpdump -i <pc2-nic> -n udp
```

Send the test traffic from pc1 — 9 crafted frames covering the awkward cases:

```
[pc1]
sudo python3 ~/dns_learn/test/gen_dns.py --send <pc1-nic>
```

> Only run `gen_dns.py` while `UPLINK_PORT` is pc2. The frames carry made-up addresses
> (including the campus resolver's IP as a source) and must not be forwarded into the
> campus network.

---

## 11. Verify Stage 1

Check in this order; the first check that fails tells you where the fault is.

| # | Check | Where | Expected after one `gen_dns.py` run |
| --- | --- | --- | --- |
| 1 | queries seen | T1 `bfrt_python` | `dns_cnt` index 0 = **1** |
| 2 | responses mirrored | T1 | index 1 = **5** |
| 3 | responses skipped (NXDOMAIN / no answer) | T1 | index 2 = **2** |
| 4 | copies reach Linux | T2 | frames beginning `d5 d5` |
| 5 | learner counts | T3 status line | `mirrored=5 parsed=5 bindings=9 q_dig=1 r_dig=7 installed=1` |
| 6 | mappings saved | T2 | 9 rows |
| 7 | rule installed | T1 | one entry for `103.56.40.12/32` → qid 7, icos 7 |

```
[switch T1, bfrt_python]
bfrt.dns_learn.pipe.Ingress.dns_cnt.get(COUNTER_INDEX=0, from_hw=True)
bfrt.dns_learn.pipe.Ingress.dns_cnt.get(COUNTER_INDEX=1, from_hw=True)
bfrt.dns_learn.pipe.Ingress.dns_cnt.get(COUNTER_INDEX=2, from_hw=True)
bfrt.dns_learn.pipe.Ingress.app_class.dump(table=True)

[switch T2]      (run gen_dns.py again on pc1 while this waits)
sudo tcpdump -i enp4s0f0 -XX -c 3
cat ~/dns_learn/run1/bindings.csv
cat ~/dns_learn/run1/installs.csv
```

Notes:

- Counters accumulate: a second `gen_dns.py` run gives 2 / 10 / 4.
- `q_dig` / `r_dig` can lag by up to a second or so — digests are delivered in batches.
- The UDP/9999 frame in the test set must move **no** counter. If it does, the parser's
  port match is wrong.
- The installed rule is removed automatically when its DNS TTL expires (600 s for the
  test record); `installs.csv` then shows a `delete` row.

Stop the learner with `Ctrl+C` in T3; it prints a final summary.

---

## 12. Stage 2 — live DNS through the campus uplink

**Needs one new cable:** a Tofino front-panel port to the campus L2 switch, with media the
L2 switch accepts. Until that exists, stay on Stage 1.

1. Add the uplink port in ucli (§6 pattern) and note its dev_port `<DU>`.
2. In `setup_bfrt.py` set `UPLINK_PORT = <DU>`, leave the rest, re-run §7.
3. Restart the learner (§9) with `--out run2`.
4. On pc1, get an address through the switch and find the resolver:

```
[pc1]
sudo dhclient <pc1-nic>
ip -4 addr show <pc1-nic>
resolvectl status | grep -i "dns servers"
ping -c2 <resolver>
```

   If pc1 gets no address or cannot ping, stop — it is cabling, port speed, or a campus
   port restriction, and nothing below will work.

5. Record ground truth and make real lookups. `dig` never caches, so every lookup is on
   the wire:

```
[pc1]
sudo tcpdump -i <pc1-nic> -w truth.pcap 'udp port 53' &
for n in www.youtube.com zoom.us example.com wikipedia.org; do
    dig @<resolver> $n +tries=1 +timeout=2
done
sudo pkill tcpdump
```

6. Compare what the switch learned with what the client actually received. Copy
   `truth.pcap` to the switch (pc1 → antserver → `scp -P 9999` → switch), then:

```
[switch T2]
cd ~/dns_learn
python3 cp/compare_truth.py truth.pcap run2/bindings.csv
```

   The "learned by switch" percentage is the headline result of the experiment.

Do **not** run `gen_dns.py` in this stage.

---

## 13. Stage 3 — learner on pc2

There is one mirror destination at a time, so this replaces the on-switch collector
rather than running beside it.

**pc2 needs two interfaces:** `<pc2-nic>` direct-cabled to the Tofino (no IP address), and
a campus interface that can SSH to antserver.

1. **Runtime.** In `setup_bfrt.py` set `COLLECTOR_PORT = <D2>` (pc2's dev_port).
   `UPLINK_PORT` can no longer be pc2: use the campus uplink `<DU>`, or — for crafted
   traffic with no uplink — any dev_port from `pm show` that is not enabled (frames sent
   there are dropped). Re-run §7.

2. **gRPC path.** The switch forwards its gRPC port to antserver, and pc2 picks it up over
   SSH:

```
[switch T2]
ssh -R 50052:localhost:50052 -fN f20212909@antserver.csis.bits-goa.ac.in

[pc2]
ssh -L 50052:localhost:50052 -fN f20212909@antserver.csis.bits-goa.ac.in
```

   The switch-side forward is bound to antserver's loopback on purpose (no `0.0.0.0`):
   BfRt gRPC has no authentication, so exposing it on antserver's public interface would
   let anyone who can reach antserver reprogram the switch.

3. **pc2 setup and run.** The learner runs as root, so its two Python dependencies must be
   installed system-wide:

```
[pc2]
sudo pip3 install grpcio protobuf
sudo ip link set <pc2-nic> up promisc on

cd ~/dns_learn
python3 cp/hello_bfrt.py --grpc localhost:50052 --sde-install ~/sde_client

sudo env SDE_INSTALL=$HOME/sde_client python3 cp/dns_learner.py \
     --iface <pc2-nic> --grpc localhost:50052 \
     --policy '\.googlevideo\.com$' '\.zoom\.us$' --out run3
```

4. Generate traffic from pc1 as in §10 (crafted) or §12 (live) and verify as in §11,
   reading `tcpdump` and the CSV files on pc2 instead of the switch.

If the gRPC path will not come up, add `--no-grpc` to the learner: you still get
`bindings.csv` (the mappings), but no digests and no rules installed.

---

## 14. Shutting down

1. `Ctrl+C` the learner (T3 or pc2).
2. In T1 leave bfshell with `Ctrl+\`.
3. Power down as written in `STARTUP.txt`, reproduced here in its original order:

```
GO BACK TO BMC          (Ctrl+X from the SOL session)
wedge_power.sh off
shutdown now
```

**Never use `poweroff`** — it shuts off the BMC, which runs the fans.

Nothing persists across a restart of switchd: ports (§6) and runtime config (§7) must be
redone each time.

---

## 15. What is proven and what is not

**Proven on this switch** (documented in the `P4_TSN` repo): power-on, the antserver
tunnel, `set_sde_path`, the `bf-p4c` → `p4build_command_param` → `make install` →
`load_program.sh` → `run_switchd.sh` flow, ucli port bring-up, CPU port 33 / dev_port 66 /
`enp4s0f0`, and a Python control plane that sniffs `enp4s0f0` and installs entries over
gRPC (the self-learning-switch work).

**Tested offline, not on the switch:**

- `dnsparse.py` agrees with Wireshark on 267/267 real DNS responses, including CNAME chains.
- `gen_dns.py` frames are accepted by Wireshark with valid IP and UDP checksums.
- `dns_learner.py` replaying those frames yields exactly the 9 expected bindings.

**Not yet run anywhere — expect to fix things here:**

| Item | Risk |
| --- | --- |
| `dns_learn.p4` compiling under SDE 9.13.3 | most likely first failure |
| table / action / digest names used by `setup_bfrt.py`, `hello_bfrt.py`, `dns_learner.py` | a wrong name fails loudly; `bfrt.dns_learn.info()` shows the right one |
| **mirroring** to dev_port 66 | earlier work *forwarded* to 66; mirroring to it is new |
| `max_pkt_len=16384` on the mirror session | lower to 1600 if the SDE rejects it |
| digest decoding in the learner | if `q_dig`/`r_dig` stay 0 while `bindings` grows, only the digest path is broken |
| Stage 2: pc1 getting DHCP through the switch | campus wired-port policy is unknown |
| Stage 3: the two-hop gRPC forward, and `protobuf` version on pc2 | see §16 |

---

## 16. Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `ssh -p 9999 developer@localhost` refused | tunnel not running | start it from the serial console (§3) |
| `scp` tries port 22 | lowercase `-p` | `scp -P 9999` |
| `$SDE_INSTALL/bin/bf-p4c: No such file` | path variables not set in this session | §4 |
| host port stays `OPR DWN` | host NIC down, wrong speed/FEC, wrong lane | `ip link set up` on the host; re-add the port with the settings you use for RealTIME |
| pc2 sees no frames in Stage 1 | `forward` entries have the wrong dev_ports | compare `forward.dump` with `pm show` |
| `dns_cnt[0]` stays 0 | DNS not entering a watched port | `dns_monitor.dump`; check `CLIENT_PORT` |
| `dns_cnt[1]` rises, `tcpdump -i enp4s0f0` silent | port 33 not enabled, or no promisc | §6 CPU port, §8 `promisc on` |
| `dns_cnt[1]` rises, tcpdump shows frames, learner `mirrored=0` | learner on the wrong interface | `--iface enp4s0f0` |
| `mirrored` rises, `parsed=0` | frame layout differs from expected | send 3 frames of `tcpdump -XX` output |
| `hello_bfrt.py` check 1 fails | `SDE_INSTALL` not set | §4, or `--sde-install $SDE_INSTALL` |
| `hello_bfrt.py` check 2 fails | switchd not running | T1 |
| `hello_bfrt.py` check 3 fails | switchd is running a different program | `run_switchd.sh -p dns_learn` |
| checks 4 / 5 fail | a name differs in this SDE | `bfrt.dns_learn.info()` |
| pc2: `Descriptors cannot be created directly` | new `protobuf` vs. SDE-generated code | `sudo pip3 install "protobuf<=3.20.3"` |
| everything gone after restarting switchd | runtime state is not persistent | redo §6 and §7 |

---

## Appendix — the other CPU path (not used here)

The Mohammed/Chaitanya report also documents the PCIe CPU port. It needs the `bf_kpkt`
kernel module, which cannot be loaded alongside `bf_kdrv`:

```
sudo rmmod bf_kdrv
sudo $SDE_INSTALL/bin/bf_kpkt_mod_load $SDE_INSTALL
```

after which the interface appears as `ens1`. It is not used in this runbook because the
Ethernet CPU port (dev_port 66 / `enp4s0f0`) is already proven on this switch and needs no
driver change. To return to the normal driver: `sudo rmmod bf_kpkt`, then
`cd ~/scripts; source load_module.sh`.
