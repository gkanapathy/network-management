# rb5009 router config

The source of truth for the router's running config is [`config.rsc`](config.rsc).
The workflow is "wipe + import": apply by erasing the router and replaying
`config.rsc` from scratch. Never patch live state by hand — edit `config.rsc`
and re-apply.

## Layout

- `config.rsc` — target configuration. The whole router's intent.
- `gkanapathy-mbpmx.pub` — admin SSH public key. Uploaded alongside
  `config.rsc` and imported by the script.
- `snapshots/` — `/export hide-sensitive` captures and `/system backup`
  files. Reference + rollback.
- `PLAN.md` — original buildout plan (VLANs/firewall/WAN). Historical /
  context; the live intent lives in `config.rsc`.

## Apply

Files in `/file/` persist across `/system reset-configuration`, so we stage
sources, then reset with `run-after-reset` to replay them on the blank
router.

```fish
# 1. Pre-apply backup
ssh admin@192.168.88.1 '/system backup save name=before-apply dont-encrypt=yes'
scp admin@192.168.88.1:before-apply.backup snapshots/$(date -u +%Y-%m-%dT%H%M%SZ)-before-apply.backup

# 2. Stage sources
scp config.rsc gkanapathy-mbpmx.pub admin@192.168.88.1:

# 3. Wipe + replay
ssh admin@192.168.88.1 '/system reset-configuration no-defaults=yes skip-backup=yes run-after-reset=config.rsc'
```

The router reboots into a blank state and runs `config.rsc`. ~60–90s later
SSH is back. Verify:

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

`config.rsc` logs `config.rsc: starting` / `... ssh key imported` / `... done`
via `:log info`. After a reset, check that all three appear:

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

SSH listens on all addresses by default and key auth works as long as the
script reached `ssh key imported`. This is the preferred recovery path —
saves the button-reset + WebFig-set-password dance.

### Hard factory reset (button)

Hold the reset button while powering on, release when the USR LED starts
flashing (~5s). The router boots back to factory state.

**Important:** RouterOS 7.x ships with a unique per-device admin password
printed on the label on the router itself. A button reset restores *that*
password — **not** empty. To regain SSH access:

1. Read the printed admin password off the router's label.
2. Log in once via Webfig at `http://192.168.88.1` (or SSH with that
   password) and reset the admin password to empty (or to whatever the
   apply flow expects).
3. Then re-stage `config.rsc` + pubkey and re-apply.

This means a button reset always requires physical access to the router
plus a manual login step. Prefer the IPv6 link-local recovery above when
possible — it skips this dance.

### Last resort: netinstall

If the router doesn't respond to L2 link-local *and* a button reset hasn't
helped:

1. Hold the reset button during power-on past the USR-LED-flashing window
   (~10s) → netinstall mode.
2. Use MikroTik's `Netinstall` tool against ether1 to reflash the OS, or
   restore the most recent `snapshots/*.backup` via `/system backup load`.

The pre-apply backup pulled in step 1 of Apply is the immediate safety net.

## Common pitfalls

- **L3 IPs must live on `/interface vlan` sub-interfaces, not on `bridge`,
  once `vlan-filtering=yes`.** Frames reaching the CPU are tagged per the
  bridge VLAN table; the bridge interface's IP layer never sees them. Put
  IPs on `vlan88`/`vlan10`/etc. — even for the management VLAN.
- **Verify RouterOS property names on the live router before writing `set`
  lines.** The script aborts on the first error and only signals failure by
  a missing log marker. `/<path>/print` shows current properties.
  Spelling/version mismatch we hit: `/ip ssh` uses
  `password-authentication={yes,no,yes-if-no-key}`, not the older
  `always-allow-password-login`.

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
