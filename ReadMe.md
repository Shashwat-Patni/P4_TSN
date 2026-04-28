# QoS-based Priority Queuing on the Tofino ASIC

**SOP 2025-26 — Shashwat Patni (f20230390@goa.bits-pilani.ac.in)**

---

## What this project is about

This project implements and explores automatic QoS-based priority queuing on an Intel Tofino 1 programmable switch ASIC. The work splits into two phases:

**Phase 1 (Midsem):** Configure the Tofino Traffic Manager (TM) to enforce per-class QoS — separate queues, buffer guarantees, and scheduling priorities — and write a P4 program (`RealTIME.p4`) that classifies DSCP EF (Expedited Forwarding) traffic as real-time and maps it to the high-priority queue. The key finding is that different traffic priority classes can be treated independently using the TM, configured entirely via the BFRT Python API at runtime without reloading the P4 program.

**Phase 2 (Post-midsem):** Survey network traffic classification techniques to understand how flows can be identified automatically (so QoS can be applied without relying on hosts self-marking). The focus is on statistical/behavioral methods and Deep Packet Inspection. The agreed next step is to narrow scope to identifying a small set of target applications from live flows using a mixture of these techniques.

---

## Main report

**[end_sem_report.md](end_sem_report.md)** — the full end-semester report.

It contains:

- Complete setup walkthrough (physical access, SDE path, compile, build, load, run, port configuration, BFRT control plane)
- Traffic Manager architecture and configuration (PPG, queue buffer, shaping, scheduling)
- Annotated walkthrough of `RealTIME.p4`
- Observations from the experiment
- Survey of classification techniques (port-based, DPI, statistical, ML, TLS fingerprinting, in-network ML)
- Statistical and DPI techniques in depth
- Proposed next steps: two-stage classification pipeline combining DPI and statistical features

---

## P4 program

**[RealTIME.p4](RealTIME.p4)** — the P4_16/TNA program used in the experiment. It forwards IPv4 packets via an LPM table and classifies DSCP EF (value 46) traffic to `qid=7` / `ingress_cos=7` for real-time priority treatment by the TM.
