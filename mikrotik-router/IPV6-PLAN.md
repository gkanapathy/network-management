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
                 │ Netwatch (shared)                 │
                 │  probe MB GW, probe Sonic GW      │
                 │  fire scripts on up/down          │
                 └───┬─────────────────────────┬─────┘
                     │ flips route distance    │ flips /ipv6 address advertise=
                     ▼                         ▼
            ┌──────────────────┐      ┌────────────────────┐
            │ v4: PBR + tables │      │ v6: per-VLAN       │
            │  per-VLAN src →  │      │  single-GUA via RA │
            │  table=mb|sonic  │      │  advertise=yes/no  │
            └────────┬─────────┘      └──────────┬─────────┘
                     │ router-side                │ client-side
                     │ route flip (immediate)     │ next-RA-driven SLAAC
                     ▼                            ▼
                 v4 client                    v6 client
                (1 addr, NAT)            (ULA + 1 GUA per VLAN)
```

Note: as-shipped design swapped RA `preferred-lifetime` bias (the
original Phase C plan) for `advertise=yes/no` on `/ipv6 address`,
after we found dynamic `/ipv6 nd prefix` entries reject `set` on
7.21.4. See [`SONIC-PLAN.md`](SONIC-PLAN.md) Stage 3 for the
post-mortem. Where this doc and SONIC-PLAN differ on Phase C
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
  connection. The original Phase C plan biased it via RA-advertised
  `preferred-lifetime`; the as-shipped design sidesteps it by
  advertising only one GUA per VLAN so clients have no choice to make.
- **PBR / mangle marks:** Policy-based routing in RouterOS, expressed
  as `/ip firewall mangle` (or `/ipv6 firewall mangle`) rules that mark
  packets/connections with a routing-mark; that mark steers them into a
  specific routing table (e.g. `mb` or `sonic`).

## Why pools, not literal prefixes

Once `config.rsc` references a specific GUA `/64` (e.g. `2607:f598:d488:6188::1/64`),
that string lives there until the next renewal — at which point the
delegation may be a different prefix entirely, and the literal goes
stale. The pool model (`/ipv6 pool` populated from the DHCP client,
`/ipv6 address … from-pool=…`) lets RouterOS re-derive the address from
whatever the lease currently is, without `config.rsc` edits. This
matters because:

- **Monkeybrains lease length is observed `/56` today** but ISPs change
  delegation policy without warning.
- **Sonic's eventual delegation length is unknown** (`/48`–`/64`).
- **Renewal can change the prefix** even without a length change.

Trade-off: pool-derived `/64`s aren't human-stable across renewals
(RouterOS picks them sequentially), so per-VLAN GUA AAAAs in `/ip dns
static` would rot. Solution: publish only the ULA AAAA for `router.lan`
(stable forever); skip GUA AAAAs.

## Current baseline

- IPv4 only on `vlan88` / `vlan10` / `vlan20` / `vlan30`; WAN is DHCP on
  `ether2`.
- `/ipv6 firewall` rules exist (defconf-style hardening at
  `config.rsc:253–277`) but IPv6 is not actively addressed on LAN VLANs
  and the inter-VLAN policy from IPv4 (`config.rsc:232–235`) is **not
  yet mirrored into IPv6**.
- Management services already allow `fe80::/10` in `address=` alongside
  RFC1918 nets so **link-local SSH recovery** in [`README.md`](README.md)
  stays valid.

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
  - `vlan10` (plumtree) → `sonic`
  - `vlan20` (guest), `vlan30` (iot), `vlan88` (mgmt) → `mb`
- Each routing table lists the *other* WAN at higher distance, so a
  primary-WAN failure fails through to secondary. `main` is now
  Sonic-primary (applied 2026-05-22 with the reconciler-lite change).
- NAT (`masquerade`) on each WAN's egress; shape unchanged.

### v6 layer — per-VLAN single-GUA via `advertise=yes/no`

- Add `/ipv6 dhcp-client` on `sfp-sfpplus1` mirroring `mb-pd`,
  `pool-name=sonic-pd`.
- **ISP delivery shapes differ (observed at Stage 0 probe D,
  2026-05-21; see [`SONIC-PLAN.md`](SONIC-PLAN.md)).** Monkeybrains is
  PD-only — `accept-prefix-without-address=yes` is *required* there.
  Sonic delivers BOTH IA_NA and IA_PD: a literal GUA lands on
  `sfp-sfpplus1` (in addition to the delegated /56). Both clients
  keep `accept-prefix-without-address=yes` for shape parity — no-op
  on Sonic but mandatory on MB.
- Per VLAN, **two** `/ipv6 address from-pool=` entries (one per pool)
  — but only the primary pool sets `advertise=yes`. Clients SLAAC
  exactly one GUA per VLAN — the matching primary WAN's. No RFC 6724
  source-bias needed; clients have no choice to make. Both /64s are
  still bound on the interface so source-PBR matches outbound traffic
  from either pool's address space (relevant for router-originated v6).
- Source-PBR for v6: `/routing rule` matching on the delegated `/56`
  per pool (same shape as v4 Stage 2 v5). Without it a packet sourced
  from one pool but routed to the other WAN gets BCP38-dropped
  upstream.
- **Netwatch hook (Stage 4)** — same probes as v4. On WAN-down: script
  flips `advertise=yes/no` on the affected VLAN so the fallback pool's
  GUA gets advertised; clients SLAAC the new GUA on the next RA. On
  WAN-up: revert.

**Earlier design — abandoned:** original Phase C plan was "advertise
both pools per VLAN with `advertise=yes`, deprecate the non-primary
via `/ipv6 nd prefix set [find ...] preferred-lifetime=0s` (script-
driven)". The probe 2 finding below tested a *static* `/ipv6 nd
prefix add` entry — but the entries derived from `/ipv6 address
from-pool=...` are *dynamic*, and `set` on them fails ("can not
change dynamic prefix"). The shipped design swaps the bias mechanism
to `advertise=yes/no` on `/ipv6 address` itself. Trade-off: no
dual-GUA safety net during a single-WAN outage until Stage 4 lands.
A future revisit could use a static `/ipv6 nd prefix add` per VLAN
per pool to restore the dual-GUA path; deferred.

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
- [x] v6 per-VLAN single-GUA via `advertise=yes/no`; `/ipv6 address
      print` shows both pools bound, only primary advertised.
      **(Stage 3, 2026-05-22 — replaces the original "dual-GUA +
      preferred-lifetime" design, see v6 layer section above.)**
- [ ] Netwatch entries probing both WANs, scripts wired on up/down.
      **(Stage 4.)**
- [ ] Pulling primary WAN cable: v4 traffic reroutes within
      `check-gateway` window; v6 RAs flip `advertise=` and new clients
      SLAAC the surviving GUA within one Netwatch + RA interval.
      **(Stage 4.)**

(Phase C was always going to be a big bundle; in practice we split it
into Sonic Stages 2–4. See [`SONIC-PLAN.md`](SONIC-PLAN.md).)

## Schema verification probe — 2026-05-07: completed

Ran early (rather than between Phase B-MB and Phase C) to de-risk
both phases before any of their config gets committed. Probe-then-
revert on `vlan88` with `comment="probe-only-remove-after"`; pre/post
`/export hide-sensitive` differed only by timestamp. All three probes
used a temporary `/ipv6 dhcp-client` on `ether2` with
`pool-name=mb-pd` (the same shape Phase B-MB will use).

### Probe 1 — `/ipv6 address from-pool=` syntax (Phase B-MB gate): finding — **prefix-only-to-interface**

The originally-assumed form (`address=::1 from-pool=mb-pd`) is **not**
how RouterOS 7.21.4 combines an interface-id with the pool prefix. It
doesn't combine them at all. Forms tested:

| Form                                                                       | Result                                              |
|----------------------------------------------------------------------------|-----------------------------------------------------|
| `add address=::1 from-pool=mb-pd interface=vlan88`                         | INVALID — literal `::1/64`, no pool prefix applied  |
| `add address=::2 from-pool=mb-pd interface=vlan88`                         | INVALID — same                                      |
| `add from-pool=mb-pd interface=vlan88 eui-64=yes`                          | INVALID — `::/64`, no IID computed                  |
| `add from-pool=mb-pd interface=vlan88` (no `address=`)                     | **VALID** — `2607:f598:d488:6100::/64` on vlan88    |

The valid form assigns the pool's `/64` to the VLAN as a network
address. The router has no GUA host address from this entry; clients
SLAAC; router-to-client reachability uses link-local (RA gateway) and
the per-VLAN ULA `::1` from Phase A. Phase B-MB §2 above and the
"Where to edit `config.rsc`" section below are written against this
finding.

### Probe 2 — `/ipv6 nd prefix` per-prefix `preferred-lifetime` (Phase C gate): finding — **works on static entries only**

`add prefix=2607:f598:d488:6100::/64 interface=vlan88
preferred-lifetime=0s` was accepted; subsequent `set` succeeded.

**Limitation discovered at Stage 3 (2026-05-22):** the probe tested
a *static* `/ipv6 nd prefix add` entry. The actual entries derived
from `/ipv6 address from-pool=...` are *dynamic* (`D` flag) and
reject `set` with `failure: can not change dynamic prefix`. So the
original Phase C design — advertise both pools, deprecate one via
preferred-lifetime override — turned out to be unimplementable as
designed on 7.21.4. The shipped design uses `advertise=yes/no` on
`/ipv6 address` instead.

A future revisit could restore the dual-GUA path via 8 static `/ipv6
nd prefix add` entries (4 VLANs × 2 pools) with computed /64 literals
— at the cost of /64-rotation bookkeeping. Deferred.

### Probe 3 — `/ipv6 dhcp-client renew` re-derivation (Phase B-MB gate): finding — **automatic**

`renew [find pool-name=mb-pd]` refreshed the lease timer
(2d23h59m40s → 2d23h59m55s) and the `from-pool=` address's `valid`
and `preferred` timers tracked it (2d23h56m33s → 2d23h59m4s on
`valid`; 2d16h44m33s → 2d16h47m4s on `preferred`). No manual
intervention required.

**Untested:** behavior when the ISP rotates the prefix (would need
Monkeybrains to actually rotate, which can't be forced). Mechanism
(`from-pool=` tracks the dhcp-client) should handle it transparently
— the address re-derives from whatever new `/64` the pool ends up
with.

### Hygiene

All probes used `comment="probe-only-remove-after"`. Removed before
any `/export` was captured into `snapshots/`. Nothing landed in
`config.rsc`.

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

Phase C is staged as [`SONIC-PLAN.md`](SONIC-PLAN.md) Stages 0–4.
Stages 0–3 + reconciler-lite applied 2026-05-22; Stage 4 (Netwatch +
`advertise=` flip) pending. Where this doc and SONIC-PLAN differ on
Phase C specifics, SONIC-PLAN wins.

## Risks

- **`/ipv6 nd prefix` dynamic entries reject `set`.** The original
  preferred-lifetime-bias mechanism doesn't work for from-pool-derived
  prefixes; shipped design uses `advertise=yes/no` on `/ipv6 address`
  instead. See probe 2 above and [`README.md`](README.md) Common
  Pitfalls.
- **RA propagation latency** during failover — clients learn the
  `advertise=` flip on the next RA. Tighten `min-rtr-adv-interval`
  (15–30s) on the affected VLANs for faster recovery; don't go too
  low or RA traffic itself becomes noise.
- **Scripted state.** Stage 4's Netwatch `advertise=` flip is the
  most stateful bit. Belt-and-suspenders: a periodic reconciler
  re-asserts `advertise=` from per-table route active state so a
  missed Netwatch event doesn't leave the network in a bad steady
  state. (Reconciler-lite already shipped for the `/routing rule` v6
  src/dst entries 2026-05-22 — same pattern extended to `advertise=`
  in Stage 4.)
- **Firewall ordering:** Mistakes black-hole IPv6 or break ND; test
  from each SSID after changes.
- **RouterOS schema:** Verify every `set`/`add` property on the
  running version before relying on it in `config.rsc` (see README
  "Common pitfalls").

## Out of scope

- **NPTv6 / NAT66.** Not needed in this design — both WANs delegate
  prefixes, so clients carry real GUAs from each.
- **Stateful DHCPv6 / reservations.** Phase A/B-MB use SLAAC + RDNSS;
  add stateful DHCPv6 only if a future need arises.
- **Per-SSID IPv6 controller policy.** Omada-side per-SSID v6 toggles
  stay default unless we hit a concrete reason to override.
- **Touching `config.rsc` in this pass.** Each phase is its own apply.
