# Project: home network management

This directory holds configuration and notes for the user's home network.

## Layout

```
omada-controller/     # all Omada-controller setups
  oc200/              # ACTIVE hardware controller (OC200 v1 @ .252)
    README.md         # ops notes, beta-firmware caveat, backup/restore workflow
    backups/          # controller .cfg backup files

mikrotik-router/      # MikroTik rb5009 router — IaC-managed
  README.md           # workflow: how to apply, recover, schema-level gotchas
  config.rsc          # source of truth for the live router config
  apply.sh            # apply runner: parse, /export, wipe-and-replay, verify, snapshot-last-applied
  IPV6-PLAN.md        # v6 design reference (Phases A + B-MB applied; Phase C is Sonic Stage 3)
  SONIC-PLAN.md       # staged Sonic WAN buildout (Stages 0-3 + wan-reconciler applied; 4 remains)
  LESSONS.md          # architectural lessons learned during the buildout
  gkanapathy-mbpmx.pub  # admin SSH pubkey, imported on apply
  snapshots/          # apply.sh working artifacts (gitignored): last-applied.rsc + last-export.rsc

netgear-wifi/         # Orbi RBR50/RBS50 v1, being reflashed to OpenWrt — bench, not deployed
  README.md           # status, hardware inventory, post-flash facts
  FLASH.md            # nmrpflash runbook + debug.htm fallback
```

## What's already configured

- Omada controller is the hardware **OC200 v1** at
  `https://192.168.88.252/` (firmware 1.40.18 stable — see
  `omada-controller/oc200/README.md`).
- Two EAP770 (US) v2.0 APs adopted, mesh formed (root `Root` wired on
  ether1 trunk @ .251; satellite `Satellite` @ .247 over **6 GHz
  ch213 / 160 MHz** wireless backhaul, ~−79 dBm, single hop).
- **6 GHz is backhaul-only** (decided 2026-06-08). Client SSIDs are
  2.4 + 5 GHz only — the `plumtree` SSID's 6 GHz band was disabled in
  the controller. Rationale: each EAP770 has one 6 GHz radio, so the
  wireless backhaul and any 6 GHz clients are forced onto the *same*
  channel (ch213/160); clients then contend with the backhaul +
  hidden-node collisions, which caused a 6E Mac in a LOS room to drop
  the link in bursts (deauth reason 2, BadRSSI poor-link sessions in
  airportd logs) while a 5 GHz-only Mac in the same spot was fine.
  Dropping 6 GHz client access gives the backhaul the channel to
  itself and moves clients to the solid 5 GHz. Disabling 6 GHz also
  relaxed `plumtree` from WPA3+PMF-required to WPA2/WPA3-SAE
  transition (6 GHz mandates WPA3+PMF; 2.4/5 don't). To reclaim 6 GHz
  for clients later, the backhaul must leave 6 GHz first (wire the
  satellite, or move the satellite for a stronger link).
- Three SSIDs (`plumtree`, `plumtree-guest`, `plumtree-iot`) on VLANs
  10/20/30; clients get IPs from the rb5009 DHCP servers per VLAN.
- rb5009 in its target shape: `vlan-filtering=yes`, `vlan88/10/20/30` L3
  sub-interfaces with DHCP servers, inter-VLAN firewall (guest isolated,
  iot one-way to plumtree, iot blocked from mgmt+guest), ether2 reassigned
  to WAN.

The router is managed as IaC; see
[mikrotik-router/README.md](mikrotik-router/README.md) for the
edit-`config.rsc`-then-wipe-and-replay workflow. Don't patch the live
router by hand — drift will get wiped on the next apply.

## What's next

- Tighten `/ip ssh password-authentication` from `yes` back to
  `yes-if-no-key`. **Deferred** — apply flow is trusted (multiple
  clean applies + the key-import refactor on 2026-05-09), but keep the
  password fallback as a belt-and-suspenders safety net while there's
  ongoing iterative work on the router. Revisit when router work
  settles.
- **Optional: encrypted DNS (DoH) if path privacy matters.** Plain DNS
  on UDP/53 is visible to every hop, not just the first. RouterOS 7
  supports DoH via `/ip dns set use-doh-server=https://...`. Skip this
  unless you're trying to defeat on-path observers — Monkeybrains is
  fine as the plain upstream (small SF ISP, not in the data-mining
  business), and switching to 1.1.1.1/8.8.8.8 is a sideways move at
  best (Google is worse than Monkeybrains, Cloudflare already terminates
  most of your TLS).
- **IPv6 buildout.** Phases A and B-MB done 2026-05-09. Phase A: ULA
  `fd7f:aee1:6ce0::/48` per VLAN, RA + RDNSS, inter-VLAN firewall
  parity, AAAA for `router.lan`. Phase B-MB: Monkeybrains DHCPv6-PD
  delegated `2607:f598:d488:6100::/56`, sub-allocated /64s per VLAN,
  ::/0 default route, full v6 internet via the MB GUA. Phase C
  (Sonic-day dual-WAN routing + dual-GUA failover) is folded into the
  Sonic WAN buildout below — design model in
  [mikrotik-router/IPV6-PLAN.md](mikrotik-router/IPV6-PLAN.md), staged
  apply in [mikrotik-router/SONIC-PLAN.md](mikrotik-router/SONIC-PLAN.md).
  Link-local recovery in `mikrotik-router/README.md` stays valid.
- **Sonic WAN buildout** — Sonic on `sfp-sfpplus1`, MB on `ether2`.
  Per-VLAN PBR (v4 + v6 via `/routing rule`): plumtree + mgmt →
  Sonic; guest + iot → MB. `main` table is Sonic-primary too. v6
  uses dual-GUA per VLAN — both pools bound (`advertise=no`), RA
  emission via explicit static `/ipv6 nd prefix` entries with
  preferred-lifetime bias (`30m` for primary, `0s` for fallback);
  clients SLAAC both, RFC 6724 Rule 3 picks the preferred. Stage 4
  Netwatch failover: per-WAN probes of `2606:4700:4700::1111` from a
  router host GUA in that WAN's /56 (foreign-source v6 — when the
  WAN dies, the reply can't route back via the dead WAN so the
  probe times out). `*-down` scripts flip preferred-lifetime;
  clients re-pick the surviving GUA on next RA, no DAD wait.
  WAN-derived literals (PD /56s, v4 next-hops, upstream LLs, ND
  prefix /64s, netwatch src) are kept in sync by `wan-reconciler`,
  hybrid-triggered (event-driven via dhcp-client `script=` hooks +
  10m scheduler tick). Detailed staging in
  [mikrotik-router/SONIC-PLAN.md](mikrotik-router/SONIC-PLAN.md);
  architectural lessons (mangle PBR trap, dynamic-prefix `set`
  refusal, BCP38 asymmetry, Bug A v4-probe trap) in
  [mikrotik-router/LESSONS.md](mikrotik-router/LESSONS.md).
- **Diagnose Wi-Fi bufferbloat / latency under load on the EAPs.** Sustained
  ping spikes during saturating Wi-Fi traffic suggest queueing somewhere
  in the AP→client path. First isolate: ping a LAN target from a wired
  client (vs Wi-Fi) while running iperf3 to compare added latency, run
  Waveform's bufferbloat test (<https://www.waveform.com/tools/bufferbloat>)
  on each SSID, check whether the rb5009 has fq_codel/CAKE on egress and
  whether WMM is on on each Omada SSID. Pin down whether the bloat is on
  the WAN egress, the AP queue, or the client driver before reaching for
  per-SSID rate limits or QoS toggles in the controller.
- **Orbis on Voxel, shelved for rehoming** (reflashed 2026-05-31). RBR50 +
  RBS50 v1 ran OpenWrt as spares, then were reflashed to Voxel custom
  firmware (`9.2.5.2.44SF-HW`, blank state, paired kit) to prep for
  eventual giveaway — Voxel = stock Orbi UX + modern TLS, the best thing
  to hand a recipient. No concrete recipient yet; set aside until one
  appears. Reflash to OpenWrt if a keep-as-spare need reappears.
  Deploying them *here* was dropped 2026-05-08 — see
  [`netgear-wifi/README.md` § Decision: shelved](netgear-wifi/README.md#decision-shelved)
  for the reasoning (no real coverage gap; wireless-backhaul-only
  forces single-VLAN STA-mode bridging; EAP770 is Omada-Mesh-only;
  Wi-Fi 5–era hardware below the existing EAP770s' ceiling).

## Memory

Network topology, SSID quirks learned during setup, VLAN scheme, and dual-WAN
intent are stored as project memory at
`~/.claude/projects/-Users-gkanapathy-network-management/memory/` and auto-load
into context. Don't restate that content here — link to it instead.
