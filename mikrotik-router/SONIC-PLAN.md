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
    S3["Stage 3: v6 dual-GUA + source-PBR<br/>+ipv6 address from-pool=sonic-pd per VLAN<br/>+ipv6 nd prefix preferred-lifetime overrides<br/>+ipv6 firewall mangle (src-address PBR)"]
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
- v6 dual-GUA: every VLAN gets a `/64` from each pool; RFC 6724 source
  selection biased by per-prefix `preferred-lifetime` overrides.
- v6 PBR: `mark-connection` on `src-address` matching pool prefixes
  (load-bearing — without it, MB BCP38-drops sonic-pd-sourced packets).
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

### Why source-based PBR, not mangle (post-mortem of v1–v4)

The first design used `/ip firewall mangle` to mark connections by
source VLAN, then mark routing by connection-mark. That broke
plumtree v4 reproducibly across four apply attempts. Three distinct
bugs we found:

1. **`/routing table fib=yes` aborts the import** (v1 + v2; see above).
   Independent of the PBR mechanism. Carries forward into v5.
2. **`/ipv6 dhcp-client add-default-route` defaults to `no` on 7.21.4**
   (Stage 1 v1). Independent of PBR. Carries forward into v5.
3. **The mangle mark-routing PBR scheme itself broke return traffic.**
   This is what made us abandon the mangle approach:

   - **3a.** A plumtree-marked packet to a LAN dst (e.g., DNS to
     `192.168.10.1` or inter-VLAN to `192.168.88.x`) had routing-mark
     set, lookup happened in the marked table (sonic or mb), which only
     contained `0.0.0.0/0` to a WAN — packet egressed the WAN with a
     private-IP destination and was dropped upstream. Killed DNS from
     plumtree → "internet broken" symptom. We added
     `dst-address-list=!LAN-SUBNETS` to the mark-routing rule to keep
     LAN dsts out of the marked path.
   - **3b.** Reply traffic also ended up with the routing-mark applied
     via conntrack (RouterOS appears to carry the mark forward from
     the initial direction to the reply direction). The reply,
     NAT-reversed to a LAN dst, looked up in the sonic table, matched
     `0.0.0.0/0` → Sonic gateway, egressed back out Sonic with a
     private-IP destination, and was dropped upstream. Mac never saw
     replies. Conntrack showed `SEEN-REPLY orig-packets=N
     repl-packets=N` for every ping that timed out at the Mac.
   - **3c.** We tried adding LAN connected routes (`192.168.X.0/24 ->
     vlanX`) to the sonic and mb tables on the theory that LPM
     within the table would catch LAN dsts before the `0.0.0.0/0`
     fallback. That *also* didn't work — `print detail` showed our
     static routes had `scope=30 target-scope=10` (RouterOS default
     for static) while main's connected routes had
     `scope=10 target-scope=5`, and either the LPM ignored the
     entry or returned it in a state that didn't actually forward.
     We never figured out exactly why, because disabling pass-2
     mark-routing entirely restored connectivity immediately, and
     `/routing rule` source-based PBR sidesteps the whole question.

`/routing rule` source-based PBR works because it **never sets a
routing-mark**. The routing decision happens with no mark, against
whichever table the rules select. Reply packets have a non-LAN source
address (the remote endpoint), so they bypass the src rules and fall
through to `main` — where the connected LAN routes have always
worked. Validated 2026-05-22 via live probe on the router; plumtree
ping to `1.1.1.1` went out Sonic with replies arriving back at the
Mac in 9–65 ms, while LAN and inter-VLAN traffic stayed unaffected.

## Stage 3 — v6 dual-GUA per VLAN

**Goal:** v6 follows v4 per-SSID routing in steady state. Source-PBR
ensures clients sending from the "wrong" GUA still egress via the matching
WAN.

### `config.rsc` changes

- `/ipv6 address`: parallel to the existing `from-pool=mb-pd` entries
  (lines 261–264), add `from-pool=sonic-pd advertise=yes` for vlan88,
  vlan10, vlan20, vlan30. Both pools advertise simultaneously; clients
  SLAAC one GUA per pool per VLAN.

- `/ipv6 nd prefix`: per-prefix `preferred-lifetime` overrides
  (probe 2 of 2026-05-07 already confirmed the schema):

  | VLAN   | `mb-pd` preferred-lifetime | `sonic-pd` preferred-lifetime |
  |--------|----------------------------|-------------------------------|
  | vlan10 | `0s` (deprecated)          | default (preferred)           |
  | vlan20 | default (preferred)        | `0s` (deprecated)             |
  | vlan30 | default (preferred)        | `0s` (deprecated)             |
  | vlan88 | default (preferred)        | `0s` (deprecated)             |

  `valid-lifetime` stays default on all — non-preferred prefixes are
  still routable for inbound, just not picked by RFC 6724 for outbound.

- `/ipv6 firewall mangle`: prerouting source-prefix marks, two-pass
  pattern mirroring v4. Pass 1 marks the connection by `src-address`
  matching the literal pool prefix observed in Stage 1 (`mb-pd` `/56`
  today, `sonic-pd` length per Stage 0/1); pass 2 mark-routings from
  the connection-mark. **Mandatory, not a safety net** — Stage 2's v4
  in-interface PBR rules don't fire on v6 (separate filter tables), so
  without v6 source-PBR a vlan10 client sending from its `mb-pd` GUA
  egresses via Sonic and gets BCP38-dropped.

  **Doc sync:** `IPV6-PLAN.md` § Phase C v6 layer currently calls
  source-PBR a "safety net" (line 332 of that file). Update wording to
  "mandatory" during this apply so the design doc matches reality.

- v6 fasttrack exclusion is already covered by the Stage 2 edit to the
  v6 fasttrack rule at line 327.

### Revert tarpit

Reverting Stage 3 without prep strands clients with `sonic-pd` GUAs at
default `valid-lifetime` (≈4w2d). With Stage 2's in-interface PBR and
no v6 source-PBR, packets sourced from those stale GUAs route via
vlan-PBR and BCP38-drop. RFC 6724 fallback recovers in seconds for new
flows but in-flight TCP tarpits.

**Revert procedure:** on the live router, set both pools'
`preferred-lifetime` AND `valid-lifetime` to `0s` on every VLAN; wait
one RA interval (≈2–10 min, faster if Stage 4 already tightened it) so
clients drop the addresses; THEN apply the Stage-2 `config.rsc`.

### Verify

- `ip -6 addr` on a plumtree client: three v6 addresses (ULA, `mb-pd`
  GUA deprecated, `sonic-pd` GUA preferred).
- `curl -6 ipinfo.io` from plumtree → Sonic ASN (sourced from
  `sonic-pd`). From guest/iot/mgmt → MB ASN (sourced from `mb-pd`).
- Mangle counters in `/ipv6 firewall mangle print stats` increase.
- Pull Sonic SFP: plumtree v6 breaks until next RA — Stage 4 closes
  this. v4 still falls through cleanly per Stage 2.

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
