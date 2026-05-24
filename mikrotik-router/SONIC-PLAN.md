# Sonic WAN buildout — staged plan

Sonic delivered on `sfp-sfpplus1`; Monkeybrains on `ether2`. Per-SSID
WAN selection, with v4 + v6 PBR, and per-WAN failover. Designed in
[`IPV6-PLAN.md` § Phase C](IPV6-PLAN.md); staged here for incremental
apply.

**Status (2026-05-23):** Stages 0–4 applied. Sonic Stage 4 (Netwatch
+ dynamic `preferred-lifetime` flip via the dual-GUA mechanism) is
the v6 counterpart to v4's route-distance failover.

## Shipped design (current state)

- **Routing tables:** `main`, `mb`, `sonic`. Each carries `::/0` +
  `0.0.0.0/0` with the table's local WAN at d=1 (+`check-gateway=ping`)
  and the other WAN at d=2 (failover).
- **`main` is Sonic-primary** — router-originated traffic (DNS, NTP)
  and any traffic that doesn't match a `/routing rule` src/dst rule
  prefers Sonic.
- **v4 PBR (Stage 2):** per-VLAN source via `/routing rule`.
  plumtree (`192.168.10.0/24`) and mgmt (`192.168.88.0/24`) →
  `sonic`; guest + iot → `mb`. A `dst-address=192.168.0.0/16 → main`
  priority rule first catches reply + inter-VLAN traffic so it stays
  on connected routes.
- **v6 PBR (Stage 3):** source-based per pool via `/routing rule`,
  same shape as v4.
- **v6 dual-GUA per VLAN with preferred-lifetime bias:** every VLAN
  binds both pools (`/ipv6 address from-pool=… advertise=no` on
  both — RA emission is driven by explicit static `/ipv6 nd prefix`
  entries instead of the auto-derived dynamic ones, since dynamic
  entries can't be `set`-mutated). Clients SLAAC TWO GUAs per VLAN
  and apply RFC 6724 Rule 3: prefer non-deprecated. Per-VLAN policy
  (steady state):
  - vlan10 (plumtree), vlan88 (mgmt) → sonic-pd preferred, mb-pd
    preferred-lifetime=0s (deprecated)
  - vlan20 (guest), vlan30 (iot) → mb-pd preferred, sonic-pd
    preferred-lifetime=0s (deprecated)
  - preferred-lifetime / valid-lifetime on the preferred entry are
    pool-derived (from /ipv6 pool) and clamped at 30m via the
    reconciler; deprecated entries hold preferred-lifetime=0s.
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

## Stage 4 — Netwatch + dynamic `preferred-lifetime` flip

**Shipped shape:** v6 failover symmetric with v4. When a WAN's
upstream becomes unreachable, the corresponding Netwatch probe fires
the `*-down` script, which flips `preferred-lifetime` on the four
affected `/ipv6 nd prefix` entries (2 VLANs × 2 pools — the two
VLANs whose primary is the failed WAN, both pools' entries). Clients
applying RFC 6724 Rule 3 migrate to the surviving GUA on the next RA
(15–30s with the tightened RA interval). Since they already hold
both addresses from the dual-GUA design, there's no DAD wait — first
packet on the new GUA goes out immediately. `*-up` scripts revert.

### Components

- **`/tool netwatch`** (two entries): probe `1.1.1.1` via ICMP, each
  with `src-address=<a VLAN IP that routes via the named WAN>`. The
  `/routing rule` chain steers the probe through the named WAN based
  on source. 7.21.4 doesn't have `routing-table=` or `interface=` on
  Netwatch, so this is the way.
  - `sonic-probe`: `src-address=192.168.10.1` (plumtree → sonic)
  - `mb-probe`: `src-address=192.168.20.1` (guest → mb)
  - `packet-count=3 packet-interval=500ms` suppresses single-packet
    noise (all 3 echoes must time out for the probe to fail).
  - 7.21.4 lacks `loss-threshold`, so any failed probe immediately
    fires the down-script. False-fail risk mitigated by 1.1.1.1's
    stability + the reconciler's `stage4Heal` self-correcting on the
    10m tick.
  - `startup-delay=60s` keeps the probes quiet until dhcp-clients
    bind on apply-day.

- **Four `/system script` entries** (`sonic-up`, `sonic-down`,
  `mb-up`, `mb-down`). Each is 4 `/ipv6 nd prefix set` calls plus
  a log line. Idempotent.

- **`/ipv6 nd` tightened RA cadence** to `min=15s max=30s` per
  active VLAN — RA-driven failover converges within one RA cycle.

- **`wan-reconciler` extended with `stage4Heal`** — reads each
  Netwatch probe's `status`, ensures the corresponding VLAN's
  `/ipv6 nd prefix` preferred-lifetime values match. Catches missed
  Netwatch events or failed script invocations on the 10m polling
  tick.

### Verify

- Manual `/system script run sonic-down` → `/ipv6 nd prefix print`
  shows vlan10/vlan88 sonic-pd entries with `preferred-lifetime=0s`
  and mb-pd entries with `preferred-lifetime=30m`.
- Software-disable Sonic interface (`/interface set sfp-sfpplus1
  disabled=yes`): within ~12s Netwatch detects + fires `sonic-down`;
  within one RA cycle (15-30s) plumtree clients deprecate sonic-pd
  GUA, source from mb-pd, egress via MB.
- Re-enable: `sonic-up` script fires within ~12s of `up` probe.
- `stage4Heal` self-heal: manually misset a `preferred-lifetime`
  to the wrong value; wait the 10m reconciler tick; confirm
  restoration.

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
