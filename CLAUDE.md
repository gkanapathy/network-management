# Project: home network management

This directory holds configuration and notes for the user's home network.

## Layout

```
omada-controller/     # TP-Link Omada Controller, running on Colima + Docker
  README.md           # ops guide for the controller (start/stop, upgrades, troubleshooting)
  PLAN.md             # original design doc for the controller setup
  docker-compose.yaml
  omada/{data,logs,work,backup}/

mikrotik-router/      # MikroTik rb5009 router — IaC-managed
  README.md           # workflow: how to apply, recover, and the gotchas hit so far
  config.rsc          # source of truth for the live router config
  gkanapathy-mbpmx.pub  # admin SSH pubkey, imported on apply
  snapshots/          # pre-apply backups + post-apply /export captures
  PLAN.md             # historical buildout plan; live intent is in config.rsc
```

## What's already configured

- Omada controller running at `https://192.168.88.251:8043/` (image
  `mbentley/omada-controller:6.2`, host-mode networking via Colima bridged
  to `en7`).
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

- Plug monkeybrains into ether2 (WAN). DHCP client + masquerade NAT are
  already configured; should Just Work.
- Tighten `/ip ssh password-authentication` from `yes` back to
  `yes-if-no-key` once we trust the apply flow.
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
