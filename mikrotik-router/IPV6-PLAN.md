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
                     │ flips route distance    │ flips RA preferred-lifetime
                     ▼                         ▼
            ┌──────────────────┐      ┌────────────────────┐
            │ v4: PBR + tables │      │ v6: dual-GUA + RA  │
            │  per-VLAN mark → │      │  pref-LT 7d / 0    │
            │  table=mb|sonic  │      │  per VLAN per WAN  │
            └────────┬─────────┘      └──────────┬─────────┘
                     │ router-side                │ client-side
                     │ route flip (immediate)     │ RA-driven (next interval)
                     ▼                            ▼
                 v4 client                    v6 client
                (1 addr, NAT)            (ULA + 2 GUAs, RFC 6724)
```

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
  connection. We bias it via RA-advertised `preferred-lifetime`:
  `preferred-lifetime=0` deprecates a prefix so clients won't pick it
  for new flows.
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
- **Mangle marks** — `/ip firewall mangle` and `/ipv6 firewall mangle`
  mark connections by source VLAN (and for v6, by source prefix as a
  safety net) and route via the appropriate table.

### v4 layer — primary/secondary

- Add `/ip dhcp-client` on `sfp-sfpplus1` (Sonic).
- Per-VLAN PBR via mangle:
  - `vlan10` (plumtree) → `sonic`
  - `vlan20` (guest), `vlan30` (iot), `vlan88` (mgmt) → `mb`
- Each routing table lists the *other* WAN at higher distance, so a
  primary-WAN failure fails through to secondary.
- NAT (`masquerade`) on each WAN's egress, shape unchanged from
  `config.rsc:238–239`.
- Applied 2026-05-22 as Sonic Stage 2 via source-based PBR
  (`/routing rule`), not mangle mark-routing. See
  [`SONIC-PLAN.md`](SONIC-PLAN.md) Stage 2 for the live shape.

### v6 layer — preferred/allowed via RA timers

- Add `/ipv6 dhcp-client` on `sfp-sfpplus1` mirroring `mb-pd`,
  `pool-name=sonic-pd`.
- **ISP delivery shapes differ (observed at Stage 0 probe D,
  2026-05-21; see [`SONIC-PLAN.md`](SONIC-PLAN.md)).** Monkeybrains is
  PD-only — `accept-prefix-without-address=yes` is *required* there.
  Sonic delivers BOTH IA_NA and IA_PD: a literal GUA lands on
  `sfp-sfpplus1` (observed `2001:5a8:601:2b::2:1ba2`, rotates on
  lease) *in addition to* the delegated /56 (observed
  `2001:5a8:6a4:d500::/56`). Both clients keep
  `accept-prefix-without-address=yes` for shape parity — it's a no-op
  on Sonic but mandatory on MB. The Sonic IA_NA address is not used
  by the dual-GUA design (clients still SLAAC per-VLAN from the
  delegated `/56`), but it gives the router a stable v6 source for
  outbound on Sonic should we want one (e.g., source-pinned Netwatch
  probes); MB has no equivalent, and from-router v6 sources on the
  MB side come from per-VLAN GUAs or link-local.
- Per VLAN, **two** `/ipv6 address from-pool=` entries: one
  `from-pool=mb-pd`, one `from-pool=sonic-pd`. Both `advertise=yes`.
- `/ipv6 nd prefix` per-prefix `preferred-lifetime` overrides:

  | VLAN   | `mb-pd` preferred-lifetime | `sonic-pd` preferred-lifetime |
  |--------|----------------------------|-------------------------------|
  | vlan10 | `0` (deprecated)           | `7d` (preferred)              |
  | vlan20 | `7d` (preferred)           | `0` (deprecated)              |
  | vlan30 | `7d` (preferred)           | `0` (deprecated)              |
  | vlan88 | `7d` (preferred)           | `0` (deprecated)              |

- Source-PBR for v6: marks on **source-prefix** instead of
  in-interface, mechanically identical to v4 PBR. Acts as a safety net
  so non-preferred GUAs (still valid for inbound, not yet expired)
  don't trigger BCP38 / asymmetric routing if a client uses one.
- **Netwatch hook** — same probes as v4. On WAN-down: script flips the
  per-prefix `preferred-lifetime` so clients move to the surviving GUA
  on the next RA. On WAN-up: revert.

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
- [ ] Netwatch entries probing both WANs, scripts wired on up/down.
- [ ] Routing tables `mb` and `sonic` each carry both default routes,
      different distances.
- [ ] v4 PBR mangle rules per VLAN; `traceroute` from each VLAN shows
      expected first-hop ISP.
- [ ] v6 dual-GUA per VLAN; `/ipv6 address print` shows both, only one
      preferred per VLAN per RA.
- [ ] Pulling primary WAN cable: v4 traffic reroutes within Netwatch
      probe window; v6 RAs flip `preferred-lifetime` and new flows use
      surviving GUA within one RA interval.

### Optional split

If the apply window is too long, split Phase C:

- **C-v4**: dual-WAN PBR routing first (`/ip` only). v6 stays on
  Phase B-MB.
- **C-v6**: dual-GUA layered on top of working PBR. Reuses the same
  Netwatch + routing-table scaffolding.

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

### Probe 2 — `/ipv6 nd prefix` per-prefix `preferred-lifetime` (Phase C gate): finding — **works cleanly**

`add prefix=2607:f598:d488:6100::/64 interface=vlan88
preferred-lifetime=0s` was accepted. Resulting entry has
`preferred-lifetime=0s`, default `valid-lifetime=4w2d`,
`on-link=yes`, `autonomous=yes`.

Script-driven flips: `set [find ...] preferred-lifetime=1w` and back
to `0s` both succeeded. This is exactly the operation the Phase C
Netwatch failover script will perform, and it works in the
running 7.21.4. **The full-RA-replacement fallback noted in Risks
below is no longer needed; the v6 failover model is implementable
as designed.**

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

Phase C (Sonic-day v6 + v4 multi-WAN) is staged as
[`SONIC-PLAN.md`](SONIC-PLAN.md) Stages 0–4. The IPv4 piece (Stage 2
source-based PBR) is already applied; v6 dual-GUA + Netwatch arrive in
Stages 3 and 4. Where IPV6-PLAN.md and SONIC-PLAN.md differ on Phase C
specifics, SONIC-PLAN.md wins — it's been refined by running into the
actual gotchas.

## Risks

- ~~`/ipv6 nd prefix` per-prefix `preferred-lifetime` override
  syntax~~ **Resolved 2026-05-07** by probe 2 — works cleanly via
  `set [find ...] preferred-lifetime=...`. Full-RA-replacement
  fallback no longer needed.
- **RA propagation latency** during failover — clients learn flipped
  preference on the next RA. Tighten `min-rtr-adv-interval`
  (15–30s) on the affected VLANs for faster recovery; don't go too
  low or RA traffic itself becomes a noise source.
- **Phase C bundles a lot.** v4 multi-WAN was the first half (now
  Sonic Stage 2, applied 2026-05-22). v6 dual-GUA + Netwatch are
  Stages 3 + 4.
- **Scripted state.** The Netwatch RA-timer flip is the most stateful
  bit in the design. Belt-and-suspenders: also include a periodic
  reconciliation script that ensures timers match current WAN state
  every N minutes, so a missed event doesn't leave the network in a
  bad steady state.
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
