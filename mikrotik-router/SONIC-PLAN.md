# Sonic WAN buildout — staged plan

Sonic delivered on `sfp-sfpplus1`; Monkeybrains on `ether2`. Per-SSID
WAN selection, with v4 + v6 PBR, and per-WAN failover. Designed in
[`IPV6-PLAN.md` § Phase C](IPV6-PLAN.md); staged here for incremental
apply.

**Status (2026-05-22):** Stages 0–3 applied. Reconciler-lite +
main-table flip to Sonic-primary applied at the same time. Stage 4
(Netwatch + dynamic `advertise=` flip) pending.

## Shipped design (current state)

- **Routing tables:** `main`, `mb`, `sonic`. Each carries `::/0` +
  `0.0.0.0/0` with the table's local WAN at d=1 (+`check-gateway=ping`)
  and the other WAN at d=2 (failover).
- **`main` is Sonic-primary** — router-originated traffic (DNS, NTP)
  and any traffic that doesn't match a `/routing rule` src/dst rule
  prefers Sonic.
- **v4 PBR (Stage 2):** per-VLAN source via `/routing rule`. plumtree
  (`192.168.10.0/24`) → `sonic`; guest/iot/mgmt → `mb`. A
  `dst-address=192.168.0.0/16 → main` priority rule first catches
  reply + inter-VLAN traffic so it stays on connected routes.
- **v6 PBR (Stage 3):** source-based per pool via `/routing rule`,
  same shape as v4.
- **v6 dual-GUA per VLAN with preferred-lifetime bias:** every VLAN
  binds both pools (`/ipv6 address from-pool=… advertise=no` on
  both — RA emission is driven by explicit static `/ipv6 nd prefix`
  entries instead of the auto-derived dynamic ones, since dynamic
  entries can't be `set`-mutated). Clients SLAAC TWO GUAs per VLAN
  and apply RFC 6724 Rule 3: prefer non-deprecated. Per-VLAN policy
  (steady state):
  - vlan10 (plumtree) → sonic-pd preferred-lifetime=1w, mb-pd
    preferred-lifetime=0s (deprecated)
  - vlan20/30/88 → mb-pd preferred-lifetime=1w, sonic-pd
    preferred-lifetime=0s (deprecated)
  - valid-lifetime stays long (4w2d) on all so clients hold both
    GUAs configured continuously.
  Stage 4 Netwatch scripts will flip preferred-lifetime on these
  entries on WAN-down to migrate clients to the surviving GUA on
  the next RA — without DAD-wait, since clients already have the
  fallback address provisioned.

### wan-reconciler (hybrid event-driven + polling)

A single `/system script` (`wan-reconciler`) keeps all WAN-derived
config in sync with the live DHCPv4 + DHCPv6 lease state. **All
managed entries are declared statically in `config.rsc` with bootstrap
literals + comment tags; the reconciler only ever updates them
in-place via `set`** (never `add`). Set-only is race-free because the
dhcp-client `script=` hook fires from multiple sub-events
near-simultaneously (e.g., dhcp-client/bind + dhcp-ia/acquire); a
find-then-add pattern would create duplicates.

- **`/routing rule` v6 src/dst** entries (PD-delegated /56) — declared
  with literal /56 as bootstrap. Tagged
  `comment="auto-v6-{src,dst}-<pool>"`.
- **`/ip route` gateway** for the six v4 default routes (per-table
  × per-WAN) — declared with literal next-hops as bootstrap. Tagged
  `comment="auto-v4-route-<table>-{pri|sec}-<wan>"`.
- **`/ipv6 route` gateway** for the six v6 default routes — declared
  with literal `<LL>%<interface>` as bootstrap. Tagged
  `comment="auto-v6-route-<table>-{pri|sec}-<wan>"`.
- **`/ipv6 nd prefix` `prefix=`** for the eight RA prefix entries
  (per-VLAN × per-pool) — declared with literal /64 as bootstrap.
  Tagged `comment="auto-nd-<vlan>-<pool>"`. The reconciler keeps
  `prefix=` in sync with what `/ipv6 address from-pool=…` actually
  bound, in case the /56 ever rotates. `preferred-lifetime` is NOT
  reconciler-managed in steady state (Stage 4 will manipulate it on
  WAN-down events).

The reconciler heals all four when the ISP rotates the underlying
value (PD /56, v4 next-hop, or upstream link-local).

Triggered three ways (hybrid):

- **Event-driven** — `/ip dhcp-client script="…"` and `/ipv6 dhcp-client
  script="…"` invoke the reconciler on lease bind / value change.
  Fast reaction (immediate, no scheduler delay). Fires on actual lease
  events; not on no-op renewals where values didn't change.
- **Polling** — `/system scheduler` at 10 min interval. Belt-and-
  suspenders against any drift the event-driven path misses (manual
  edits, missed events, bugs).
- **Implicit apply-day bootstrap** — dhcp-client first-bind after
  `config.rsc` import naturally fires the event-driven trigger.

The reconciler script is defined in `config.rsc` *before* `/ip
dhcp-client` so the named script exists when each dhcp-client's
`script=` property gets set during import.

The Sonic-pd /56 lives entirely in the live DHCPv6 lease state; the
v4 next-hops and v6 upstream link-locals live in `config.rsc` only as
bootstrap defaults that get healed by the reconciler when the ISP
rotates them.

## Stage 4 — Netwatch + dynamic `preferred-lifetime` flip (pending)

**Goal:** v6 failover symmetric with v4 — primary WAN down flips
`preferred-lifetime` on the static `/ipv6 nd prefix` entries so the
deprecated/preferred designation swaps. Clients applying RFC 6724
Rule 3 migrate to the surviving GUA on the next RA. Since they
already hold both addresses, there's no DAD wait — first packet on
the new GUA goes out immediately.

**`config.rsc` shape:**

- `/tool netwatch`: two probes pinging the same external target
  through different tables (avoids target-side outages firing false
  WAN-down events).
  ```
  add comment=mb-probe    type=icmp host=1.1.1.1 routing-table=mb    \
      interval=10s timeout=2s up-script=mb-up    down-script=mb-down
  add comment=sonic-probe type=icmp host=1.1.1.1 routing-table=sonic \
      interval=10s timeout=2s up-script=sonic-up down-script=sonic-down
  ```
- `/system script`: four scripts (`mb-up`, `mb-down`, `sonic-up`,
  `sonic-down`). Each flips `preferred-lifetime` on the affected
  `/ipv6 nd prefix` entries by `find comment=auto-nd-<vlan>-<pool>`.
  Example for `sonic-down` (vlan10 is the only VLAN whose primary
  is Sonic):
  ```
  /ipv6 nd prefix set [find comment=auto-nd-vlan10-sonic-pd] preferred-lifetime=0s
  /ipv6 nd prefix set [find comment=auto-nd-vlan10-mb-pd]    preferred-lifetime=1w
  ```
  `sonic-up` reverts; `mb-down` / `mb-up` are symmetric for
  vlan20/30/88.
- Extend `wan-reconciler` to also re-assert `preferred-lifetime`
  based on per-table route active state. Belt-and-suspenders against
  a missed Netwatch event.
- Tighten `/ipv6 nd min-rtr-adv-interval` on vlan10/20/30/88 to
  15–30s so RA-driven failover converges faster.

**Verify:**

- Manual trigger of `sonic-down` → `/ipv6 nd prefix print` shows
  vlan10 sonic-pd entry `preferred-lifetime=0s` and mb-pd entry
  `preferred-lifetime=1w`.
- Pull Sonic SFP → within `check-gateway` window v4 plumtree falls
  to MB; within one Netwatch interval + one RA, plumtree v6 clients
  pick up the `mb-pd` GUA via SLAAC, source from it, egress via MB.
- Restore. Within Netwatch recovery interval, scripts revert.
- Reconciler self-heal: manually misset `advertise=` on one entry;
  wait the 10 min reconciler tick; confirm restoration.

## Stages 0–3 — applied 2026-05-21/22

Live state is `config.rsc`; the git log captures the apply sequence
per stage. For the design decisions, dead-ends, and architectural
lessons that drove the shipped shape (mangle-vs-source-PBR pivot,
dynamic prefix `set` constraint, BCP38 on foreign-source v6), see
[`LESSONS.md`](LESSONS.md).

## Critical files

- [`config.rsc`](config.rsc) — source of truth for the live router.
- [`IPV6-PLAN.md`](IPV6-PLAN.md) § Phase C — parent design doc for the
  v6 multi-WAN model.
- [`README.md`](README.md) § Common pitfalls — schema-level gotchas
  to know about when editing config.rsc.
- [`LESSONS.md`](LESSONS.md) — architectural lessons learned during
  the buildout.
