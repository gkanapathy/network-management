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
  same shape as v4. ULA dst rule is static; per-pool /56 src/dst
  rules are reconciler-managed (see below).
- **v6 single-GUA per VLAN:** every VLAN binds *both* pools (so
  source-PBR can match either) but only the primary pool sets
  `advertise=yes`. Clients SLAAC exactly one GUA per VLAN — the
  matching primary WAN's. Trade-off: no dual-GUA safety net during a
  single-WAN outage until Stage 4 flips `advertise=` on the fallback
  pool.

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

The reconciler heals all three when the ISP rotates the underlying
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

## Stage 4 — Netwatch + dynamic `advertise=` flip (pending)

**Goal:** v6 failover symmetric with v4 — primary WAN down toggles
`/ipv6 address ... advertise=yes/no` on the affected VLAN so clients
SLAAC the fallback pool's GUA on the next RA. Original SONIC-PLAN
draft used `/ipv6 nd prefix preferred-lifetime` overrides; 7.21.4
rejects `set` on dynamic prefix entries (Stage 3 post-mortem). The
`advertise=yes/no` toggle on `/ipv6 address` works in steady state
(Stage 3 confirmed) so Stage 4 reuses it dynamically.

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
  `sonic-down`). Each flips `advertise=` on the affected `/ipv6
  address` entries by `find interface=... from-pool=...` (both stable
  across PD renewal, unlike the literal prefix). Example for
  `sonic-down`:
  ```
  /ipv6 address set [find interface=vlan10 from-pool=sonic-pd] advertise=no
  /ipv6 address set [find interface=vlan10 from-pool=mb-pd]    advertise=yes
  ```
  `sonic-up` reverts; `mb-down` / `mb-up` are symmetric for
  vlan20/30/88.
- Extend `wan-reconciler` to also re-assert `advertise=` based on
  per-table route active state (`/ip route get [find …] active`).
  Belt-and-suspenders against a missed Netwatch event.
- Tighten `/ipv6 nd min-rtr-adv-interval` on vlan10/20/30/88 to
  15–30s so RA-driven failover converges faster.

**Verify:**

- Manual trigger of `sonic-down` → `/ipv6 address print` shows the
  flip on vlan10.
- Pull Sonic SFP → within `check-gateway` window v4 plumtree falls
  to MB; within one Netwatch interval + one RA, plumtree v6 clients
  pick up the `mb-pd` GUA via SLAAC, source from it, egress via MB.
- Restore. Within Netwatch recovery interval, scripts revert.
- Reconciler self-heal: manually misset `advertise=` on one entry;
  wait the 10 min reconciler tick; confirm restoration.

## Stages 0–3 — history (collapsed)

Detail lives in `config.rsc` comments; what's worth preserving:

- **Stage 0 probes (2026-05-21)** captured Sonic delivery shape:
  DHCP/IPoE with IA_NA + IA_PD /56, v4 next-hop `23.93.120.1`, v6
  upstream LL `fe80::5e5e:abff:feda:ebc0%sfp-sfpplus1`, 6h lease.
  Also: 7.21.4 has `default-route-distance` / `default-route-tables`
  on `/ipv6 dhcp-client` (both single-value); `add-default-route`
  defaults to `no` on v6 (unlike v4); `default-route-tables=default`
  maps to `main`.
- **Stage 1 (2026-05-21)** bound Sonic as passive secondary.
  Failover/recovery converges in ~6s for v4 + v6; cable-pull recovery
  ~2s. Sonic upstream BCP38-drops foreign-source v6 packets (motivated
  Stage 3's source-PBR as mandatory, not safety-net).
- **Stage 2 (2026-05-22)** v4 source-based PBR via `/routing rule`.
  Took five iterations: v1–v4 used `/ip firewall mangle mark-routing`
  and all broke return traffic, because (a) 7.x has no LPM across
  tables and no fallback to main, and (b) conntrack carries the
  routing-mark to reply direction. Source-based `/routing rule` (v5)
  never sets a mark; reply packets bypass the rules and fall through
  to `main` where connected LAN routes always worked. Generalized
  lesson in [`README.md`](README.md) § Common Pitfalls.
- **Stage 3 (2026-05-22)** v6 source-based PBR + single-GUA-per-VLAN.
  Original "dual-GUA + `/ipv6 nd prefix` preferred-lifetime" design
  failed because dynamic prefix entries reject `set` on 7.21.4.
  Switched to `advertise=yes/no` on `/ipv6 address` itself.

## Critical files

- [`config.rsc`](config.rsc) — source of truth for the live router.
- [`IPV6-PLAN.md`](IPV6-PLAN.md) § Phase C — parent design doc for the
  v6 multi-WAN model.
- [`README.md`](README.md) § Common Pitfalls — generalized lessons
  across all stages.
