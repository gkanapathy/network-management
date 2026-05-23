# Project: home network management

This directory holds configuration and notes for the user's home network.

## Layout

```
omada-controller/     # all Omada-controller setups
  oc200/              # ACTIVE hardware controller (OC200 v1 @ .252)
    README.md         # ops notes, beta-firmware caveat, backup/restore workflow
    backups/          # controller .cfg backup files

mikrotik-router/      # MikroTik rb5009 router — IaC-managed
  README.md           # workflow: how to apply, recover, and the gotchas hit so far
  config.rsc          # source of truth for the live router config
  IPV6-PLAN.md        # v6 design reference (Phases A + B-MB applied; Phase C is Sonic Stage 3)
  SONIC-PLAN.md       # staged Sonic WAN buildout (Stages 0-3 + wan-reconciler applied; 4 remains)
  gkanapathy-mbpmx.pub  # admin SSH pubkey, imported on apply
  snapshots/          # single pre-Sonic baseline .rsc for deep cold-bootstrap fallback

netgear-wifi/         # Orbi RBR50/RBS50 v1, being reflashed to OpenWrt — bench, not deployed
  README.md           # status, hardware inventory, post-flash facts
  FLASH.md            # nmrpflash runbook + debug.htm fallback
```

## What's already configured

- Omada controller is the hardware **OC200 v1** at
  `https://192.168.88.252/` (Omada Controller v6.2.10.17 via TP-Link beta
  firmware — see `omada-controller/oc200/README.md` for the should-move-to-stable note).
- Two EAP770 APs adopted, mesh formed (root wired on ether1 trunk,
  satellite over 6 GHz channel 197 / 160 MHz).
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
- **Sonic WAN buildout** — Sonic line is live on `sfp-sfpplus1`
  (Stages 0–3 applied 2026-05-21/22; Sonic delivers DHCP/IPoE with
  IA_NA + IA_PD /56). Per-SSID PBR for both v4 and v6 is source-based
  via `/routing rule`. Current routing — plumtree (v4 + v6) → Sonic
  primary; guest/iot/mgmt (v4 + v6) → MB primary; `main` table →
  Sonic primary too (router-originated traffic + any fall-through).
  v6 uses a single-GUA-per-VLAN approach (both pools bound on every
  VLAN so source-PBR can match, but only the primary pool is
  `advertise=yes`) — Trade-off: no dual-GUA safety net during a
  single-WAN outage until Stage 4 lands. WAN-derived literals (PD
  /56s, v4 next-hops, v6 upstream link-locals) are kept in sync with
  live DHCP state by a `wan-reconciler` script, triggered three ways
  (hybrid): /ip + /ipv6 dhcp-client `script=` hooks on lease change
  (event-driven), `/system scheduler` at 10m interval (polling
  belt-and-suspenders), and natural apply-day bootstrap via first
  dhcp-client bind. Staged rollout in
  [mikrotik-router/SONIC-PLAN.md](mikrotik-router/SONIC-PLAN.md);
  remaining: Stage 4 Netwatch + advertise-flip on WAN-down.
- **Diagnose Wi-Fi bufferbloat / latency under load on the EAPs.** Sustained
  ping spikes during saturating Wi-Fi traffic suggest queueing somewhere
  in the AP→client path. First isolate: ping a LAN target from a wired
  client (vs Wi-Fi) while running iperf3 to compare added latency, run
  Waveform's bufferbloat test (<https://www.waveform.com/tools/bufferbloat>)
  on each SSID, check whether the rb5009 has fq_codel/CAKE on egress and
  whether WMM is on on each Omada SSID. Pin down whether the bloat is on
  the WAN egress, the AP queue, or the client driver before reaching for
  per-SSID rate limits or QoS toggles in the controller.
- **OpenWrt'd Orbis: shelved as spares** (decided 2026-05-08). RBR50 +
  RBS50 v1 are flashed to OpenWrt 25.12.3 and factory-reset
  (`firstboot`) on the shelf. Not deployed — see
  [`netgear-wifi/README.md` § Decision: shelved](netgear-wifi/README.md#decision-shelved)
  for the reasoning (no real coverage gap; wireless-backhaul-only
  forces single-VLAN STA-mode bridging; EAP770 is Omada-Mesh-only;
  Wi-Fi 5–era hardware below the existing EAP770s' ceiling). Revisit
  only if a real gap appears or a 4-address-WDS test against the
  EAP770 ever changes the design space.

## Memory

Network topology, SSID quirks learned during setup, VLAN scheme, and dual-WAN
intent are stored as project memory at
`~/.claude/projects/-Users-gkanapathy-network-management/memory/` and auto-load
into context. Don't restate that content here — link to it instead.
