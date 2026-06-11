# rb5009 router config

The source of truth for the router's running config is [`config.rsc`](config.rsc).
The workflow is "wipe + import": apply by erasing the router and replaying
`config.rsc` from scratch. Never patch live state by hand — edit `config.rsc`
and re-apply.

## Layout

- `config.rsc` — target configuration. The whole router's intent.
- `apply.sh` — apply runner: parse-check, pre-wipe `/export`,
  wipe-and-replay, wait, verify completion, snapshot last-applied.
  See [Apply](#apply).
- `gkanapathy-mbpmx.pub` — admin SSH public key. Staged manually on
  cold bootstrap (see Recovery) and imported by the script's
  cold-bootstrap-only key-import block. Routine `apply.sh` does NOT
  re-upload this; `keep-users=yes` on `/system reset-configuration`
  preserves the imported key across routine applies.
- `snapshots/` — working artifacts written by `apply.sh`, gitignored:
  - `last-applied.rsc` — copy of `config.rsc` from the last successful
    apply (= what's currently running on the router).
  - `last-export.rsc` — pre-wipe `/export hide-sensitive` dump, for
    debugging drift between intended (`config.rsc`) and materialized
    state. Not a rollback artifact — rollback is
    `git checkout <sha> -- config.rsc && ./apply.sh`.
- `IPV6-PLAN.md` — v6 design reference. Phases A + B-MB applied;
  Phase C is folded into the Sonic Stage buildout.
- `SONIC-PLAN.md` — staged Sonic WAN buildout. Stages 0–4 applied
  2026-05-21..24 (Stage 0 probes 21st; Stages 1-3 v1 22nd; Stage 3 v2
  + Stage 4 23rd; Bug A retrofit to v6 foreign-source probes 24th).
- `LESSONS.md` — architectural lessons learned during the buildout
  (RouterOS 7.x gotchas, design dead-ends, generalizable patterns).

## Apply

Use [`apply.sh`](apply.sh):

```fish
cd mikrotik-router
./apply.sh                  # full apply
./apply.sh --parse-only     # parse-check only, no destructive action
```

The script does:

1. **scp `config.rsc`** to the router.
2. **Parse-check** via `:parse` — catches syntax errors WITHOUT
   mutating state. Aborts the script before anything destructive
   if parse fails. (Property-name typos can still slip past this —
   see [Common pitfalls](#common-pitfalls).)
3. **Pull `/export hide-sensitive`** to `snapshots/last-export.rsc`.
   Pre-wipe debugging snapshot; rollback is not via this file.
   `skip-backup=yes` on step 4 tells the router not to bother
   saving its own binary backup either — we don't use those.
4. **Wipe + replay**: `/system reset-configuration no-defaults=yes
   skip-backup=yes keep-users=yes run-after-reset=config.rsc`.
   `keep-users=yes` preserves admin's password and imported SSH keys
   so the routine apply doesn't need the `.pub` re-staged. Cold
   bootstrap (button reset, netinstall) is the exception — see
   [Recovery](#recovery).
5. **Poll for the router to come back**. Clears the stale host-key
   entry first (`/system reset-configuration` regenerates the SSH
   host key). Times out after ~3-4 minutes with a recovery pointer.
6. **Verify `config.rsc: done` log marker** is present — catches the
   "import aborted mid-script" failure mode (which the parse-check
   in step 2 won't catch on its own; property-name and runtime
   errors only show up at import time).
7. **Snapshot `config.rsc`** to `snapshots/last-applied.rsc` (only on
   success, so a failed apply doesn't clobber the prior known-good
   copy).

If something goes wrong mid-apply and SSH-via-mgmt-VLAN stops
working, the IPv6 link-local backdoor (see [Recovery](#recovery))
covers most cases without needing a button-reset cold bootstrap.

Manual verification after apply (these are not in the script):

```fish
ssh admin@192.168.88.1 '/export hide-sensitive' > /tmp/router-now.rsc
diff -u config.rsc /tmp/router-now.rsc   # modulo /export's reformatting
```

`/export` reorders and reformats sections, so a literal `diff` will never be
clean — read it for substantive presence/absence, not line-by-line matches.

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
ssh admin@192.168.88.1 '/log/print where message~"config.rsc" and buffer=memory'
```

The `buffer=memory` scopes to the current boot. Without it, `/log` unions
the **disk** buffer too (with disk logging on — see § Disk), which surfaces
every *past* apply's `starting`/`done` markers and makes the current run
hard to pick out. If only `starting` shows, the script aborted partway —
`done` missing means it hit an error somewhere. Read the current boot's log
(`/log/print where buffer=memory`) for the error, fix `config.rsc`, re-apply.

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
user-db (no SSH keys) AND a freshly-generated SSH host key.

(Routine `/system reset-configuration` ALSO regenerates the host
key on each apply, but `apply.sh`'s polling step takes care of
refreshing known_hosts automatically. Cold bootstrap differs because
apply.sh isn't running yet to do that refresh — hence the manual
`ssh-keygen -R` step below.)

**Important:** RouterOS 7.x ships with a unique per-device admin password
printed on the label on the router itself. A button reset restores *that*
password — **not** empty. To regain SSH access:

1. **Clear the stale host-key entry** on the client (`apply.sh` uses
   `StrictHostKeyChecking=accept-new` which fails loudly on a key
   mismatch). On the apply machine:

   ```fish
   ssh-keygen -R 192.168.88.1
   ```

2. Read the printed admin password off the router's label.
3. Log in once via Webfig at `http://192.168.88.1` (or SSH with that
   password — first connection TOFU's the new host key) and reset
   the admin password to empty (or to whatever the apply flow expects).
4. Re-stage **both** `config.rsc` and `gkanapathy-mbpmx.pub`
   (`scp config.rsc gkanapathy-mbpmx.pub admin@192.168.88.1:`) and
   apply. The script's import block runs because the user-db is empty;
   it logs `ssh key imported (cold bootstrap)` and consumes the `.pub`
   off `/file/` after import.

   If the working-tree `config.rsc` is mid-edit from a failed apply,
   `git checkout HEAD -- mikrotik-router/config.rsc` first so the
   re-stage uses the last-committed state. If HEAD itself is broken,
   walk back: `git log mikrotik-router/config.rsc` and
   `git checkout <good-sha> -- mikrotik-router/config.rsc`.

5. **`/system device-mode` dance.** Cold-bootstrap resets device-mode
   to its factory default (`scheduler: no`), which blocks `/system
   scheduler add` — and the shipped config uses a scheduler for the
   `wan-reconciler` 10m polling tick. The apply will complete (the
   scheduler `add` is wrapped in `:do/on-error` so a failure here
   doesn't abort the whole import), but the event-driven reconciler
   trigger via dhcp-client `script=` still works on its own; the
   missing piece is just the belt-and-suspenders 10m heal. To restore
   it after the cold-bootstrap apply:

   ```fish
   ssh admin@192.168.88.1 '/system routerboard reset-button set enabled=no'   # defensive: prevent toggle-leds tap from racing the confirm
   ssh admin@192.168.88.1 '/system device-mode update scheduler=yes'
   # Router prints "press button to confirm in Nm Ys"; press the reset
   # button briefly within that window. Router reboots into permissive
   # mode. After it's back:
   ssh admin@192.168.88.1 '/system routerboard reset-button set enabled=yes'  # restore the hook
   ./apply.sh   # re-apply so the scheduler add succeeds this time
   ```

This means a button reset always requires physical access to the router
plus a manual login + a `ssh-keygen -R` step. Prefer the IPv6 link-local
recovery above when possible — it skips all of this.

### Last resort: netinstall — cold bootstrap

If the router doesn't respond to L2 link-local *and* a button reset hasn't
helped:

1. Hold the reset button during power-on past the USR-LED-flashing window
   (~10s) → netinstall mode.
2. Use MikroTik's `Netinstall` tool against ether1 to reflash the OS.
   Then re-stage `config.rsc` (from git) + `gkanapathy-mbpmx.pub` and
   run `apply.sh` per the button-reset cold-bootstrap procedure above.

Netinstall wipes both the OS and `/file/`, so the cold-bootstrap
re-stage of `gkanapathy-mbpmx.pub` and the `ssh-keygen -R 192.168.88.1`
client-side cleanup from the button-reset section apply here too. We
don't keep binary `.backup` artifacts — rollback is via git, not
`/system backup load`.

## Looking up command syntax on the live router

RouterOS has a built-in introspection command — handy when you're unsure
of a command name, its arguments, or a menu's contents (non-interactive
SSH can't use the interactive `?` completion). Paths are **comma-
separated**, not slash-separated:

```
# arguments/properties a command accepts (e.g. /disk format):
/console/inspect request=syntax path=disk,format

# subcommands under a menu (e.g. what lives under /disk):
/console/inspect request=child path=disk as-value

# enumerate the valid VALUES of an enum-typed property — use
# request=completion with the partial command in `input` (NOT syntax):
/console/inspect request=completion input="/system logging add topics="
```

This is how the `/disk` format command turned out to be `format` (not the
older `format-drive`) and which params it takes (`file-system`, `label`),
and how the full 103-entry `topics` enum was dumped (severity +
subsystem + `packet`/`raw`/`event`… qualifiers).

Caveats:

- `request=syntax` shows argument *names* only — **not** their enum
  values and **not** integer ranges. For enum values use
  `request=completion` (above); for numeric ranges there's no inspect
  path at all.
- Integer ranges surface only from the runtime error (e.g.
  `disk-lines-per-file out of range (1..65535)`) or the docs — which is
  how the 65535 per-file log-line cap was found, after a first apply
  tried 200000 and halted. (Hence: numeric-valued blocks belong below
  the lockout gate, so a range error halts harmlessly — see config.rsc.)

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
  - **Mangle `mark-routing` for per-source PBR is a trap on 7.x.**
    Use `/routing rule` source-based PBR with a `dst=<LAN supernet>`
    priority rule first. Full retrospective with diagnosis trick in
    [`LESSONS.md`](LESSONS.md).
- **Avoid `\` line-continuation in `set` blocks.** RouterOS's `/import`
  parser sometimes rejects continuation across long property lists.
  `/export` produces them but `/import` doesn't always accept them.
  Collapse to a single line; if it's truly unwieldy, split into multiple
  `set` calls with disjoint property sets.
- **`/ipv6 nd prefix` entries derived from `/ipv6 address from-pool=`
  are dynamic; `set` on them is rejected** with `failure: can not
  change dynamic prefix`. Static `/ipv6 nd prefix add` entries accept
  `set`; the dynamic auto-derived ones don't. RA biasing on a
  from-pool interface uses `/ipv6 address ... advertise=yes/no`
  instead. Background in [`LESSONS.md`](LESSONS.md).

## Disk (USB SSD)

A USB SSD (slot `usb1`) holds the long-term log store. The **only** manual
step is formatting it ext4 — a one-time hardware prep, since the filesystem
is not part of `config.rsc` (reset-configuration doesn't touch disk
contents):

```
/disk format usb1 file-system=ext4 label=usb1   # ext4 = container-ready too
```

Everything else is driven by `config.rsc`, **conditional on a mounted
disk**:

- It waits up to ~15s for the disk to enumerate (USB can lag the script on
  a fresh boot), then derives the path from the disk's actual mount-point
  (not hard-coded `usb1`), auto-creates the `logs/` dir, retargets the
  built-in `disk` action at `<mount>/logs/log`, and adds the rules.
- **No disk mounted → no rules are added**, the `disk` action stays
  dormant, and nothing is written — in particular, no fallback writes to
  internal flash.
- Verify after an apply: `/log print where message~"disk logging" and
  buffer=memory` should show `disk logging enabled -> usb1/logs/log`, not
  `… disabled`.

**`/log print` unions all buffers.** Each entry is tagged `buffer=memory`
/ `buffer=disk` / etc., and the disk buffer exposes the *entire* on-disk
log. So with disk logging on, a message caught by both the default
`→memory` rule and our `→disk` rule appears **twice** in plain `/log
print`, and old entries from past boots show up too. For the clean,
single-entry, current-boot view, filter `where buffer=memory`. The disk
*files* are not duplicated — that's purely a `/log` view artifact.

Logging is **severity-based** (`info`/`warning`/`error`/`critical` → disk),
*not* a catch-all — a `!debug`/empty-topics rule silently enables the
`dns,packet` trace firehose (gated topics; see `LESSONS.md`). Rolling
window ~6.5M lines (65535 × 100 files, `disk-stop-on-full=no` = overwrite
oldest). Default memory/echo rules stay intact, so `/log print` still reads
the volatile buffer. Files land as `usb1/logs/log.0.txt`, `log.1.txt`, …

ext4 (over exFAT/FAT) so the same disk can later host container images
(containers need POSIX semantics) — needs the `container` package +
`/system/device-mode/update container=yes` (physical confirm), not set up
yet.

Reformat is now self-healing: just re-run the `format` above; the `logs/`
dir and rules come back on the next apply.

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
