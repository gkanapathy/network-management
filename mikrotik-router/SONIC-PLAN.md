# Sonic WAN buildout — staged plan

## Context

Sonic is delivered to the rb5009 on `sfp-sfpplus1` (link up). Monkeybrains
stays live on `ether2`. Today `sfp-sfpplus1` is unconfigured
(`config.rsc:9` calls it out), so every flow still egresses MB.

End state, already designed in
[`IPV6-PLAN.md` § Phase C](IPV6-PLAN.md):
per-SSID WAN selection (plumtree → Sonic primary, guest/iot/mgmt → MB
primary), v6 dual-GUA per VLAN biased by RA `preferred-lifetime`, and
Netwatch-driven failover both directions. The model is sound and the
schema probes (1, 2, 3) on 2026-05-07 already de-risked it.

The work is too large for one apply. This plan stages it into **four
applies**, each via the wipe-and-replay flow in [`README.md`](README.md)
and each independently testable and revert-safe.

```mermaid
flowchart TD
    S0["Stage 0 (pre-apply): live-router schema probes<br/>verify ipv6 dhcp-client default-route-distance,<br/>routing-mark+connection-mark interaction with fasttrack,<br/>check-gateway behavior. Capture Sonic PD length + gateway facts."]
    S1["Stage 1: Sonic as PASSIVE secondary<br/>+ ipv6 dhcp-client sonic-pd, +ip dhcp-client sfp-sfpplus1<br/>+sfp-sfpplus1 to WAN list<br/>NO per-VLAN PBR, NO sonic-pd /64s on VLANs"]
    S2["Stage 2: v4 per-SSID PBR (source-based)<br/>+routing tables mb, sonic<br/>+manual 0.0.0.0/0 routes per table (distance 1 & 2)<br/>+manual ::/0 routes per table<br/>+/routing rule (dst-LAN priority + per-VLAN src)<br/>Both DHCP clients switch to add-default-route=no"]
    S3["Stage 3: v6 dual-GUA + source-PBR<br/>+ipv6 address from-pool=sonic-pd per VLAN<br/>+/routing rule v6 chain (dst-LAN + per-pool src)<br/>(per-VLAN preferred-pool biasing deferred; see post-mortem)"]
    S4["Stage 4: Netwatch + RA-timer flip<br/>+netwatch mb-probe, sonic-probe (per-table)<br/>+scripts mb-up/down, sonic-up/down<br/>+scheduler reconcile from route state<br/>tighten min-rtr-adv-interval"]
    Verify1["Verify: MB still primary on all SSIDs.<br/>Pull MB: Sonic active. v6 degraded (no sonic-pd GUAs yet) — expected."]
    Verify2["Verify: plumtree v4 egresses Sonic; others MB.<br/>Pull either WAN: per-SSID fall-through within check-gateway window."]
    Verify3["Verify: clients carry ULA + mb-pd + sonic-pd.<br/>Default-preferred GUA matches v4 routing per VLAN.<br/>Pull primary WAN: v6 broken on that VLAN until next RA — Stage 4 closes."]
    Verify4["Verify: v6 failover matches v4 within one RA interval.<br/>Reconciler re-asserts state after manual mis-set."]
    S0 --> S1 --> Verify1 --> S2 --> Verify2 --> S3 --> Verify3 --> S4 --> Verify4
```

The gates between stages aren't decoration — Stage 3 needs Stage 1's
actual PD length and prefix to write source-PBR rules; Stage 4 needs
Stages 2 + 3 settled to flip timers meaningfully.

## Final design (reference)

Already documented at [`IPV6-PLAN.md` § Phase C](IPV6-PLAN.md). Key
points reused below — don't restate the model, only deltas.

- Two routing tables (`mb`, `sonic`); each carries both `::/0` and
  `0.0.0.0/0` with local WAN d=1, other WAN d=2.
- v4 PBR: per-VLAN source via `/routing rule` (with a dst=LAN-priority
  rule first, so reply + inter-VLAN traffic always uses `main`).
- v6 dual-GUA: every VLAN gets a `/64` from each pool. RFC 6724 source
  selection bias per-VLAN is NOT YET IMPLEMENTED — the original
  preferred-lifetime override design hit a RouterOS 7.21.4 constraint
  (`set` rejected on dynamic `/ipv6 nd prefix` entries). See Stage 3
  for the post-mortem and alternatives.
- v6 PBR: `/routing rule` source-based per pool (same shape as v4),
  with dst-LAN priority rules. Routing-mark is never set, so the
  conntrack-stickiness trap that broke Stage 2 v1–v4 doesn't apply.
- Netwatch + scripts flip RA timers on WAN-down → next-RA migration.
  v4 failover is router-side route-distance, immediate.

## Stage 0 — pre-apply schema probes (live router, no `config.rsc` edits)

The probes from 2026-05-07 covered Phase B / C v6 schema but NOT these
Sonic-day specifics. Run these on the live router (probe-then-revert,
`comment="probe-only-remove-after"`, same hygiene as IPV6-PLAN.md §
Schema verification probe). They produce facts the later stages encode.

| Probe | Question | How |
|-------|----------|-----|
| **A** | Does `/ipv6 dhcp-client` accept `default-route-distance=N`? | Try `set [find pool-name=mb-pd] default-route-distance=1`. If accepted, Stage 1's manual `::/0` route disappears — use the property instead. If rejected, the draft's manual-route plan stands. |
| **B** | Does `routing-mark` set in mangle prerouting correctly steer marked conns when fasttrack is active? | Add a no-op `mark-routing` rule on a test VLAN, watch counters. Confirms whether the `connection-mark=no-mark` fasttrack predicate is actually needed (it is, but verify on 7.21.4). |
| **C** | What does `check-gateway=ping` do against a DHCP-bound `0.0.0.0/0` route on `ether2` today? | Temporarily add `check-gateway=ping` to MB's existing default route via `/ip route`. Watch behavior when MB upstream is pinged; restore. Validates the Stage-2 monitoring assumption. |
| **D** | What does Sonic actually deliver? PPPoE vs DHCP? IA_NA + IA_PD or PD-only? PD length? | Add `/ip dhcp-client` and `/ipv6 dhcp-client` (pool-name=`sonic-pd-probe`) on `sfp-sfpplus1`, observe. Record the v4 gateway literal IP, v6 upstream link-local, and PD length. Remove before exporting. |

**Outputs captured for downstream stages:**

- Sonic delivery model (DHCP/IPoE vs PPPoE — if PPPoE, Stage 1's `ip
  dhcp-client` becomes `/interface pppoe-client` and the v4 plan shifts).
- Sonic PD length (drives Stage 3's per-VLAN /64 sizing; `/64` or no PD
  trigger the edge-case rows in IPV6-PLAN.md's table).
- Sonic v4 next-hop literal IP (Stage 2 `check-gateway`).
- Sonic v6 upstream link-local `fe80::…%sfp-sfpplus1` (Stage 1 manual
  ::/0 route if probe A says manual route is needed; Stage 2 manual ::/0
  routes per table unconditionally).
- Sonic-delivered v4 + v6 resolvers (recorded; no `config.rsc` impact —
  `use-peer-dns=yes` defaults already cover it).

### Stage 0 probe results — 2026-05-21: completed

All four probes plus one follow-up (`E`) ran in a single SSH session
with `comment="probe-only-remove-after"` hygiene; revert verified
(`/ip dhcp-client`, `/ipv6 dhcp-client`, and `/ip firewall mangle`
empty of probe artifacts before exit).

**Probe A — `/ipv6 dhcp-client default-route-distance` (and
`default-route-tables`) both exist on RouterOS 7.21.4.** `print detail`
of MB's bound entry showed `default-route-distance=1
default-route-tables=default`. Same properties on `/ip dhcp-client`.
Stage 1's manual-`::/0`-route fallback is no longer needed — use the
property directly. **Gotcha discovered at first Stage 1 apply
(2026-05-21):** on `/ipv6 dhcp-client`, `add-default-route` defaults
to `no` — unlike `/ip dhcp-client` where it defaults to `yes`. Setting
`default-route-distance=N` is necessary but NOT sufficient; both
clients must also explicitly set `add-default-route=yes`. The print
detail suppresses `default-route-distance` when
`add-default-route=no`, which is what made the omission silent.

**Probe B — counters tick on prerouting; fasttrack-bypass
inconclusive.** A passthrough rule on
`chain=prerouting in-interface=vlan10` counted 199 pkts / 142 KB
over 25 s of ambient vlan10 traffic. The probe shape couldn't
distinguish "new-conn only" from "all packets including fasttracked,"
so the underlying question stays open. The `connection-mark=no-mark`
defensive predicate on Stage 2's fasttrack rule stays — verify
end-to-end during Stage 2.

**Probe C — MB upstream `162.217.74.129` answers ICMP at ~7 ms (3/3,
no loss).** Stage 2's `check-gateway=ping` against the literal IP is
viable for MB. Sonic equivalent (`23.93.120.1`) untested until Stage 1
apply binds the Sonic line in production; record at apply-time.

**Probe D — Sonic delivers DHCP/IPoE with IA_NA + IA_PD /56.**

| Stratum | Value |
|---------|-------|
| Delivery model | DHCP/IPoE (not PPPoE) |
| v4 address | `23.93.121.192/21` (rotates on lease — never encode in `config.rsc`) |
| v4 next-hop | `23.93.120.1` (Stage 2 `check-gateway=ping` target) |
| v4 DNS (peer) | `50.0.1.1`, `50.0.2.2` (lands in `/ip dns dynamic-servers` via `use-peer-dns=yes`) |
| v6 IA_NA address | `2001:5a8:601:2b::2:1ba2` (Sonic delivers an address as well as a prefix; MB is PD-only) |
| v6 IA_PD prefix | `2001:5a8:6a4:d500::/56` (rotates — 256 /64s, same length as MB) |
| v6 upstream LL | `fe80::5e5e:abff:feda:ebc0%sfp-sfpplus1` |
| Lease length | 6h (both v4 and v6) |

Sonic's IA_NA-bearing behavior (vs MB's PD-only) means `sfp-sfpplus1`
gets a literal v6 address from Sonic on bind.
`accept-prefix-without-address=yes` is harmless either way — keep it
so the same config shape handles both ISPs.

**Probe E (follow-up) — `default-route-tables=` is single-value, NOT
a comma-separated list.** Attempting
`default-route-tables=main,probe-test` raised
`input does not match any value of table-default`. So Stage 2's "rip
out DHCP-installed routes, install manual routes per (table × WAN)"
approach is still required — there is no shortcut via multi-table
DHCP-installed routes. Probe also confirmed `default-route-tables=default`
maps to the `main` table (the resulting route landed in `main`).

## Stage 1 — Sonic as passive secondary WAN

**Goal:** Sonic binds v4 + v6, joins WAN interface-list, but does not
attract traffic in steady state. Everything still egresses MB.

### `config.rsc` changes

- Topology comment at top (line 9): `sfp-sfpplus1  WAN (sonic, DHCP
  client)`.
- `/ip dhcp-client` (after current `add interface=ether2` at line 239):
  `add interface=sfp-sfpplus1 default-route-distance=2 use-peer-dns=yes`.
  MB stays default (distance 1).
- `/ipv6 dhcp-client` (after current MB entry at line 251):
  `add interface=sfp-sfpplus1 request=address,prefix pool-name=sonic-pd
  pool-prefix-length=64 accept-prefix-without-address=yes
  add-default-route=yes default-route-distance=2`. The
  `add-default-route=yes` is required — `/ipv6 dhcp-client` defaults
  it to `no` (Probe A gotcha discovered at first apply). No manual
  `::/0` route needed.
- `/interface list member`: `add interface=sfp-sfpplus1 list=WAN` after
  the existing ether2 entry at line 123. This brings Sonic under the
  existing input drop, forward "WAN-originated non-DSTNATed" drop, and
  masquerade — all use `in-interface-list=WAN` / `out-interface-list=WAN`
  already, so no other edits needed.
- **No** `/ipv6 address from-pool=sonic-pd` on VLANs. Stage 1 must be
  observably "MB everywhere" until Stage 3.

### Verify

- `/ip dhcp-client print` — Sonic bound, IPv4 + gateway captured.
- `/ipv6 dhcp-client print detail` — Sonic bound, prefix shown, length
  matches Stage 0 probe D. `sonic-pd` pool populated.
- `/ip route print where dst-address=0.0.0.0/0` — two routes; MB d=1
  active, Sonic d=2 inactive.
- `/ipv6 route print where dst-address=::/0` — same shape.
- From plumtree: `curl -4 ipinfo.io` and `curl -6 ipinfo.io` both show
  MB — `AS32329` (org appears as `Another Corporate ISP, LLC`,
  Monkeybrains' registered name), reverse-DNS
  `*.public.monkeybrains.net`, v6 in `2607:f598:d488::/47`. The
  hostname is the unambiguous signal.
- Failover smoke test: unplug MB ether2. Within ~10s, Sonic v4 route
  activates and `curl -4 ipinfo.io` returns Sonic ASN. v6 traffic
  partially breaks because clients still hold only `mb-pd` GUAs — this
  is the gap Stage 3 closes; record it in the apply notes. Re-plug,
  traffic reverts.

### Stage 1 smoke-test results — 2026-05-21: completed

Two software-disable failover/recovery cycles via `/interface set
ether2 disabled=yes/no`, plus a physical cable-pull cycle for parity:

- **Failover and recovery both converge in ~6 s for v4 AND v6.** v6
  client-side recovery is automatic — no `/ipv6 dhcp-client renew`
  workaround needed in Stage 4's WAN-up script. (First trial saw a
  slower v6 recovery and a manual renew was run; second trial without
  the renew recovered in ~6 s, confirming the lag was a post-apply
  transient.)
- **BCP38 drop on v6 during MB outage confirmed empirically.** Mac
  on plumtree (sourcing from `2607:f598:d488:6101:...` MB-pd GUA)
  saw `curl -6 ipinfo.io` time out while Sonic was the only active
  v6 default; Sonic upstream dropped the foreign-source packets.
  This is the gap Stage 3's dual-GUA + source-PBR closes — the
  "mandatory, not safety net" call is now empirically backed.
- **Sonic delivered the literals captured at probe D**: v4
  `23.93.121.110/21` via `23.93.120.1`, AS46375 / `sonic.net`.
- **Physical cable-pull behaves identically to `disabled=yes`**, with
  two cosmetic differences worth knowing about for diagnosis: (a) the
  MB dhcp-client transitions to `status=stopped` with an "Interface
  not active" comment and the MB default route is *removed entirely*
  from the RIB (vs `disabled=yes` which kept the dhcp-client entry
  visible and the route as inactive); (b) recovery on cable replug
  was under ~2 s end-to-end (link up + DHCPDISCOVER + route reinstall
  + Mac's curl returning MB), faster than software-disable. ISP-side
  lease-cache likely answers a fresh DISCOVER immediately. Same v6
  BCP38 gap during the outage window.

## Stage 2 — v4 per-SSID PBR (source-based, via `/routing rule`)

**Goal:** plumtree v4 egresses Sonic; guest/iot/mgmt v4 egress MB.
Symmetric failover via `check-gateway` + route distance.

**Design: source-based PBR.** This stage went through four mangle-based
revisions (v1–v4) that all broke plumtree v4 connectivity in
reproducible ways. The mangle approach got abandoned; v5 uses
`/routing rule` matching on source address instead. See post-mortem
below for what went wrong.

This stage is **not purely additive**: both DHCP clients (v4 + v6, both
WANs) switch to `add-default-route=no`, and *all* defaults get installed
manually so each routing table is complete. The wipe-and-replay flow
keeps the live transition clean; the diff vs Stage 1 will yank the
DHCP-installed routes that Stage 1 relied on.

### `config.rsc` changes

- `/routing table`: `add name=mb fib`, `add name=sonic fib`. (NOT
  `fib=yes` — RouterOS 7.21.4 treats `fib` as a flag, not a boolean
  property; the assignment form parses as "expected end of command",
  aborts the import script, and skips the rest of `config.rsc` —
  including `vlan-filtering=yes` at the bottom, which locks plumtree
  out from the router. Discovered the hard way on the first two
  Stage 2 apply attempts, 2026-05-21.)
- Both v4 DHCP clients: `add-default-route=no`. They still bind
  addresses and the gateway is readable from `/ip dhcp-client`; we
  install all defaults manually so each table can carry both ISPs.
- Both v6 DHCP clients: `add-default-route=no`. Stage 1's
  `default-route-distance=2` on the Sonic client gets replaced (the
  client installs no route at all); manual `::/0` entries below cover
  all three tables.
- `/ip route` — six `0.0.0.0/0` entries (3 tables × 2 WANs):

  | Table  | Gateway          | Distance | `check-gateway` |
  |--------|------------------|----------|-----------------|
  | `main` | MB next-hop IP   | 1        | `ping`          |
  | `main` | Sonic next-hop IP| 2        | —               |
  | `mb`   | MB next-hop IP   | 1        | `ping`          |
  | `mb`   | Sonic next-hop IP| 2        | —               |
  | `sonic`| Sonic next-hop IP| 1        | `ping`          |
  | `sonic`| MB next-hop IP   | 2        | —               |

  Gateway is the literal next-hop IP captured in Stage 0/1, not the
  interface — `check-gateway` against a DHCP-bound interface pings the
  resolved DHCP server, which the ISP may not answer; pinging the
  literal next-hop is more reliable.

- `/ipv6 route` — same 6-row shape with `dst-address=::/0`, gateways as
  the upstream link-locals (`fe80::…%ether2`, `fe80::…%sfp-sfpplus1`).
  RouterOS v6 routes accept `check-gateway` on 7.x; use `ping`
  mirroring v4.

- `/routing rule` — five rules, processed in order:

  ```
  add dst-address=192.168.0.0/16  action=lookup table=main  comment="LAN dsts -> main"
  add src-address=192.168.10.0/24 action=lookup table=sonic comment="plumtree -> sonic"
  add src-address=192.168.20.0/24 action=lookup table=mb    comment="guest -> mb"
  add src-address=192.168.30.0/24 action=lookup table=mb    comment="iot -> mb"
  add src-address=192.168.88.0/24 action=lookup table=mb    comment="mgmt -> mb"
  ```

  Rule 1 catches reply traffic (NAT-reversed dst = LAN client) AND
  inter-VLAN traffic BEFORE the per-VLAN src rules fire, so those
  always route via `main`'s connected LAN routes. Rules 2–5 steer
  outbound LAN-to-WAN traffic to the right table by source subnet.
  Reply packets don't match the src rules because their src is the
  remote endpoint (not a LAN address). Router-originated traffic
  takes its source from the egress interface (typically a WAN IP),
  so it also doesn't match src rules and falls through to main.

- `/ip firewall nat`: existing masquerade (`out-interface-list=WAN`)
  needs no change; it NATs out whichever WAN a packet actually exits.
- **No mangle changes. No address-list. No fasttrack predicate
  changes.** The mangle/conntrack PBR pattern from v1–v4 is dropped
  entirely — see post-mortem below.

### Verify

- `curl -4 ipinfo.io` from plumtree → Sonic ASN (`AS46375`); from
  guest/iot/mgmt host → MB ASN (`AS32329`).
- `traceroute -4` from each SSID confirms first ISP hop.
- `ping 192.168.10.1` from plumtree (LAN-to-router) succeeds — rule 1
  catches it.
- `ping 192.168.88.1` from plumtree (inter-VLAN) succeeds — rule 1
  catches it.
- Pull Sonic SFP: plumtree falls through to MB within `check-gateway`'s
  detection window. Restore: reverts to Sonic.
- Pull MB ether2: guest/iot/mgmt fall through to Sonic. Restore: reverts.

### Why source-based PBR, not mangle

Four v1–v4 attempts used `/ip firewall mangle` to mark connections by
source VLAN and mark routing by connection-mark. All broke plumtree
v4 reproducibly. Two RouterOS 7.21.4 properties combined to make the
mangle scheme unworkable:

- No longest-prefix-match across routing tables and no implicit
  fallback from a custom table to `main`. Once a packet has
  `routing-mark=X`, only table `X` is searched. A LAN-destined packet
  from a marked source ends up egressing the WAN with a private-IP
  destination.
- Conntrack carries the routing-mark from the initial direction to
  the reply direction. So even after scoping the mark to WAN-bound
  traffic, reply packets get the mark applied via conntrack, route
  via the custom table, and egress the WAN instead of the LAN client.

Source-based `/routing rule` never sets a routing-mark. Reply packets
have a non-LAN source so they bypass the src rules and fall through
to `main` — where the connected LAN routes always worked. See
[`README.md`](README.md) § Common pitfalls for the generalized
"mangle mark-routing PBR is a trap" entry.

### Stage 2 results — 2026-05-22: completed (v5)

Apply landed cleanly on the v5 design after the four mangle-based
attempts. Steady-state and failover both validated.

| Test | Result |
|------|--------|
| Plumtree → 1.1.1.1 (v4) | 5/5 at 13 ms avg, Sonic egress (`AS46375`) |
| Plumtree LAN-to-router (192.168.10.1) | 2/2, rule 1 routes via `main` |
| Plumtree inter-VLAN (192.168.88.1) | 2/2, rule 1 routes via `main` |
| Mac curl `-4` ipinfo | Sonic `23.93.121.110` / `sonic.net` |
| Mac curl `-6` ipinfo | MB GUA from `mb-pd` (v6 stays on MB — Stage 3 work) |

**Failover (software-disable cycles on each WAN):**

| Cycle | Behavior |
|-------|----------|
| Disable Sonic | sonic table: d=1 deactivates, **d=2 (MB) activates** within ~6 s. Plumtree curl returns MB. Other VLANs unaffected. |
| Re-enable Sonic | d=1 (Sonic) Active again — DHCP-rebind delay >8 s, slower than software-disable revert (matches Stage 1 cable-pull observation). |
| Disable MB | main + mb tables: d=1 deactivates, **d=2 (Sonic) activates**. Plumtree stays on Sonic (its primary). Router pings with `src=192.168.20.1` / `192.168.88.1` egress via Sonic at ~3 ms. |
| Re-enable MB | d=1 (MB) Active again, immediate. |

The per-table d=1/d=2 + `check-gateway=ping` machinery does its job
in both directions. No symmetric-loss event during failover; plumtree
maintains internet through any single-WAN outage.

**v6 caveat carried forward.** During an MB outage, plumtree clients
sourcing v6 from `mb-pd` GUA will be BCP38-dropped at Sonic upstream
(same Stage 1 / Stage 2 gap). Stage 3 dual-GUA closes it.

## Stage 3 — v6 dual-GUA per VLAN (source-based, via `/routing rule`)

**Goal:** v6 follows v4 per-SSID routing in steady state. Each VLAN
gets one GUA per ISP pool; clients prefer the matching primary pool by
`preferred-lifetime` bias; `/routing rule` source-PBR steers traffic
to the matching WAN regardless of which GUA the client picked.

**Design pivot from the SONIC-PLAN v1 draft:** original plan used
`/ipv6 firewall mangle` with source-prefix marks. Stage 2's v1–v4
attempts proved mangle `mark-routing` is a trap on RouterOS 7.21.4
(conntrack carries the mark to reply traffic, no LPM-across-tables,
no fallback to main; see [`README.md`](README.md) § Common pitfalls).
Stage 3 uses the same `/routing rule` source-based pattern that
shipped in Stage 2 v5 for v4.

### `config.rsc` changes

- **`/ipv6 address`**: parallel `from-pool=sonic-pd advertise=yes`
  entries on `vlan88`, `vlan10`, `vlan20`, `vlan30`, alongside the
  existing `mb-pd` entries. Clients SLAAC one GUA per pool per VLAN.
  Same `from-pool=`-without-`address=` shape verified by probe 1
  (2026-05-07).

- **Per-VLAN GUA preference biasing: not implemented in this stage.**
  The original plan was a `/system script` + `/system scheduler` that
  iterated `/ipv6 nd prefix set [find ...] preferred-lifetime=0s` to
  deprecate the non-primary pool's RA prefix per VLAN. **That doesn't
  work on RouterOS 7.21.4** — the `/ipv6 nd prefix` entries auto-
  derived from `/ipv6 address from-pool=...` are *dynamic*, and `set`
  on them fails with `failure: can not change dynamic prefix`. The
  earlier IPV6-PLAN.md probe 2 (2026-05-07) that said this works was
  testing a STATIC `/ipv6 nd prefix add` entry, which is a different
  case.

  Net effect: clients SLAAC both GUAs but pick a source per RFC 6724
  + OS heuristics (not biased toward each VLAN's primary WAN). Traffic
  still routes correctly via the `/routing rule` chain — whichever
  GUA a client picks, the matching pool's WAN is used. But the design
  intent of "plumtree primary on Sonic, others primary on MB" is not
  enforced at the steady-state level.

  Alternatives to revisit later (none of which got past the
  whiteboard in this stage):

  1. **`advertise=yes/no` toggle on `/ipv6 address from-pool=`.**
     Only advertise one pool per VLAN; clients SLAAC only that GUA.
     No dual-GUA safety net.
  2. **Static `/ipv6 nd prefix add` override** with the literal `/64`
     per VLAN per pool. Multiplies the rotation-bookkeeping problem
     by 4 (one entry per VLAN per pool).
  3. **Accept the limitation.** Current state — dual-pool routing
     works, no policy bias.

- **`/routing rule` v6 chain** — appended to the existing v4 rules
  from Stage 2:

  ```
  add dst-address=fd7f:aee1:6ce0::/48      action=lookup table=main  comment="v6 ULA LAN dsts -> main"
  add dst-address=2607:f598:d488:6100::/56 action=lookup table=main  comment="v6 MB-pd LAN dsts -> main"
  add dst-address=<sonic-pd /56>           action=lookup table=main  comment="v6 Sonic-pd LAN dsts -> main (UPDATE if PD rotates)"
  add src-address=2607:f598:d488:6100::/56 action=lookup table=mb    comment="v6 MB-pd src -> mb"
  add src-address=<sonic-pd /56>           action=lookup table=sonic comment="v6 Sonic-pd src -> sonic (UPDATE if PD rotates)"
  ```

  Same shape as v4: dst-LAN priority catches reply traffic before src
  rules fire, then per-pool src rules steer outbound. Reply packets
  have non-LAN src so they bypass the src rules and fall through to
  main (where the per-VLAN connected `/64`s deliver the packet).

- **No `/ipv6 firewall mangle` changes.** The earlier "mandatory v6
  source-PBR via mangle" design is abandoned. `/routing rule`
  source-based PBR replaces it.

- **Fasttrack unchanged from Stage 2 v5.** No `connection-mark=no-mark`
  predicate needed because no routing-mark is ever set.

### Why literal `/56`s instead of address-list

`/routing rule` on RouterOS 7.21.4 only accepts literal CIDR for
`src-address`/`dst-address` — `src-address-list=` is rejected
("expected end of command"). The natural workaround (use
`prefix-address-lists` on `/ipv6 dhcp-client` to dynamically populate
an address-list, then reference it in `/routing rule`) is closed off.

**Mitigation:** the literal Sonic-pd `/56` only needs updating if the
DHCPv6 client gets a new prefix on rebind. Routine renewal (T1/T2)
keeps the same prefix because our DUID is stable (driven by the
bridge `admin-mac` set in `config.rsc`). The `/56` only changes when
the dhcp-client entry is recreated — which happens on a full apply
(wipe-and-replay) or on interface flap. Practical workflow: before
each apply that touches the `/ipv6 dhcp-client` block, run
`ssh admin@192.168.10.1 '/ipv6 dhcp-client get [find pool-name=sonic-pd] prefix'`
and update the two `<sonic-pd /56>` literals in `/routing rule` if
they differ.

### Verify (applied 2026-05-22)

- `ip -6 addr` on a plumtree client: shows three v6 addresses (ULA,
  `mb-pd` GUA, `sonic-pd` GUA), both GUAs `valid` and `preferred`
  (no deprecation, since the bias mechanism isn't installed).
- `curl -6 ipinfo.io` from plumtree → returns whichever pool the
  client's RFC 6724 source-selection happens to pick. Observed
  on the apply-day Mac: `mb-pd` GUA (AS32329 MB). Routing-wise
  it's correct (mb-pd src → mb table → MB egress).
- `/ipv6 nd prefix print` — all pool-derived `/64`s show their
  default `preferred-lifetime` from the lease (no overrides
  applied).
- Pull Sonic SFP: clients with `sonic-pd` source flows lose v6
  connectivity until they happen to switch back to `mb-pd` source
  (no preferred-lifetime bias means slower convergence). v4 still
  falls through cleanly per Stage 2.

## Stage 4 — Netwatch + dynamic v6 preferred-lifetime flip

**Goal:** v6 failover symmetric with v4 — primary WAN down flips the
deprecated/preferred designation so clients migrate on the next RA.

### `config.rsc` changes

- `/tool netwatch`: two probes pinging the same external target through
  different tables.

  ```
  add comment=mb-probe    type=icmp host=1.1.1.1 routing-table=mb    \
      interval=10s timeout=2s up-script=mb-up    down-script=mb-down
  add comment=sonic-probe type=icmp host=1.1.1.1 routing-table=sonic \
      interval=10s timeout=2s up-script=sonic-up down-script=sonic-down
  ```

  Same target through both probes avoids target-side outages firing
  false WAN-down events.

- `/system script`: four scripts (`mb-up`, `mb-down`, `sonic-up`,
  `sonic-down`). Each sets `preferred-lifetime` on the affected
  `/ipv6 nd prefix` entries:

  - `sonic-down`: vlan10 flips — `sonic-pd` prefix → `0s`, `mb-pd`
    prefix → default. vlan20/30/88 untouched (their primary is MB,
    still up).
  - `sonic-up`: vlan10 reverts to Stage-3 defaults.
  - `mb-down` / `mb-up`: symmetric for vlan20/30/88.

  Use `find` by prefix string (or by interface + pool reference,
  whichever is stable in 7.21.4 — verify the find selector at apply
  time; the prefix string changes on PD renewal, so find-by-interface
  + matching-pool-prefix is more robust).

- `/system scheduler`: a periodic reconciler (5–10 min interval) that
  reads route state (`/ip route get [find …] active` per table), not
  Netwatch status, and re-asserts the preferred-lifetime values.
  Route state is what actually matters for traffic; reading it
  side-steps Netwatch transient flap states. Belt-and-suspenders
  against a missed event.

- Tighten `/ipv6 nd` `min-rtr-adv-interval` on vlan10/20/30/88 to
  15–30s so RA-driven failover converges faster. Don't go too low or
  RA traffic becomes background noise.

### Verify

- Trigger `sonic-down` manually first (before pulling cable) — confirm
  `/ipv6 nd prefix print` shows the timer flip.
- Pull Sonic SFP: within `check-gateway` window v4 plumtree falls to
  MB; within one RA interval plumtree v6 clients see `sonic-pd`
  deprecated, `mb-pd` preferred; new `curl -6` sources from `mb-pd`,
  egresses via MB.
- Restore. Within Netwatch's recovery interval, scripts revert.
- Reconciler: manually misset `preferred-lifetime` on one entry; wait
  the scheduler tick; confirm restoration.
- Symmetric story for MB pull.

## Critical files

- [`config.rsc`](config.rsc) — every stage edits this and re-applies
  via wipe-and-replay.
- [`IPV6-PLAN.md`](IPV6-PLAN.md) § Phase C — parent design doc; tick the
  Phase C checklist as each stage lands; update the "safety net" wording
  in Stage 3.
- [`../CLAUDE.md`](../CLAUDE.md) "What's next" — Sonic WAN buildout
  bullet collapses as stages land.
- [`snapshots/`](snapshots/) — pre-apply backups land here per the
  existing apply flow ([`README.md`](README.md) step 1).

## Reuse vs new code

- The existing `/interface list member` membership-driven WAN rules
  (input drop, forward drop, masquerade — at lines 283, 291, 301)
  already correctly handle multiple WANs. No new firewall infrastructure
  needed beyond mangle and the fasttrack predicate tweak.
- The wipe-and-replay flow in [`README.md`](README.md) (Apply
  section) is used unchanged for each stage's apply — including the
  `:parse` pre-flight, the post-reset SSH-host-key handling, and the
  IPv6 link-local recovery backdoor if a stage breaks v4.
- `from-pool=` semantics on `/ipv6 address` are already understood
  (probe 1, 2026-05-07): no `address=` argument, prefix-only-to-interface.
  Stage 3 uses the same form for `sonic-pd`.

## Sequencing notes

- Each stage is its own `scp config.rsc … && /system reset-configuration
  … run-after-reset=config.rsc` cycle. Brief outage (~60–90s) per apply.
- Verify Stage N for "at least a few hours / a day" in production before
  starting Stage N+1, so transient breakage on one stage doesn't
  compound into the next.
- Stage 1 is the riskiest in terms of "what does Sonic actually look
  like at the wire" — Stage 0 probes are non-negotiable.
- Stages 2 and 3 each leave a "primary-WAN-down → v6 partially
  degraded" gap until Stage 4 closes it. IPV6-PLAN.md's `C-v4` then
  `C-v6` split is exactly this trade-off; Stages 2+3 here are that same
  intermediate state.
- Keep `/ip ssh password-authentication=yes` (per the CLAUDE.md
  deferred-tightening note) until all four stages have settled. The
  password fallback stays the belt-and-suspenders while this work is
  active. Revisit when the buildout is done.
