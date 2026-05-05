# Project: home network management

This directory holds configuration and notes for the user's home network.

## Layout

```
oc200/                # Active hardware Omada Controller (OC200 v1 @ .252)
  README.md           # ops notes, beta-firmware caveat, backup/restore workflow
  backups/            # controller .cfg backup files

omada-controller/     # RETIRED Omada controller setups
  macos-software/     # bootstrap software controller (Colima + Docker), retired 2026-05-03
    README.md         # retirement note + recovery procedure
    PLAN.md           # original design doc (historical)
    docker-compose.yaml
    omada/            # gitignored runtime state; kept as recovery fallback

mikrotik-router/      # MikroTik rb5009 router — IaC-managed
  README.md           # workflow: how to apply, recover, and the gotchas hit so far
  config.rsc          # source of truth for the live router config
  gkanapathy-mbpmx.pub  # admin SSH pubkey, imported on apply
  snapshots/          # pre-apply backups + post-apply /export captures
  PLAN.md             # historical buildout plan; live intent is in config.rsc
```

## What's already configured

- Omada controller is the hardware **OC200 v1** at
  `https://192.168.88.252/` (Omada Controller v6.2.10.17 via TP-Link beta
  firmware — see `oc200/README.md` for the should-move-to-stable note).
  Migrated from the software controller (now in
  `omada-controller/macos-software/`) on 2026-05-03; that dir is dormant
  recovery only and slated for removal by the scheduled audit on
  2026-05-17.
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
  `yes-if-no-key` once we trust the apply flow.
- **Tighten DNS upstream so the ISP can't see LAN lookups.** Currently
  `use-peer-dns=yes` (default) on the WAN DHCP client, and the router
  acts as resolver for the LAN with `allow-remote-requests=yes` — so
  every LAN device's DNS query egresses to monkeybrains' DNS. Set
  `/ip dhcp-client set [find interface=ether2] use-peer-dns=no` and
  `/ip dns set servers=1.1.1.1,8.8.8.8` (or trusted equivalents).
- **Add IPv6 to all VLANs.** ULA + (eventually) PD from the WAN. IPv6
  link-local on the mgmt VLAN is automatic and stays up regardless of L3
  config — so the IPv6-link-local recovery path documented in
  `mikrotik-router/README.md` keeps working even after IPv6 changes (as long
  as the bridge itself is alive).
- **Sonic WAN buildout** (when the line is up): mirror the ether2 setup on
  `sfp-sfpplus1`, then implement per-SSID WAN selection per PLAN.md —
  plumtree → sonic primary, guest/iot → monkeybrains primary, failover
  either way. Separate pass via mangle marks + routing tables.

## Memory

Network topology, SSID quirks learned during setup, VLAN scheme, and dual-WAN
intent are stored as project memory at
`~/.claude/projects/-Users-gkanapathy-network-management/memory/` and auto-load
into context. Don't restate that content here — link to it instead.
