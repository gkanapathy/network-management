# rb5009 router config

The source of truth for the router's running config is [`config.rsc`](config.rsc).
The workflow is "wipe + import": apply by erasing the router and replaying
`config.rsc` from scratch. Never patch live state by hand — edit `config.rsc`
and re-apply.

## Layout

- `config.rsc` — target configuration. The whole router's intent.
- `gkanapathy-mbpmx.pub` — admin SSH public key. Uploaded alongside
  `config.rsc` and imported by the script.
- `snapshots/` — single pre-Sonic baseline `.rsc` for deep
  cold-bootstrap fallback. Per-apply backups are taken locally
  but gitignored (`*.backup`).
- `IPV6-PLAN.md` — v6 design reference (Phases A + B-MB applied;
  Phase C is the Sonic Stage 3 work).
- `SONIC-PLAN.md` — staged Sonic WAN buildout (Stages 0–2 applied).

## Apply

Routine apply only needs `config.rsc`. Files in `/file/` persist
across `/system reset-configuration`, and `keep-users=yes` separately
preserves admin's password and previously-imported SSH keys, so the
script's key-import block is a no-op once the key is loaded. Cold
bootstrap (button reset, netinstall) is a different path — see
[Recovery](#recovery) — and is the only case that needs the `.pub`
re-staged.

```fish
# 1. Pre-apply backup
ssh admin@192.168.88.1 '/system backup save name=before-apply dont-encrypt=yes'
scp admin@192.168.88.1:before-apply.backup snapshots/$(date -u +%Y-%m-%dT%H%M%SZ)-before-apply.backup

# 2. Stage source
scp config.rsc admin@192.168.88.1:

# 3. Pre-flight: parse-check the staged file. Fails fast on syntax errors
#    (line-continuation glitches, unclosed quotes, etc.) WITHOUT mutating
#    state. Catches roughly half of the script-aborts-mid-apply failures.
#    Property-name typos still get past this — see Common pitfalls.
ssh admin@192.168.88.1 ':parse [/file/get config.rsc contents]; :put "parse OK"'
# Should print "parse OK" with no error. If it errors, fix and re-stage.

# 4. Wipe + replay (keep-users preserves admin's password + ssh keys across the reset)
ssh admin@192.168.88.1 '/system reset-configuration no-defaults=yes skip-backup=yes keep-users=yes run-after-reset=config.rsc'
```

The router reboots into a blank state and runs `config.rsc`. SSH should
return within ~90s. **If it's not back inside ~2 min, assume the script
aborted** — switch to the IPv6 link-local backdoor (see Recovery) and
read `/log/print where message~"config.rsc"` to find the error. Don't
keep waiting; the rb5009 boots fast and a long silence is a failure
signal, not a slow boot. Verify:

```fish
ssh admin@192.168.88.1 '/export hide-sensitive' > /tmp/router-now.rsc
diff -u config.rsc /tmp/router-now.rsc   # modulo /export's reformatting
```

`/export` reorders and reformats sections, so a literal `diff` will never be
clean — read it for substantive presence/absence, not line-by-line matches.

### After a reset, the SSH host key changes

`/system reset-configuration no-defaults=yes` regenerates the router's SSH
host keys, so the first SSH after apply will fail with "REMOTE HOST
IDENTIFICATION HAS CHANGED". Clear the old entry and reconnect:

```fish
ssh-keygen -R 192.168.88.1
ssh admin@192.168.88.1
```

### Apply log markers

`config.rsc` logs `config.rsc: starting` and `config.rsc: done` via
`:log info` at the boundaries, plus one of three SSH-key messages
in between:

- `admin ssh key already present, skipping import` — routine apply,
  `keep-users=yes` carried the key forward. Most common.
- `ssh key imported (cold bootstrap)` — first apply after factory
  wipe / netinstall; the staged `.pub` populated the empty user db.
- `no admin ssh key registered and gkanapathy-mbpmx.pub absent;
  password fallback only` — cold bootstrap without staging the `.pub`.
  Recoverable but you'll need the device-label admin password to
  log back in and add a key.

After a reset, check that `starting` and `done` both appear:

```fish
ssh admin@192.168.88.1 '/log/print where message~"config.rsc"'
```

If only `starting` shows, the script aborted partway — `done` missing means
the script hit an error somewhere. Read the full log (`/log/print`) for the
error, fix `config.rsc`, re-apply.

## Recovery

### IPv6 link-local: the backdoor when IPv4 breaks

If the apply leaves IPv4 unreachable (mgmt VLAN misconfig, DHCP server
didn't start, vlan-filtering enabled too early, etc.), the router is almost
always still alive on IPv6 link-local over the same cable:

```fish
ping6 -I en7 ff02::1                    # all-nodes mcast; router replies on every if MAC
ssh admin@fe80::6f4:1cff:fe51:bad8%en7  # bridge admin-mac 04:F4:1C:51:BA:D8 in EUI-64
```

SSH listens on all addresses by default and key auth works as long as
admin's key is registered. This is the preferred recovery path — saves
the button-reset + WebFig-set-password dance.

### Hard factory reset (button) — cold bootstrap

Hold the reset button while powering on, release when the USR LED starts
flashing (~5s). The router boots back to factory state with an empty
user-db (no SSH keys), so unlike a routine `reset-configuration` apply,
this path **does** need the `.pub` re-staged.

**Important:** RouterOS 7.x ships with a unique per-device admin password
printed on the label on the router itself. A button reset restores *that*
password — **not** empty. To regain SSH access:

1. Read the printed admin password off the router's label.
2. Log in once via Webfig at `http://192.168.88.1` (or SSH with that
   password) and reset the admin password to empty (or to whatever the
   apply flow expects).
3. Re-stage **both** `config.rsc` and `gkanapathy-mbpmx.pub`
   (`scp config.rsc gkanapathy-mbpmx.pub admin@192.168.88.1:`) and
   apply. The script's import block runs because the user-db is empty;
   it logs `ssh key imported (cold bootstrap)` and consumes the `.pub`
   off `/file/` after import.

   If the working-tree `config.rsc` is mid-edit from a failed apply,
   `git checkout HEAD -- mikrotik-router/config.rsc` first so the
   re-stage uses the last-committed state. `snapshots/` keeps a single
   pre-Sonic baseline (`*-post-key-refactor.rsc`) as a deeper fallback
   if HEAD itself is in a broken state.

4. **(Stage 4 prerequisite, not Stage 3.)** Cold-bootstrap also resets
   `/system device-mode` to its factory default (`scheduler: no`),
   which blocks `/system scheduler add`. Stage 3 as-shipped doesn't
   use the scheduler (the original preferred-lifetime-override design
   was abandoned when we found dynamic `/ipv6 nd prefix` entries
   reject `set` on 7.21.4), so a cold-bootstrap recovery applies
   `config.rsc` cleanly without this step. **Stage 4** (Netwatch
   failover automation) WILL need scheduler; when Stage 4 lands, add
   this step after the apply above:

   ```fish
   ssh admin@192.168.88.1 '/system routerboard reset-button set enabled=no'   # defensive: prevent toggle-leds tap from racing
   ssh admin@192.168.88.1 '/system device-mode update scheduler=yes'
   # Router prints "press button to confirm in Nm Ys"; press the reset
   # button briefly within that window. Router reboots into permissive
   # mode. After it's back:
   ssh admin@192.168.88.1 '/system routerboard reset-button set enabled=yes'  # restore the hook
   ssh admin@192.168.88.1 '/system reset-configuration no-defaults=yes skip-backup=yes keep-users=yes run-after-reset=config.rsc'   # re-apply
   ```

This means a button reset always requires physical access to the router
plus a manual login step (plus the device-mode dance once Stage 4 lands).
Prefer the IPv6 link-local recovery above when possible — it skips all
of this.

### Last resort: netinstall — cold bootstrap

If the router doesn't respond to L2 link-local *and* a button reset hasn't
helped:

1. Hold the reset button during power-on past the USR-LED-flashing window
   (~10s) → netinstall mode.
2. Use MikroTik's `Netinstall` tool against ether1 to reflash the OS, or
   restore the most recent `snapshots/*.backup` via `/system backup load`.

The pre-apply backup pulled in step 1 of Apply is the immediate safety
net. Netinstall wipes both the OS and `/file/`, so the cold-bootstrap
re-stage of `gkanapathy-mbpmx.pub` applies here too.

## Common pitfalls

- **L3 IPs must live on `/interface vlan` sub-interfaces, not on `bridge`,
  once `vlan-filtering=yes`.** Frames reaching the CPU are tagged per the
  bridge VLAN table; the bridge interface's IP layer never sees them. Put
  IPs on `vlan88`/`vlan10`/etc. — even for the management VLAN.
- **Verify RouterOS property names on the live router before writing `set`
  lines.** The script aborts on the first error and only signals failure by
  a missing log marker. `/<path>/print` shows current properties; the
  `:parse` pre-flight in Apply step 3 catches *syntax* errors but not
  schema errors (a `set foo=bar` will parse fine even if `foo` isn't a
  real property; the failure only shows up at `/import` runtime).
  Bugs we've actually hit:
  - `/ip ssh` uses `password-authentication={yes,no,yes-if-no-key}`, not
    `always-allow-password-login` (that's RouterOS 6.x).
  - `/ip ssh` does not have a `max-auth-tries` property in 7.21.4 (that's
    OpenSSH's `MaxAuthTries`). Brute-force resistance lives elsewhere
    (key-only auth + `/ip service address=` scoping).
  - `/routing table` accepts `fib` as a flag, NOT `fib=yes` as an
    assignment. `fib=yes` parses as "expected end of command" at
    the `=`, aborts the import script, and (since the
    `vlan-filtering=yes` line is at the very bottom of `config.rsc`)
    locks plumtree out from the router. Cost two cold-bootstrap
    recoveries during the Stage 2 buildout (2026-05-21) before we
    spotted it. Use `add name=X fib` (no value).
  - `/ipv6 dhcp-client add-default-route` defaults to `no` on 7.21.4
    (unlike `/ip dhcp-client` which defaults to `yes`). Set it
    explicitly. Setting `default-route-distance=N` alone is not
    enough — the property is suppressed in `print detail` output
    when `add-default-route=no`, which makes the omission silent.
  - **Mangle `mark-routing` for per-source PBR is a trap on 7.21.4.**
    Two related issues we hit during the Sonic Stage 2 buildout
    (2026-05-21..22):
    (a) RouterOS 7.x has **no longest-prefix-match across routing
        tables** and **no implicit fallback** from a custom table to
        `main`. Once a packet has `routing-mark=X`, only table `X` is
        searched. So a LAN-destined packet from a marked source VLAN
        (DNS to router, inter-VLAN, etc.) egresses whichever WAN the
        marked table points at, gets masqueraded, and is dropped
        upstream with a private-IP dst.
    (b) Conntrack carries the routing-mark from the initial direction
        to the reply direction. So even if you avoid (a) by scoping the
        mark to WAN-bound traffic, reply packets *also* end up with the
        mark, route via the custom table, and egress back out the WAN
        instead of to the LAN client. Conntrack shows `SEEN-REPLY
        orig-packets=N repl-packets=N` for every flow that times out at
        the client.
    Adding LAN-connected routes to the custom tables (so LPM within
    the table catches LAN dsts) didn't reliably work either — static
    routes end up with `scope=30 target-scope=10` (vs `scope=10
    target-scope=5` on `main`'s connected routes), and the LPM didn't
    appear to use the static entry. **Solution: use `/routing rule`
    source-based PBR instead.** A source-based rule sets no
    routing-mark; reply packets bypass the rule because their src is
    the remote endpoint, falling through to `main`. Put a
    `dst-address=192.168.0.0/16 action=lookup table=main` rule *first*
    in the chain so inter-VLAN and LAN-to-router traffic stays in
    `main` too. Diagnosis trick: disable the mangle `mark-routing`
    rules; if the client recovers immediately, you're hitting this.
- **Avoid `\` line-continuation in `set` blocks.** RouterOS's `/import`
  parser sometimes rejects continuation across long property lists.
  `/export` produces them but `/import` doesn't always accept them.
  Collapse to a single line; if it's truly unwieldy, split into multiple
  `set` calls with disjoint property sets.
- **`/ipv6 nd prefix` entries derived from `/ipv6 address from-pool=`
  are dynamic; `set` on them is rejected.** Attempting
  `/ipv6 nd prefix set [find ...] preferred-lifetime=...` returns
  `failure: can not change dynamic prefix`. Probe results that say
  the override "works" likely tested a *static* `/ipv6 nd prefix add`
  entry — a different code path. The 7.21.4 mechanism for biasing RA
  on a from-pool interface is `/ipv6 address ... advertise=yes/no`
  itself (which IS settable; Sonic Stage 3 ships this). If you need
  a dynamic preferred-lifetime knob, the alternative is a static
  `/ipv6 nd prefix add` per VLAN per pool — at the cost of having
  to track prefix rotation manually for each entry.

## Sensitive material

Currently none in `config.rsc`:

- Admin password is empty; key auth + empty-password fallback (`/ip ssh
  password-authentication=yes` is set as a safety net while we iterate —
  tighten to `yes-if-no-key` later).
- Wi-Fi PSKs live on the Omada APs, not the router.

If ISP credentials (PPPoE etc.) get added later, keep them in a separate
`secrets.rsc` that is *not* committed and is imported after `config.rsc`.

## Workflow rule

If something is wrong with the router, the fix is to edit `config.rsc` and
re-apply, not to fix the live router with a one-off command. The one-off
will get wiped on the next apply, and the drift will silently come back.
