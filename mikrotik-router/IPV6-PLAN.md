# rb5009 — IPv6 enablement plan

This document is the working plan for adding IPv6 to every VLAN on the
rb5009. It is staged in three phases — **A** (ULA + firewall parity,
no ISP dependency), **B-MB** (Monkeybrains prefix delegation, single
GUA per VLAN), and **C** (Sonic-day: v4 multi-WAN routing + v6 dual-GUA
together) — so earlier work doesn't paint into a corner of the eventual
dual-WAN shape laid out in [`../CLAUDE.md`](../CLAUDE.md). Live router
intent remains [`config.rsc`](config.rsc) until each phase's separate
future apply.

The driving design choice: **let each protocol use its native
multihoming model.** v6 was built so hosts carry multiple GUAs and
pick among them via RFC 6724; v4 wasn't (one address per interface in
practice). Forcing v6 into a v4-shaped single-prefix model wastes a
built-in capability and creates an unnecessary v6 outage on per-VLAN
primary-WAN failure.

```
                 ┌───────────────────────────────────┐
                 │ Netwatch (shared, v6 foreign-src) │
                 │  probe Cloudflare v6 anycast via  │
                 │  each WAN's /56 src — fire scripts│
                 │  on up/down                       │
                 └───┬─────────────────────────┬─────┘
                     │ flips route distance    │ flips /ipv6 nd prefix
                     │ on auto-v4-route-*-pri- │ preferred-lifetime on
                     │ <wan> entries           │ auto-nd-<vlan>-<pool>
                     ▼                         ▼
            ┌──────────────────┐      ┌────────────────────────┐
            │ v4: PBR + tables │      │ v6: per-VLAN dual-GUA  │
            │  per-VLAN src →  │      │  static /ipv6 nd prefix│
            │  table=mb|sonic  │      │  preferred-lifetime    │
            │                  │      │  bias (30m / 0s)       │
            └────────┬─────────┘      └──────────┬─────────────┘
                     │ router-side                │ client-side
                     │ route flip (immediate)     │ next-RA-driven
                     ▼                            ▼
                 v4 client                    v6 client
                (1 addr, NAT)            (ULA + 2 GUAs per VLAN,
                                          RFC 6724 picks preferred)
```

Note: shipped Stage 3 ended up at *static* `/ipv6 nd prefix` entries
with explicit `preferred-lifetime` per pool per VLAN — the original
Phase C plan in spirit, but routed around the 7.21.4 quirk that
dynamic (auto-derived from `from-pool=`) entries reject `set`. We
first tried `advertise=yes/no` on `/ipv6 address` as a workaround
(Stage 3 v1) before pivoting back. Shipped Stage 4 then ended up at
a v6 foreign-source probe shape after the v4 LAN-src probe was
found to be invisible to interface-down failures (Bug A,
2026-05-24). Where this doc and SONIC-PLAN differ on Phase C
specifics, SONIC-PLAN wins.

## Terms

- **ULA (Unique Local Address):** Private IPv6 space (`fd00::/8`), not
  routed on the public Internet. Lets you run IPv6 internally without
  waiting for the ISP.
- **GUA (Global Unicast Address):** Globally routable IPv6 address. In
  this design, GUAs come from prefixes delegated by each ISP (one pool
  per WAN).
- **PD (Prefix Delegation):** The ISP (via DHCPv6-IA_PD) delegates a
  prefix to your router; you sub-allocate `/64`s per VLAN.
- **RFC 6724 source-address selection:** The host-side rule for which
  of its multiple addresses to use as the source of an outbound
  connection. The as-shipped design biases it via the
  `preferred-lifetime` field on per-pool `/ipv6 nd prefix` entries
  (Rule 3: prefer non-deprecated). Clients hold two GUAs per VLAN
  (one per pool); the deprecated one stays valid for established
  flows but new flows source from the preferred one.
- **PBR / mangle marks:** Policy-based routing in RouterOS, expressed
  as `/ip firewall mangle` (or `/ipv6 firewall mangle`) rules that mark
  packets/connections with a routing-mark; that mark steers them into a
  specific routing table (e.g. `mb` or `sonic`).

## Why pools, not literal prefixes

`/ipv6 address … from-pool=…` re-derives the assigned /64 from
whatever the dhcp-client currently has, without `config.rsc` edits.
A literal `/64` hardcoded in `config.rsc` would go stale on any
prefix rotation (ISPs are within their rights to change delegation
on renewal). Both ISPs deliver `/56` today, but neither contract
guarantees that across years.

Trade-off: pool-derived `/64`s aren't human-stable across renewals
(RouterOS picks them sequentially), so per-VLAN GUA AAAAs in `/ip dns
static` would rot. Resolution: publish only the ULA AAAA for
`router.lan` (stable forever); skip GUA AAAAs.

Where literals are unavoidable (`/routing rule` src/dst, `/ip route`
+ `/ipv6 route` gateways), the wan-reconciler updates them
in-place — see [`SONIC-PLAN.md`](SONIC-PLAN.md).

## Phase A — ULA + IPv6 firewall parity (applied 2026-05-09)

ULA `/48` `fd7f:aee1:6ce0::/48` (RFC 4193 random), subnet ID =
VLAN-ID-as-hex per VLAN (`:88::/64` = mgmt, `:10::/64` = plumtree,
etc., a mnemonic — not a numeric encoding). Per-VLAN `/ipv6 address
::1/64 advertise=yes`, `/ipv6 nd` with RDNSS pointing at the router's
ULA `::1`. `/ipv6 firewall filter` inter-VLAN drops mirror the v4
forward-chain drops. Single `router.lan` AAAA pinned to the mgmt
ULA — no GUA AAAAs (see "Why pools, not literal prefixes" above).

Live state and per-rule rationale are in `config.rsc` comments;
nothing in this section needs re-deriving.

## Phase B-MB — Monkeybrains PD + single GUA per VLAN (applied 2026-05-09)

`/ipv6 dhcp-client` on `ether2` with `pool-name=mb-pd`, MB delegates
`/56` (`2607:f598:d488:6100::/56`). Per-VLAN `/ipv6 address
from-pool=mb-pd advertise=yes` assigns one `/64` per VLAN, sequential
out of the `/56` (`:6100::/64` vlan88, `:6101::/64` vlan10, etc.).
Clients SLAAC their own GUAs from the per-VLAN /64; the router itself
has no GUA host address per VLAN (the `from-pool=` semantics on 7.21.4
is *prefix-only-to-interface* — see Probe 1 below). Router-to-client
reachability uses the per-VLAN ULA `::1` (Phase A) or link-local.

Key design choices captured here (still relevant for Stage 3):

- **No GUA AAAA per VLAN** in `/ip dns static` — pool-derived `/64`s
  rotate on lease renewal and any AAAA would go stale. Only the ULA
  AAAA for `router.lan` is published.
- **`accept-prefix-without-address=yes`** is required because MB
  delegates PD only, no IA_NA. Sonic differs (delivers both); keep the
  property on both clients for shape parity.
- **`pool-prefix-length=64`** is the *sub-allocation* size RouterOS
  hands back per `from-pool=` request, not a hint to the ISP.

Live config is in `config.rsc`'s `/ipv6 dhcp-client` and `/ipv6
address` blocks; nothing in this section needs re-applying.

## Phase C — Sonic-day: v4 multi-WAN + v6 dual-GUA together

Bundled milestone, triggered when Sonic is provisioned. The shared
machinery (Netwatch, mangle marks, routing tables) is built once and
both protocols hook into it. Detailed config is written against the
actual Sonic line specs at apply-day; this section captures the
**model**. (Probe 2 already verified 2026-05-07 — see "Schema
verification probe" below.)

### Shared infrastructure (built once, used by both)

- **Netwatch** — probes a stable address through each WAN; fires
  scripts on up/down transitions.
- **Routing tables** — one per ISP (`mb`, `sonic`), each carrying that
  WAN's default route plus the other WAN at higher distance for
  fallthrough on primary failure.
- **`/routing rule` source-based PBR** — per-VLAN source matches for
  v4 (LAN subnets) and per-pool source matches for v6 (delegated /56s).
  A `dst=LAN -> main` priority rule catches reply traffic and
  inter-VLAN traffic before the source rules fire. NOT `/ipv6 firewall
  mangle` — see [`SONIC-PLAN.md`](SONIC-PLAN.md) Stage 2 post-mortem
  for why mangle `mark-routing` doesn't work on 7.21.4.

### v4 layer — primary/secondary (applied 2026-05-22 as Sonic Stage 2)

- `/ip dhcp-client` on `sfp-sfpplus1` (Sonic) joined the WAN
  interface-list.
- Per-VLAN PBR via `/routing rule` source-based (NOT mangle — see
  [`SONIC-PLAN.md`](SONIC-PLAN.md) Stage 2 post-mortem):
  - `vlan10` (plumtree), `vlan88` (mgmt) → `sonic`
  - `vlan20` (guest), `vlan30` (iot) → `mb`
- Each routing table lists the *other* WAN at higher distance, so a
  primary-WAN failure fails through to secondary. `main` is
  Sonic-primary.
- NAT (`masquerade`) on each WAN's egress; shape unchanged.

### v6 layer — per-VLAN dual-GUA with `preferred-lifetime` bias

- Add `/ipv6 dhcp-client` on `sfp-sfpplus1` mirroring `mb-pd`,
  `pool-name=sonic-pd`.
- **ISP delivery shapes differ (observed at Stage 0 probe D,
  2026-05-21; see [`SONIC-PLAN.md`](SONIC-PLAN.md)).** Monkeybrains is
  PD-only — `accept-prefix-without-address=yes` is *required* there.
  Sonic delivers BOTH IA_NA and IA_PD: a literal GUA lands on
  `sfp-sfpplus1` (in addition to the delegated /56). Both clients
  keep `accept-prefix-without-address=yes` for shape parity — no-op
  on Sonic but mandatory on MB.
- Per VLAN, **two** `/ipv6 address from-pool=` entries (one per pool),
  **both with `advertise=no`**. The /64 binding gives source-PBR a
  match target; RA emission is handled separately.
- Per VLAN per pool, a static `/ipv6 nd prefix add` entry with an
  explicit `preferred-lifetime`. The primary-pool entry carries
  `preferred-lifetime=1w` (preferred); the secondary-pool entry
  carries `preferred-lifetime=0s` (deprecated). `valid-lifetime`
  stays long (4w2d) so clients hold both addresses configured.
- Clients SLAAC two GUAs per VLAN and apply RFC 6724 Rule 3:
  prefer non-deprecated. New flows source from the preferred-pool
  GUA; the deprecated GUA stays valid for already-established
  connections and for inbound traffic.
- Source-PBR for v6: `/routing rule` matching on the delegated `/56`
  per pool (same shape as v4 Stage 2 v5). Without it, a packet
  sourced from one pool but routed to the other WAN gets BCP38-
  dropped upstream.
- **Netwatch hook (Stage 4)** — same probes as v4. On WAN-down: script
  flips `preferred-lifetime` on the affected VLAN's static `/ipv6 nd
  prefix` entries so the surviving pool becomes preferred and the
  failed one becomes deprecated. Clients learn the new bias on the
  next RA and start new flows from the surviving GUA — no DAD wait,
  since they already hold it.

**Why this works on 7.21.4 (since we originally thought it didn't):**
the constraint we hit is that `/ipv6 nd prefix` entries auto-derived
from `/ipv6 address from-pool=… advertise=yes` are dynamic and reject
`set`. Setting `advertise=no` on the `/ipv6 address` entries
suppresses the auto-derivation; we then add explicit *static*
`/ipv6 nd prefix` entries that DO accept `set` (probed 2026-05-07
and re-confirmed 2026-05-23). See [`LESSONS.md`](LESSONS.md).

### Per-protocol failover behavior (note the asymmetry)

- **v4**: router-side route-distance flip; immediate; existing flows
  die (NAT state on the failed WAN is gone), new flows go via
  secondary through NAT.
- **v6**: client-side RA-driven; one RA interval to propagate;
  existing flows die (TCP doesn't migrate sources), new flows source
  from the now-preferred GUA.

### Phase C checklist

- [x] Probe 2 (`/ipv6 nd prefix` per-prefix preferred-lifetime override)
      confirmed (2026-05-07; see "Schema verification probe" below).
- [x] Routing tables `mb` and `sonic` each carry both default routes,
      different distances. **(Stage 2, 2026-05-22.)**
- [x] v4 source-based PBR via `/routing rule`; `traceroute` from each
      VLAN shows expected first-hop ISP. **(Stage 2, 2026-05-22.)**
- [x] v6 per-VLAN dual-GUA via static `/ipv6 nd prefix` with
      preferred-lifetime bias; `/ipv6 address` has both pools bound
      with `advertise=no`; `/ipv6 nd prefix` carries explicit
      preferred-lifetime per pool per VLAN.
      **(Stage 3 v2, 2026-05-23.)**
- [x] Netwatch entries probing both WANs, scripts wired on up/down.
      **(Stage 4, 2026-05-23; v6 foreign-source probe form after
      Bug A retrofit 2026-05-24 — see [`LESSONS.md`](LESSONS.md).)**
- [x] WAN-down failover: v4 traffic reroutes within `check-gateway`
      window; v6 RAs flip `preferred-lifetime` and clients migrate
      to the surviving GUA on the next RA (no DAD wait — both
      addresses already held). **Logical equivalent verified via
      `/interface set <wan> disabled=yes`** for both Sonic (2026-05-24)
      and MB (2026-05-24). Physical cable-pull is a follow-on test
      to validate L1 SFP-side detection.

(Phase C was always going to be a big bundle; in practice we split it
into Sonic Stages 2–4. See [`SONIC-PLAN.md`](SONIC-PLAN.md).)

## Schema verification probes — 2026-05-07

Three probe-then-revert investigations on `vlan88` (temporary
`/ipv6 dhcp-client` with `pool-name=mb-pd`) before any of this design
landed in `config.rsc`:

1. **`/ipv6 address from-pool=` semantics is prefix-only-to-interface.**
   The forms `address=::1 from-pool=...`, `eui-64=yes`, etc. don't
   combine an interface-id with the pool prefix — only
   `add from-pool=mb-pd interface=vlan88` (no `address=`) is valid,
   and it assigns the pool's `/64` to the VLAN as a network address.
   Router has no GUA host address; clients SLAAC. Router reaches
   them via ULA + link-local.
2. **`/ipv6 nd prefix preferred-lifetime` override works on static
   entries.** Caveat discovered at Stage 3: the entries auto-derived
   from `from-pool=` are *dynamic* and reject `set`. The shipped
   design works around it via `advertise=yes/no` on `/ipv6 address`.
   See [`LESSONS.md`](LESSONS.md).
3. **`/ipv6 dhcp-client renew` re-derives `from-pool=` addresses
   automatically.** Lease timer refreshes; the address's valid and
   preferred timers track it; no manual intervention. Untested with
   actual prefix rotation (couldn't force the ISP to rotate). The
   wan-reconciler covers the rotation case anyway by re-reading
   `/ipv6 pool` on every script invocation.

## Edge cases by parent-prefix length

What v6 looks like depending on what the ISP delegates:

| Parent length | Sub-`/64`s available | Phase B-MB / C behavior                                              |
|---------------|-----------------------|-----------------------------------------------------------------------|
| `/48`         | 65,536                | Plenty of headroom; `pool-prefix-length=64` works trivially.          |
| `/56` (current MB) | 256              | Plenty for 4 VLANs.                                                   |
| `/60`         | 16                    | Fine; still room for growth.                                          |
| `/63`         | 2                     | Tight: only enough for 2 VLANs from this WAN. Document per-VLAN priority before applying. |
| `/64`         | 1                     | Cannot sub-allocate per-VLAN. Options: bridge a single `/64` across all VLANs (loses inter-VLAN v6 firewalling on that WAN) or treat that WAN as v4-only and lean on the other WAN for v6. |
| no PD         | 0                     | Stay on Phase A (ULA only) for that WAN.                              |

## Omada / APs

SSIDs already map to VLANs 10/20/30; APs bridge IPv6 like IPv4. If the
controller exposes per-SSID IPv6 toggles, leave them consistent with
"RA from the gateway" unless you have a reason to override.

## Phase C apply staging

Phase C is staged as [`SONIC-PLAN.md`](SONIC-PLAN.md) Stages 0–4,
all applied 2026-05-22 through 2026-05-24. Where this doc and
SONIC-PLAN differ on Phase C specifics, SONIC-PLAN wins (notably:
shipped Stage 3 swapped `advertise=yes/no` for static
`/ipv6 nd prefix` with explicit `preferred-lifetime` bias, and
shipped Stage 4 uses v6 foreign-source probes instead of v4 LAN-src
probes — both pivots are documented in [`LESSONS.md`](LESSONS.md)).

## Risks

- **RA propagation latency** during failover — clients learn the
  `preferred-lifetime` flip on the next RA. RA cadence is tightened
  to `ra-interval=15s-30s` on affected VLANs so failover converges
  within one cycle. Going much lower would make RA itself noise.
- **Scripted state.** Stage 4's Netwatch up/down scripts are the
  most stateful piece. Belt-and-suspenders: `wan-reconciler`'s
  `ndPreferredReconcile` pass re-asserts `preferred-lifetime` on
  every 10m tick from the current netwatch probe status, so a
  missed Netwatch event self-heals on the next tick. Same shape as
  the other reconciler-managed surfaces.
- **Firewall ordering:** Mistakes black-hole IPv6 or break ND; test
  from each SSID after changes.
- **RouterOS schema gotchas** — see [`README.md`](README.md) Common
  pitfalls and [`LESSONS.md`](LESSONS.md).

## Out of scope

- **NPTv6 / NAT66.** Not needed in this design — both WANs delegate
  prefixes, so clients carry real GUAs from each.
- **Stateful DHCPv6 / reservations.** Phase A/B-MB use SLAAC + RDNSS;
  add stateful DHCPv6 only if a future need arises.
- **Per-SSID IPv6 controller policy.** Omada-side per-SSID v6 toggles
  stay default unless we hit a concrete reason to override.
- **Touching `config.rsc` in this pass.** Each phase is its own apply.
