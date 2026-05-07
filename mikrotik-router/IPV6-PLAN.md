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

## Phase A — ULA + IPv6 firewall parity (no ISP dependency)

Fully verifiable today; doesn't wait on either ISP.

### 1. Choose a ULA /48

Per RFC 4193, pick a random **`fd00::/8` ULA `/48`** before
implementation (do not copy documentation examples blindly). One way:
roll 40 bits of randomness after `fd` and format as
`fdXX:XXXX:XXXX::/48`.

The **subnet ID** (next 16 bits after the `/48`) follows a mnemonic so
each VLAN maps to one `/64`:

| VLAN | Role     | Subnet (replace prefix with yours) | Router address |
|------|----------|------------------------------------|----------------|
| 88   | mgmt     | `fdXX:XXXX:XXXX:88::/64`           | `...::1/64`    |
| 10   | plumtree | `fdXX:XXXX:XXXX:10::/64`           | `...::1/64`    |
| 20   | guest    | `fdXX:XXXX:XXXX:20::/64`           | `...::1/64`    |
| 30   | iot      | `fdXX:XXXX:XXXX:30::/64`           | `...::1/64`    |

Implement with `/ipv6 address add address=<...::1/64> interface=vlanNN
advertise=yes` on each VLAN sub-interface.

### 2. Router advertisement (SLAAC + DNS)

On each VLAN, configure `/ipv6 nd` so hosts autoconfigure and learn
DNS:

- Enable RA on `vlan88`, `vlan10`, `vlan20`, `vlan30`.
- Set **RDNSS** to the router's ULA on that VLAN (`...::1`) so clients
  use the router as resolver (same role as IPv4 DHCP "DNS = gateway").
- If you use non-default MTU on WAN, set consistent **MTU** hints
  where RouterOS exposes them.

### 3. IPv6 firewall parity with IPv4

Today's `/ipv6 firewall filter` does not encode inter-VLAN policy. Add
**forward** rules mirroring the IPv4 inter-VLAN drops at
`config.rsc:232–235`, ordered **before** the broad `drop everything not
from LAN` rule at `config.rsc:277`:

| Mirror of (IPv4)                 | New IPv6 rule                                                              |
|----------------------------------|----------------------------------------------------------------------------|
| `config.rsc:232` guest → LAN     | `in-interface=vlan20 out-interface-list=LAN action=drop`                   |
| `config.rsc:233` iot → mgmt      | `in-interface=vlan30 out-interface=vlan88 action=drop`                     |
| `config.rsc:234` iot → plumtree  | `in-interface=vlan30 out-interface=vlan10 connection-state=new action=drop` |
| `config.rsc:235` iot → guest     | `in-interface=vlan30 out-interface=vlan20 action=drop`                     |

The `connection-state=new` form on the iot → plumtree rule lets return
traffic from plumtree-initiated flows back through, same as IPv4.

**Keep untouched:**

- ICMPv6 accept rules at `config.rsc:256` (input) and `config.rsc:271`
  (forward) — Neighbor Discovery (RS/RA/NS/NA) depends on them.
- The `bad_ipv6` address list and its forward drops at
  `config.rsc:268–269`.

**Do not** add `/ipv6 firewall nat` unless you explicitly adopt
NPTv6/NAT66 — neither is needed in this design.

### 4. Static DNS name for the router

Mirror the existing `router.lan` A record at `config.rsc:212`: add
`type=AAAA address=<mgmt-ULA::1>` in `/ip dns static`. Mgmt VLAN ULA is
the natural choice for the single-name AAAA. **No GUA AAAAs** (see
"Why pools, not literal prefixes" above).

### 5. Default route expectation

In ULA-only mode there is no default IPv6 route; that is expected.
Hosts still get ULA for internal traffic and for validating firewall
rules.

### Phase A checklist

- [ ] Generated own ULA `/48`; documented final hex in `config.rsc`
      comments.
- [ ] `/ipv6 address` on `vlan88`, `vlan10`, `vlan20`, `vlan30`
      (`advertise=yes`).
- [ ] `/ipv6 nd` per VLAN with RDNSS pointing at the per-VLAN ULA `::1`.
- [ ] Four inter-VLAN drop rules in `/ipv6 firewall filter`, ahead of
      the broad LAN drop.
- [ ] `router.lan` AAAA static entry next to the existing A.
- [ ] Smoke test: each SSID obtains an address in the expected `/64`;
      ping6 to gateway succeeds; guest → plumtree gateway ping6 fails.

## Phase B-MB — Monkeybrains PD + single GUA per VLAN

Single WAN exists; "primary-only" is "the only one." No source-PBR
needed yet — only one default v6 route. **Run probes 1 and 3 from
"Schema verification probe" below before applying this phase.**

### 1. DHCPv6-PD client on `ether2`

Add `/ipv6 dhcp-client` on `ether2`:

```
request=address,prefix
pool-name=mb-pd
pool-prefix-length=64
accept-prefix-without-address=yes
add-default-route=yes
use-peer-dns=no
```

Notes:

- `pool-prefix-length=64` is the **sub-allocation size** RouterOS hands
  back per `from-pool=` request, **not a hint to the ISP**. Earlier
  probe used `60` and Monkeybrains delegated `/56` regardless.
- `accept-prefix-without-address=yes` matters: the probe showed
  Monkeybrains delegates prefix-only with no IA_NA address.
- `use-peer-dns=no` because resolver is the router itself; clients
  learn it via RDNSS from Phase A.

### 2. Per-VLAN GUA from the pool

For each of `vlan88`, `vlan10`, `vlan20`, `vlan30`, add:

```
/ipv6 address add address=::1 from-pool=mb-pd interface=vlanN advertise=yes
```

The `::1` interface-id lives inside whichever `/64` the pool hands out,
regardless of parent-prefix length. Re-derives automatically on
renewal.

### 3. DNS

Continue to publish only the ULA AAAA from Phase A. No GUA AAAA per
VLAN — pool-derived `/64`s aren't human-stable across renewals.

### 4. Default IPv6 route

`add-default-route=yes` on the DHCPv6 client installs `::/0`. Verify
with `/ipv6 route print` and a `ping6` to a global target.

### Phase B-MB checklist

- [ ] Probe 1 (`from-pool=` syntax) and probe 3 (renewal hygiene)
      confirmed on the live router.
- [ ] `/ipv6 dhcp-client print detail` shows `bound`, `mb-pd` populated.
- [ ] `/ipv6 address print` shows per-VLAN GUA derived from `mb-pd`.
- [ ] `::/0` present in `/ipv6 route print`.
- [ ] `ping6 google.com` from each SSID succeeds, with source from the
      `mb-pd` `/64`.

## Phase C — Sonic-day: v4 multi-WAN + v6 dual-GUA together

Bundled milestone, triggered when Sonic is provisioned. The shared
machinery (Netwatch, mangle marks, routing tables) is built once and
both protocols hook into it. Detailed config is written against the
actual Sonic line specs at apply-day; this section captures the
**model**. **Run probe 2 from "Schema verification probe" before
applying this phase.**

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
- This is the eventual home of the deferred "per-SSID WAN failover
  routing" item from [`PLAN.md`](PLAN.md).

### v6 layer — preferred/allowed via RA timers

- Add `/ipv6 dhcp-client` on `sfp-sfpplus1` mirroring `mb-pd`,
  `pool-name=sonic-pd`.
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

- [ ] Probe 2 (`/ipv6 nd prefix` per-prefix preferred-lifetime override)
      confirmed.
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

## Schema verification probe

Some load-bearing RouterOS bits weren't covered by the earlier PD
probe and need sanity-checking on the live router with the same
probe-then-revert pattern (`comment="probe-only-remove-after"`,
`/export hide-sensitive` diff before/after).

| # | What to confirm                                                                                                | Gates       | Why                                                            |
|---|----------------------------------------------------------------------------------------------------------------|-------------|----------------------------------------------------------------|
| 1 | `/ipv6 address from-pool=mb-pd address=::1 interface=vlan10` is accepted; resulting addr is `<pool-/64>:1/64`  | Phase B-MB  | B-MB depends on this exact form.                               |
| 2 | `/ipv6 nd prefix` accepts per-prefix `preferred-lifetime` overrides (incl. `=0`); a script-driven flip emits a fresh RA promptly | Phase C     | RA-timer model is load-bearing for v6 failover.                |
| 3 | `/ipv6 dhcp-client renew` re-derives `from-pool=` addresses; LAN clients see new RA with new prefix and the old one deprecated | Phase B-MB  | Renewal must not strand LAN clients.                           |

If probe 2 fails, the fallback for Phase C is **full-RA-replacement**
in the Netwatch script (delete + re-add `/ipv6 nd prefix` entries for
the affected VLAN). Less elegant, same outcome.

Hygiene: all probes use `comment="probe-only-remove-after"` and are
removed before any `/export` is captured into `snapshots/`. Nothing
lands in `config.rsc` from these probes.

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

## Where to edit `config.rsc` (per phase, future applies)

Each phase lands as its own apply via the wipe-and-replay flow in
[`README.md`](README.md): stage file, `:parse` pre-flight, reset +
import, confirm `config.rsc: done` in the log.

**Phase A insertion order:**

1. After IPv4 `/ip address` block (`config.rsc:126–130`): `/ipv6
   address` ULA `::1/64` per VLAN.
2. Near `/ip dns static` (`config.rsc:211–212`): AAAA for `router.lan`.
3. After `/ipv6 firewall filter` defconf rules (`config.rsc:253–277`):
   the four inter-VLAN drops, ahead of the broad LAN drop.
4. New `/ipv6 nd` block, after addresses exist on each VLAN.

**Phase B-MB additions:**

5. After WAN `/ip dhcp-client` block (`config.rsc:204–206`): `/ipv6
   dhcp-client` for `ether2` with `pool-name=mb-pd`.
6. Update Phase A `/ipv6 address` entries: add a parallel
   `from-pool=mb-pd address=::1 advertise=yes` entry per VLAN
   (alongside the ULA `::1/64`, not replacing it).

**Phase C additions:**

7. `/ipv6 dhcp-client` for `sfp-sfpplus1` with `pool-name=sonic-pd`.
8. Second per-VLAN `/ipv6 address from-pool=sonic-pd` entry.
9. Routing tables (`/routing table`), Netwatch (`/tool netwatch`),
   mangle marks (`/ip firewall mangle`, `/ipv6 firewall mangle`),
   `/ipv6 nd prefix` per-prefix `preferred-lifetime` overrides, and
   the up/down scripts (`/system script`).

## Verification (per phase)

**Phase A:**

```
/ipv6 address print
/ipv6 nd print
/ipv6 firewall filter print
```

From a vlan10 client: `ping6 fdXX:XXXX:XXXX:88::1` succeeds. From a
vlan20 client: `ping6 fdXX:XXXX:XXXX:30::<iot>` fails (guest → iot
blocked).

**Phase B-MB:**

```
/ipv6 dhcp-client print detail
/ipv6 pool print
/ipv6 address print
/ipv6 route print
```

From any SSID: `ping6 2606:4700:4700::1111` and `ping6 google.com`
succeed; `ip -6 addr` on the client shows a GUA in the `mb-pd` `/64`.

**Phase C:**

- v4: `traceroute` from a vlan10 client to `8.8.8.8` shows Sonic as
  first ISP hop; from vlan20/30/88 shows Monkeybrains. Pull Sonic
  cable: vlan10 traffic reroutes via Monkeybrains within Netwatch's
  probe window.
- v6: `ip -6 addr` on a client shows three addresses on the VLAN
  (ULA + `mb-pd` GUA + `sonic-pd` GUA), one of the GUAs marked
  deprecated. New `ping6` flows source from the preferred prefix.
  Pull primary WAN: RA timers flip within one RA interval; new flows
  source from the surviving prefix.

## Risks

- **`/ipv6 nd prefix` per-prefix `preferred-lifetime` override
  syntax** is load-bearing for the v6 failover model; verified by
  probe 2 above. If RouterOS 7.21.4 doesn't expose it cleanly, fall
  back to full-RA-replacement in the Netwatch script.
- **RA propagation latency** during failover — clients learn flipped
  preference on the next RA. Tighten `min-rtr-adv-interval`
  (15–30s) on the affected VLANs for faster recovery; don't go too
  low or RA traffic itself becomes a noise source.
- **Phase C bundles a lot.** v4 multi-WAN routing is a significant
  design in its own right (deferred by `PLAN.md`). The optional
  C-v4/C-v6 split above mitigates.
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
