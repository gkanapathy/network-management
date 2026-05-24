# rb5009 — lessons learned

Things we figured out the hard way while building out this setup.
Generalizable across RouterOS 7.x multi-WAN work; not necessary to
*operate* the shipped design but useful for understanding why it took
the shape it did, and for anyone extending or debugging it later.

## RouterOS 7.x

### Mangle `mark-routing` for per-source PBR is a trap

The intuitive way to do per-source policy-based routing on RouterOS
is `/ip firewall mangle` with `chain=prerouting` rules that set
`routing-mark=<table>` based on `src-address`. It doesn't work for a
multi-WAN+LAN topology, for two combined reasons:

1. **No longest-prefix-match across routing tables, no implicit
   fallback from a custom table to `main`.** Once a packet has a
   `routing-mark` set, only the matching table is searched. A
   LAN-destined packet from a marked source VLAN (e.g., DNS to the
   router, inter-VLAN traffic) follows the marked table's `0.0.0.0/0`
   to a WAN, gets masqueraded, and the upstream drops it with a
   private destination address.
2. **Conntrack carries the routing-mark to the reply direction.**
   Even if you scope the mark only to WAN-bound traffic, the reply
   packet *also* gets the mark applied (via conntrack), routes via
   the custom table, and egresses back out the WAN instead of to the
   LAN client. Conntrack shows `SEEN-REPLY orig-packets=N
   repl-packets=N` for every flow that times out at the client.

Adding LAN-connected routes to the custom tables doesn't reliably fix
(1) — static routes end up with `scope=30 target-scope=10` (vs
`scope=10 target-scope=5` on `main`'s auto-generated connected
routes), and the LPM-within-table didn't appear to use the static
entry.

**The right pattern: `/routing rule` source-based PBR.** A
source-address rule sets `action=lookup table=X`; no routing-mark is
involved, so conntrack stickiness doesn't apply. Reply packets bypass
the source rules because their src is the remote endpoint, not a LAN
address — they fall through to `main` where the connected LAN routes
always worked.

Put a `dst-address=192.168.0.0/16 action=lookup table=main` (or your
LAN supernet) priority rule *first* in the chain, so inter-VLAN and
LAN-to-router traffic also stays in `main`.

**Diagnosis trick** for "client outbound times out, conntrack shows
SEEN-REPLY": disable the mangle mark-routing rules; if connectivity
recovers immediately, you're hitting this trap. Pivot to `/routing
rule`.

Cost during Sonic Stage 2 buildout (2026-05-21..22): four attempts
(v1-v4) before pivoting to source-based PBR; multiple cold-bootstrap
recoveries to unbreak the router.

### Dynamic `/ipv6 nd prefix` entries reject `set`

`/ipv6 nd prefix` entries that are auto-created from `/ipv6 address
from-pool=...` are flagged dynamic (`D`). Attempting
`/ipv6 nd prefix set [find ...] preferred-lifetime=...` returns
`failure: can not change dynamic prefix`.

A static `add prefix=... interface=... preferred-lifetime=0s` accepts
`set` cleanly. **The distinction matters** because the same `:put
[find prefix=X]` queries return different entries depending on which
code path created them. Probe results that say preferred-lifetime
override "works" almost always tested the static path.

**On 7.21.4 there is no way to mutate a dynamic prefix entry directly.**
The mechanism for biasing RA on a from-pool interface is
`advertise=yes/no` on the parent `/ipv6 address` entry itself (which
IS settable). If you need a dynamic preferred-lifetime knob, the
alternative is per-VLAN-per-pool static `/ipv6 nd prefix add` entries
with computed /64 literals — at the cost of having to track prefix
rotation manually for each entry.

Drove the Sonic Stage 3 design pivot from "advertise both pools +
deprecate via preferred-lifetime" to "advertise only the primary
pool" (single-GUA-per-VLAN).

### `/system scheduler start-time=startup` doesn't fire on the current boot

A `/system scheduler add … start-time=startup` entry **only fires on
subsequent boots, not the boot during which the entry is being
created**. If your `config.rsc` adds such a scheduler and you rely on
it for apply-day bootstrap, you'll see `run-count=0` until the next
reboot.

Workarounds:
- `:execute { :delay 60s; /system script run … }` for a one-shot
  background invocation, OR
- Trigger the work via a different mechanism that doesn't depend on
  `start-time=startup` — e.g., `/ip dhcp-client script=` hooks fire
  naturally on first bind after apply.

### DHCPv6 client `script=` fires from multiple sub-events

`/ipv6 dhcp-client` has a single `script=` property, but it gets
invoked twice from different RouterOS subsystems on a fresh lease
bind: once labeled `dhcp-client/script` and once `dhcp-ia/script`,
within milliseconds. (Sonic delivers both IA_NA and IA_PD in the same
DHCPv6 reply; MB is PD-only but still triggers both.)

For find-then-add scripts, this races: both invocations see no
existing entry and both add → duplicate rules. Confirmed via the log:

```
23:49:22 added by dhcp-client/script:wan-reconciler (*9 = ...auto-v6-dst-mb-pd...)
23:49:22 added by dhcp-ia/script:wan-reconciler     (*A = ...auto-v6-dst-mb-pd...)
```

**Solution: declare the managed entries statically in `config.rsc`
with comment tags + bootstrap values; have the script only ever
`set` (never `add`).** Concurrent invocations both call `set` with
the same target value — idempotent at the kernel level, no
duplicates.

`$pd-valid` / `$pd-prefix` / `$na-valid` / `$na-address` script
variables tell you which sub-event you're in, but they don't help
prevent the race — they just tell you what already happened.

### `rp-filter=strict` + multi-WAN source-PBR is masked by conntrack-bypass

`rp-filter=strict` checks that an inbound packet's source would
route back via the same interface it arrived on; if not, drop. For a
multi-WAN setup where `main` defaults to one ISP but per-VLAN
`/routing rule` steers traffic out the other, **reply packets arrive
on a WAN that fails the strict check** — a literal-RFC reading says
drop.

In practice, established conntrack flows skip the strict recheck —
Linux/RouterOS treats them as "already validated earlier" — so most
reply traffic passes. Empirically (probed 2026-05-23) zero
martian-source log entries, zero observed drops, asymmetric pings
return 4/4. But this hides fragility:

- First-packet-of-flow on an asymmetric-return WAN would be dropped
  if conntrack didn't already know about it (e.g., unsolicited
  inbound, fragmented packets that miss reassembly, ICMP error types
  that miss tracking).
- The config is relying on conntrack-bypass to mask a deliberate
  asymmetry the kernel was told to forbid.

**Loose is correct for multi-WAN.** It still catches packets whose
src isn't reachable via *any* of your interfaces (the actual
anti-spoof / bogon role) but tolerates per-interface mismatch.

### Sonic's upstream BCP38-drops foreign-source v6

During Sonic Stage 1 smoke test (passive secondary, no PBR yet),
pulling MB's cable forced all traffic via Sonic. Plumtree clients
that had SLAAC'd a `2607:f598:d488:6101:...` (MB-pd) GUA tried to
egress via Sonic with that MB-prefix source — Sonic upstream dropped
them as foreign-source. The Sonic v6 default route was active, but
plumtree v6 timed out.

**Implication:** in a dual-WAN setup with both ISPs delegating
prefixes, source-based PBR for v6 isn't a "safety net" or "nice to
have" — it's *mandatory*. Each client's source GUA dictates which WAN
its traffic must egress; cross-routing gets BCP38-dropped at the
non-matching ISP's upstream.

This drove the Stage 3 design from "dual-GUA with hopeful
RFC-6724-based source selection" to "advertise only the matching
pool's GUA per VLAN, with source-PBR enforcing it server-side."

### Netwatch on 7.21.4 — what params actually exist

The Netwatch docs and many third-party guides list parameters that
turn out NOT to exist on 7.21.4:

- `routing-table=` — **no.** Probes can't be steered through a
  specific routing table directly. Use `src-address=` and rely on
  the `/routing rule` chain.
- `interface=` — **no.** Same story; use `src-address=`.
- `loss-threshold=` — **no.** The "require N consecutive probe
  failures before firing the down-script" knob isn't in 7.21.4. Any
  single failed probe fires immediately.
- `down-time=` / `test-script=` — **no.**

What IS there (verified by add-then-print-detail):

- `host`, `type`, `interval`, `timeout`, `src-address`, `packet-count`,
  `packet-interval`, `startup-delay`, `up-script`, `down-script`,
  `comment`, `disabled`.

Lesson: `/tool netwatch add ?` doesn't list params on 7.21.4
("expected end of command"). The reliable way to verify a param is
real is `:do { /tool netwatch add ... <param>=<value> }; print
detail` — if the param shows in the printed entry, it exists. The
`:do/on-error` wrapper alone doesn't catch parameter-name-rejection
cleanly enough.

Flap protection without `loss-threshold` is limited to multi-packet-
per-probe via `packet-count` + `packet-interval`. For our setup we
backstop it with a reconciler-driven self-heal pass that re-asserts
state on the 10m polling tick.

### Netwatch v4 probes can't detect WAN failure in a src-PBR setup with fallback

Naive design for per-WAN reachability monitoring: a `/tool netwatch`
entry probing `1.1.1.1` with `src-address=<a LAN IP that routes via
the named WAN>`. Relies on the `/routing rule` chain to steer the
probe through the named WAN's routing table.

Doesn't work when the routing table has a `d=2 <other-WAN>` fallback
(which it must, so client traffic on that VLAN still gets internet
when the primary WAN dies):

- Failed WAN's `d=1` invalidates (interface admin-down OR
  `check-gateway=ping` detects gateway dead) → `d=2` activates →
  probe egresses the *other* WAN.
- For v4: NAT masquerade rewrites the src on egress, so the probe
  arrives at `1.1.1.1` with a valid source IP regardless of which
  WAN it went out. Probe stays `up`. Failure invisible.
- Down-script never fires.

**Diagnostic**: disable a WAN's interface (`/interface set <wan>
disabled=yes`) and watch the netwatch entry's `since` timestamp.
If `since` doesn't move while the WAN is down, you're hitting this.

**Fix: v6 probe with foreign-source src.** Probe Cloudflare v6
anycast `2606:4700:4700::1111` with `src-address=<router's host GUA
in the named WAN's /56>`. Two layered detection mechanisms work
in combination:

1. **Egress filtering** (BCP38 on the other WAN, when present).
   Probe routes via the surviving WAN with src in the failed WAN's
   /56 — i.e., foreign-source from the surviving WAN's view. Some
   ISPs (empirically: Sonic does, Monkeybrains doesn't) drop
   foreign-source v6 on egress.
2. **Reply-path-broken** (works regardless of egress filtering).
   Even if the surviving WAN forwards the foreign-source packet
   and it reaches the target, the *reply* is destined for the
   failed WAN's /56 — which routes back via the failed WAN's
   announcement. With the failed WAN dead (link or upstream),
   reply gets dropped at the failed WAN's edge or earlier. Probe
   times out.

Either way, probe goes `down` → down-script fires. This mirrors
actual client traffic in the dual-WAN setup exactly: a client whose
preferred GUA is in the failed pool experiences the same failure
mode, so probe-up ⟺ "round-trip via this pool would succeed right
now" — the condition Stage 4 needs to detect.

**Implementation knobs**:

- Router needs a host GUA in each /56 for use as probe src. Use
  `/ipv6 address from-pool=X interface=vlanY eui-64=yes` to get one
  auto-derived from the bridge MAC. Host part stable; prefix tracks
  /56 rotation. (Static `/128` works too, but adds a reconciler
  surface for the address literal itself — `eui-64=yes` doesn't.)
- Reconciler must update netwatch `src-address=` on /56 rotation,
  since the prefix part of the GUA changes. (The address itself
  rotates inside the existing `/ipv6 address` entry; reconciler
  reads it and `set`s netwatch.)

Discovered + fixed 2026-05-23..24 (Bug A in the original Stage 4
design pass).

### Netwatch's script policy envelope is `{read,write,test,reboot}`

Netwatch invokes `up-script` / `down-script` as `*sys`, and its caller
envelope is exactly `{read, write, test, reboot}`. A script with ANY
additional policy (`policy`, `password`, `sniff`, `sensitive`, `ftp`,
`romon`) is refused with:

```
script,error could not run script <name>: not enough permissions
script,error executing script from netwatch failed, please check it manually
script,error,debug (netwatch:type: icmp, host: 1.1.1.1) not enough permissions to run script <name>
```

`/system script add` defaults to the full 10-policy set, which exceeds
that envelope — so out-of-the-box, a netwatch-invoked script always
fails the permission check. **Trim policy to the narrowest set the
script actually uses** (typically `read,write,test,reboot` for an
`/ipv6 nd prefix set` or similar config mutation):

```
add name=sonic-down policy=read,write,test,reboot source={ ... }
```

The error message is misleading — it reads as "the script lacks
permissions" but the actual cause is "the script HAS too many
permissions for the netwatch envelope". Same fix (trim policy) regardless.

Alternative: `/system script set ... dont-require-permissions=yes`
bypasses the check entirely, but the MikroTik docs explicitly call this
out as less secure than trimming policy; do the trim.

The form of `up-script=` doesn't matter — both bare `up-script=sonic-up`
and explicit `up-script="/system script run sonic-up"` work once policy
is correct. Both fail with the same error when policy is wrong.

Surfaced 2026-05-23 testing Sonic Stage 4 failover. The diagnostic
that pins the issue: `/system script run <name>` works from an admin
SSH session (run-count increments, side effects land) but fails from
netwatch context with the error above. That asymmetry rules out a
body-level bug and points straight at the caller envelope.

### `:local` variable names cannot contain underscores

`:local foo_bar 30m` errors with `Script Error: expected end of
command` on the underscore. The 7.21.4 parser treats `_` as a
statement-end of some kind. CamelCase or all-lowercase no-separator
works fine: `:local fooBar 30m` or `:local lifetimecap 30m`.

Not documented anywhere obvious; surfaced while building the
clamped lifetime reconciler.

### Bare `:return` in functions taking args errors on the next call

In a `:local fn do={...}` user-defined function on 7.21.4, **bare
`:return` (no value) errors out the script on the next invocation
of the function** if the function takes positional arguments via
`$1`/`$2`/etc. Error message: `Script Error: missing value(s) of
argument(s) value` — misleading because it points at "argument
values" when the actual issue is the return statement.

Reproduces with two-line minimum:

```
:local fn do={ :put ("arg=" . $1); :return }
$fn "a"  ; works
$fn "b"  ; Script Error: missing value(s) of argument(s) value
```

Fix: always `:return true` (or any value, doesn't matter what). The
caller doesn't have to consume it; just give `:return` an argument.

`:return value` works in all cases; bare `:return` may "work" by
luck if the function is called only once (or if the failing call
happens to be the LAST statement in the script body). The
wan-reconciler used bare `:return` for a while because its call
ordering happened to dodge the trap; rewrote to `:return true`
defensively after hitting it during the dual-GUA expansion.

### RouterOS interactive SSH scoping

When piping multiple commands via SSH stdin (heredoc, multi-line
ssh command, etc.), **each newline-separated statement is its own
RouterOS scope**. `:local` variables don't persist across newlines.

This bites ad-hoc multi-step probes:

```
ssh admin@router << 'EOF'
:local foo "bar"
:put $foo           # prints nothing — $foo is undefined in this scope
EOF
```

Two fixes:

1. Wrap everything in a single `:do { ... }` block so it's one
   statement, OR
2. Upload as a `.rsc` file via `scp` and `/import` it (the file is
   parsed and executed as a single script with proper scope).

Doesn't affect scripts stored in `/system script` (their `source=`
block is parsed as one statement when invoked).

### Schema gotchas worth knowing about

These are bare-property quirks worth knowing if you're editing
`config.rsc`. The full reference lives in
[`README.md`](README.md) § Common pitfalls — listed here for
context within other lessons:

- `/routing table` accepts `fib` as a flag, not `fib=yes` as a
  property assignment. The property form aborts the entire script.
- `/ipv6 dhcp-client add-default-route` defaults to `no` (unlike
  `/ip dhcp-client` which defaults to `yes`), and is silently
  suppressed from `print detail` when set to `no` — which makes
  omission invisible.
- `/ip ssh password-authentication` is the v7 property name (not
  `always-allow-password-login` from v6) and `/ip ssh` has no
  `max-auth-tries` on 7.21.4.

## Project-specific historical notes

For the chronological "what we did when" record, the live config
state in `config.rsc` is authoritative and the git log captures the
sequence. Brief milestones:

- **Phases A + B-MB applied 2026-05-09** — ULA `/48` per VLAN, MB
  DHCPv6-PD `/56` delegation, RA + RDNSS.
- **Sonic Stages 0-3 applied 2026-05-21/22** — Stage 0 probes
  captured Sonic delivery shape (DHCP/IPoE, IA_NA + IA_PD /56, 6h
  lease). Stage 1 added Sonic as passive secondary. Stage 2 v5
  shipped v4 per-VLAN source-based PBR after v1-v4 mangle attempts
  failed (see lesson above). Stage 3 shipped v6 single-GUA-per-VLAN
  via `advertise=yes/no` (see lesson above).
- **wan-reconciler shipped 2026-05-22** — initially `v6-reconciler`
  for `/routing rule` PD-prefix entries only; expanded same day to
  also reconcile `/ip route` + `/ipv6 route` gateway literals, and
  to use dhcp-client `script=` hooks as the event-driven trigger
  alongside a 10-minute polling tick.
- **`main` table flipped to Sonic-primary 2026-05-22** with the
  wan-reconciler change — router-originated traffic and any
  src/dst-rule fall-through prefers the faster ISP.
- **`rp-filter` switched strict → loose 2026-05-23** to align config
  with the multi-WAN asymmetry (see lesson above).
