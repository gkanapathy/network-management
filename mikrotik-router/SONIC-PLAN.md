# Sonic WAN buildout — staged plan

Sonic delivered on `sfp-sfpplus1`; Monkeybrains on `ether2`. Per-SSID
WAN selection, with v4 + v6 PBR, and per-WAN failover. Designed in
[`IPV6-PLAN.md` § Phase C](IPV6-PLAN.md); staged here for incremental
apply.

**Status (2026-05-24):** Stages 0–4 applied; Bug A fix in Stage 4
applied 2026-05-24 (switched probes from v4 1.1.1.1 to v6 Cloudflare
anycast with foreign-source src — see [`LESSONS.md`](LESSONS.md)).
Stage 4 (Netwatch + dynamic `preferred-lifetime` flip via the
dual-GUA mechanism) is the v6 counterpart to v4's route-distance
failover.

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
  reconciler-managed in steady state (Stage 4 manipulates it on
  WAN-down events).
- **`/tool netwatch` `src-address=`** for the two Stage 4 probes —
  declared with the current /56's expected EUI-64-derived GUA as
  bootstrap. The reconciler reads the router's host GUA from the
  matching `/ipv6 address from-pool=… eui-64=yes` entry (found by
  `comment="probe-src-<pool>"`) and `set`s netwatch `src-address`
  if it changed. Only the prefix part rotates (host part is stable
  from the pinned bridge MAC), so this only fires on /56 rotation.

The reconciler heals all five when the ISP rotates the underlying
value (PD /56, v4 next-hop, upstream link-local, or /64 sub-allocation).

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

v6 failover symmetric with v4. Per-WAN Netwatch probe of Cloudflare
v6 anycast `2606:4700:4700::1111` from a router host GUA in that
WAN's /56. On failure, `*-down` script flips `preferred-lifetime`
on the four `/ipv6 nd prefix` entries (2 VLANs × 2 pools) for that
WAN's primary VLANs. Clients re-pick the surviving GUA on the next
RA (15-30s with `ra-interval=15s-30s`); no DAD wait because clients
hold both addresses from the dual-GUA design. `*-up` reverts.

The probe shape (foreign-source v6, not v4 LAN-IP src) was chosen
after the original Stage 4 design was found broken — see Bug A in
[`LESSONS.md`](LESSONS.md) for the diagnosis and why
reply-path-broken makes the v6 probe reliably detect WAN failures
that v4 probes miss.

### Components

- **`/tool netwatch`** (two entries) — `host=2606:4700:4700::1111`,
  `src-address=<router's host GUA in pool>`. `/routing rule
  src=<pool>::/56 → table=<pool>` steers via src-PBR. Bootstrap
  literal is the current /56's expected EUI-64 GUA; reconciler
  tracks /56 rotation via `netwatchSrcReconcile`.
- **`/ipv6 address`** on `vlan88` with `eui-64=yes` per pool — gives
  the router host GUAs to use as probe src. Host part stable from
  pinned bridge MAC; prefix auto-tracks pool rotation. mgmt VLAN
  picked because router-originated probe traffic naturally belongs
  there.
- **Four `/system script` entries** (`sonic-up`, `sonic-down`,
  `mb-up`, `mb-down`) with `policy=read,write,test,reboot` — the
  netwatch caller envelope (full default policy exceeds it and gets
  refused; see [`LESSONS.md`](LESSONS.md)).
- **`/ipv6 nd ra-interval=15s-30s`** per active VLAN — RA-driven
  failover converges within one RA cycle.
- **`wan-reconciler`** extended with two Stage 4 passes:
  `netwatchSrcReconcile` updates netwatch `src-address=` on /56
  rotation; `stage4Heal` re-asserts `preferred-lifetime` from
  current netwatch status, catching missed events on the 10m tick.

### Verify

- `/interface set sfp-sfpplus1 disabled=yes`: within ~10s
  sonic-probe transitions to `down`, `sonic-down` runs, vlan10 +
  vlan88 sonic-pd `preferred-lifetime` flips to `0s` and mb-pd to
  `30m`. Re-enable: opposite, within ~15s of probe up.
- `/system script run sonic-down` manually: same effect,
  bypasses the probe (verifies the script body in isolation).
- `stage4Heal` self-heal: misset a `preferred-lifetime`, wait the
  next 10m reconciler tick.

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
