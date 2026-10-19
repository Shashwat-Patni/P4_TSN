# dns_learn — progress log

Record of what has been demonstrated on the lab Tofino, with the evidence for each item.
Numbers are copied from the switch and host output as it was observed; nothing here is
estimated. Procedures referenced as §N are in [RUNBOOK.md](RUNBOOK.md).

---

## 30 Sep 2026 — first on-hardware run: the learning loop works end to end

### Summary

A DNS lookup made by a real client through the switch was recognised by the P4 program,
mirrored to the switch's CPU, parsed by the control plane, matched against a policy, and
turned into a live `app_class` table entry — all on the Tofino, with a live campus
resolver. This is the first time the URL→IP reverse-mapping loop has run on hardware
rather than offline.

| Stage | Status | Evidence |
| --- | --- | --- |
| P4 program compiles and loads | ✅ | `bf-p4c` succeeded on the second attempt; switchd reported `found 1 p4 programs ... dns_learn` |
| Runtime configuration (`setup_bfrt.py`) | ✅ | `--- dns_learn configured --- client 4 <-> uplink 6; DNS responses mirrored to 66 via session 5` |
| Forwarding through the switch | ✅ | pc1's only interface is cabled to dev_port 4; `FRAMES RX` on `D_P 4` rising; pc1 reached the campus resolver |
| Live DNS lookups through the switch | ✅ | `dig @10.1.1.61 ... +nocookie` → `status: NOERROR` |
| Data plane recognises DNS | ✅ | `dns_cnt`: 327 queries, 241 responses mirrored, 115 responses skipped, 0 other |
| Digest path (switch → learner over gRPC) | ✅ | learner: `q_dig=237 r_dig=268` |
| Mirror path (switch → CPU port → learner) | ✅ | learner: `mirrored=6 parsed=6 bindings=27`, `err=0+0` once CPU port 33 was enabled |
| Policy match → rule installed | ✅ | `app_class` entry `170.114.52.2/32 → qid 7, icos 7` after `dig www.zoom.us` |
| Learn everything, install only policy matches | ✅ | `bindings.csv`: `connectivity-check.ubuntu.com` logged with `policy_match=0` and no rule; `www.zoom.us` with `policy_match=1` and one rule |
| Rule removed when its lifetime ran out | ✅ | `www.zoom.us` TTL 44 s, so the 60 s minimum hold applied; learner `installed=1 deleted=1`; rule lived 60.28 s |
| Rule-install latency measured | ✅ (1 sample) | table write **3.279 ms**, delete **2.122 ms** |

### Configuration used

| Item | Value |
| --- | --- |
| Switch | Edgecore Wedge100BF-32X (Tofino-1), SDE 9.13.3 |
| Client port | dev_port **4** — pc1 |
| Uplink port | dev_port **6** — router `10.8.1.1` → campus network |
| Collector | CPU port `33/-` at 1G → dev_port **66** → Linux `enp4s0f0` (promiscuous) |
| Mirror session | 5 |
| pc1 | interface `enp1s0`, address `10.8.1.159`, its only network interface |
| Resolver | campus resolver `10.1.1.61` |
| Learner | on the switch: `--iface enp4s0f0 --grpc localhost:50052 --policy '\.googlevideo\.com$' '\.zoom\.us$'` |

### Evidence in detail

**Data-plane counters** — `bfrt.dns_learn.pipe.Ingress.dns_cnt.dump(table=True, from_hw=True)`,
read at 18:05:20:

| Index | Meaning | Packets |
| --- | --- | --- |
| 0 | queries seen | 327 |
| 1 | responses mirrored (NOERROR, ≥1 answer) | 241 |
| 2 | responses skipped (error or no answers) | 115 |
| 3 | port-53 packet that is neither | 0 |

These counts include all of pc1's DNS traffic (operating system and browser), not only the
test lookups, because pc1's only path to the network is through the switch.

**Monitored ports** — `dns_monitor.dump(table=True)`: `ingress_port 0x04 → sid 5` and
`ingress_port 0x06 → sid 5`.

**Learner status** after CPU port 33 was enabled:

```
mirrored=6 parsed=6 bindings=27 q_dig=249 r_dig=280 installed=1 deleted=1 err=0+0
```

Every mirrored response that reached the learner parsed (`err=0`). Six responses yielded 27
hostname→IP bindings, because answers typically carry several addresses or a CNAME chain.
`mirrored` counts only what arrived after port 33 came up; the 241 earlier mirrored
responses were dropped at the ASIC (problem 5 below). The digests again show more
responses than queries (280 vs 249).

**Rule installed** — `app_class.dump(table=True)` after
`dig @10.1.1.61 www.zoom.us +nocookie +tries=1 +timeout=2` on pc1:

```
hdr.ipv4.src_addr             qid    icos
('0xAA723402', '0x00000020')  0x7    0x7
```

`0xAA723402` = `170.114.52.2`, prefix `0x20` = /32. `www.zoom.us` matched the
`\.zoom\.us$` policy, so its answer address was installed with the priority class.

**Learned bindings** — `run1/bindings.csv`, as pasted from the switch. The paste started
part-way through the file, so earlier rows were not seen; the first row below is the first
complete one.

```
t_wall,hw_ts_ns,client_ip,qname,ip,ttl,cname_chain,policy_match
1790792001.930559,5434826405415,10.8.1.159,connectivity-check.ubuntu.com,91.189.91.60,19,connectivity-check.ubuntu.com,0
1790792001.930559,5434826405415,10.8.1.159,connectivity-check.ubuntu.com,91.189.91.61,19,connectivity-check.ubuntu.com,0
1790792001.930559,5434826405415,10.8.1.159,connectivity-check.ubuntu.com,91.189.91.57,19,connectivity-check.ubuntu.com,0
1790792001.930559,5434826405415,10.8.1.159,connectivity-check.ubuntu.com,185.125.190.99,19,connectivity-check.ubuntu.com,0
1790792001.930559,5434826405415,10.8.1.159,connectivity-check.ubuntu.com,91.189.91.62,19,connectivity-check.ubuntu.com,0
1790792109.313439,5542204787473,10.8.1.159,www.zoom.us,170.114.52.2,44,www.zoom.us,1
1790792301.929309,5734812145882,10.8.1.159,connectivity-check.ubuntu.com,91.189.91.64,19,connectivity-check.ubuntu.com,0
1790792301.929309,5734812145882,10.8.1.159,connectivity-check.ubuntu.com,185.125.190.100,19,connectivity-check.ubuntu.com,0
1790792301.929309,5734812145882,10.8.1.159,connectivity-check.ubuntu.com,185.125.190.101,19,connectivity-check.ubuntu.com,0
1790792301.929309,5734812145882,10.8.1.159,connectivity-check.ubuntu.com,91.189.91.57,19,connectivity-check.ubuntu.com,0
1790792301.929309,5734812145882,10.8.1.159,connectivity-check.ubuntu.com,91.189.91.98,19,connectivity-check.ubuntu.com,0
1790792301.929309,5734812145882,10.8.1.159,connectivity-check.ubuntu.com,91.189.91.62,19,connectivity-check.ubuntu.com,0
1790792301.929309,5734812145882,10.8.1.159,connectivity-check.ubuntu.com,91.189.91.96,19,connectivity-check.ubuntu.com,0
1790792301.929309,5734812145882,10.8.1.159,connectivity-check.ubuntu.com,91.189.91.58,19,connectivity-check.ubuntu.com,0
1790792301.929309,5734812145882,10.8.1.159,connectivity-check.ubuntu.com,91.189.91.97,19,connectivity-check.ubuntu.com,0
1790792301.929309,5734812145882,10.8.1.159,connectivity-check.ubuntu.com,91.189.91.61,19,connectivity-check.ubuntu.com,0
1790792301.929309,5734812145882,10.8.1.159,connectivity-check.ubuntu.com,185.125.190.99,19,connectivity-check.ubuntu.com,0
1790792301.929309,5734812145882,10.8.1.159,connectivity-check.ubuntu.com,91.189.91.60,19,connectivity-check.ubuntu.com,0
```

(The row just before the first complete one, cut off in the paste, was another
`connectivity-check.ubuntu.com` → `185.125.190.101` row from the same response.)

What these rows show:

| Response | Name | Addresses (rows) | TTL | Policy | Result |
| --- | --- | --- | --- | --- | --- |
| 1790792001.93 | `connectivity-check.ubuntu.com` | ≥ 6 (partly cut off) | 19 s | no match | logged, no rule |
| 1790792109.31 | `www.zoom.us` | 1 — `170.114.52.2` | 44 s | `\.zoom\.us$` | logged, rule installed (same `t_wall` as the `add` row in `installs.csv`) |
| 1790792301.93 | `connectivity-check.ubuntu.com` | 12 | 19 s | no match | logged, no rule |

- **One response gives many bindings.** A single `connectivity-check.ubuntu.com` answer
  carried 12 A records, and each became its own row. This is why `bindings=27` came from
  only `parsed=6` responses.
- **Background traffic is learned too.** `connectivity-check.ubuntu.com` is pc1's Ubuntu
  network-connectivity check; the two lookups are 299.999 s apart, which fits a 5-minute
  check timer. The switch learns the operating system's lookups as well as the test's.
- **The policy filter works.** Every name is learned, but only the policy match got a
  table entry.
- **Client address.** Every row shown has `client_ip` = `10.8.1.159` (pc1). This is only
  the part of the file that was pasted, so it does not yet settle the
  responses-outnumber-queries question below.

**Hardware vs wall-clock timestamps** (observation, two intervals only). Between the three
responses, the ASIC's `hw_ts_ns` and the learner's `t_wall` advance by:

| Interval | `hw_ts_ns` | `t_wall` | Difference | Ratio |
| --- | --- | --- | --- | --- |
| response 1 → 2 | 107.378382 s | 107.382880 s | 4.50 ms | 42 ppm |
| response 2 → 3 | 192.607358 s | 192.615870 s | 8.51 ms | 44 ppm |

The gap grows with the interval at a near-constant ~43 ppm, which points to a clock-rate
difference between the Tofino timestamp counter and the switch CPU's system clock, not to
random delay. Two intervals are not enough to confirm it. It matters for the end-to-end
latency measurement: ASIC timestamps and wall-clock times cannot be subtracted directly
without first fitting the offset and rate between the two clocks.

**Install and expiry** — `run1/installs.csv`:

```
t_wall,action,ip,qname,latency_ms,error
1790792109.313439,add,170.114.52.2,www.zoom.us,3.279,
1790792169.595712,delete,170.114.52.2,www.zoom.us,2.122,
```

- Writing the rule over BfRt gRPC took **3.279 ms**; removing it took **2.122 ms**.
- The rule lived **60.28 s**. `bindings.csv` shows the answer's TTL was **44 s**; the
  learner keeps a rule for `max(TTL, 60 s minimum hold)`, so 60 s applied, and the extra
  0.28 s is the janitor's 1 s check interval. A TTL above 60 s would have set the lifetime
  instead.
- `t_wall` in `installs.csv` is the time the learner *received* the mirrored response
  (the same value as the binding row), not the time the write finished.

What the 3.3 ms does and does not cover: it is the time of the `entry_add` call alone. It
does not include the mirrored copy's trip to the CPU or the parse, so it is a lower bound
on the time from DNS answer to rule-in-place, not the end-to-end figure. It is one
sample.

For scale, the earlier capture analysis found a client's first packet to a new server
follows the DNS answer by a median of 0.8 ms, but bulk data only starts after the TLS
handshake, about 50 ms later. A few-millisecond install therefore misses the first packets
of a flow but is in place before its bulk data.

### Problems found and fixed during bring-up

| # | Symptom | Cause | Fix |
| --- | --- | --- | --- |
| 1 | `bf-p4c`: `Non-zero constant value 16w0xd5d5 in digest field list is not supported on tofino` | the mirror marker constant was written directly in the `mirror.emit` field list | carry it in a metadata field set by `watch_port`; also made `dns_cnt` count from one call site (one-table rule for indirect counters) |
| 2 | `load_module.sh`: `insmod ... bf_kdrv.ko: File exists` | driver already loaded | none — harmless |
| 3 | `dns_cnt` read 0 with `.get(COUNTER_INDEX=0, from_hw=True)` | on SDE 9.13.3 `.get()` returns an entry object and does not show the hardware count | read with `dns_cnt.dump(table=True, from_hw=True)` (runbook §13 updated) |
| 4 | `dig` returned `status: FORMERR`, 0 answers | the campus resolver rejects the EDNS cookie `dig` sends by default | `dig ... +nocookie` (runbook §14 updated) |
| 5 | learner `mirrored=0` although `dns_cnt[1]` was rising | CPU port 33 (dev_port 66) had not been added in ucli, so mirrored copies were dropped | `port-add 33/- 1G NONE`, `an-set 33/- 2`, `port-enb 33/-` (runbook §7) |

### Not yet done or not yet measured

| Item | Why it matters | How |
| --- | --- | --- |
| **Install latency — more samples and end-to-end** | one 3.3 ms sample is the write call only | `hello_bfrt.py` check 5 gives median/max over 20 writes; end-to-end needs the ASIC timestamp mapped onto wall-clock time (the two clocks appear to drift ~43 ppm apart, see above) and a timestamp when the write returns |
| **Mapping completeness** | the experiment's headline number: share of the client's bindings the switch learned | runbook §14: `truth.pcap` on pc1, then `compare_truth.py` |
| **The rule actually changing the queue** | installing a rule is not the same as traffic from that server landing in queue 7 | fetch from `170.114.52.2` on pc1 while reading the queue counters |
| **Crafted-frame test** (runbook §11–§13) | exact expected numbers (1 / 5 / 2, 9 bindings) validate the filter logic case by case | not run — went straight to live traffic; needs the uplink disabled while sending |
| **Responses outnumber queries** | 241 + 115 = 356 responses vs 327 queries in the counters, and 280 vs 249 in the digests: roughly 30 responses crossed the switch without a counted query. They may be replies for *other* hosts flooded from the campus side, which would mean other users' lookups are being recorded | `cut -d, -f3 <out>/bindings.csv \| sort \| uniq -c` — addresses other than `10.8.1.159` confirm it. The rows pasted so far are all `10.8.1.159`, but that was only part of the file |
| Strict-priority scheduling of the real-time queue | pre-existing open item: `min_priority` / `max_priority` on `pg_queue=23` are LOW, need HIGH | TM configuration, before any queue-effect test |
