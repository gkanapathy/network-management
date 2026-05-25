#!/bin/bash
# Apply config.rsc to the rb5009 router via wipe-and-replay.
#
# Steps:
#   1. Parse-check config.rsc on the router (catches syntax errors
#      BEFORE the destructive apply).
#   2. Save a pre-apply backup, scp it down to snapshots/, delete the
#      on-router copy (router-side backups accumulate as junk and
#      aren't useful — wipe-and-replay starts from config.rsc, not
#      a backup restore).
#   3. Wipe-and-replay: /system reset-configuration ... run-after-reset.
#   4. Wait for the router to come back online.
#   5. Confirm config.rsc:done log marker fired (catches the
#      "import aborted mid-script" failure mode).
#
# Recovery if router doesn't return: README.md § Recovery
#   - IPv6 link-local backdoor (most cases)
#   - button-reset cold bootstrap (if LL also unreachable)
#
# Usage:
#   ./apply.sh                  # full apply
#   ./apply.sh --parse-only     # parse-check, no destructive action
#
# Note: this script does NOT prompt for confirmation. Don't run it
# unless you intend to apply.

set -euo pipefail

ROUTER_USER=admin
ROUTER_HOST=192.168.88.1
ROUTER="${ROUTER_USER}@${ROUTER_HOST}"
CONFIG=config.rsc
BACKUP_NAME=before-apply

# ssh/scp -q suppresses OpenSSH client warnings ("post-quantum",
# "store now", "may need to be upgraded") that flood every line on
# RouterOS 7.21.4. RouterOS's own stdout/stderr passes through fine.
#
# Pre-reset calls use StrictHostKeyChecking=accept-new: first-time
# connect TOFU's the host key into known_hosts, subsequent connects
# verify against it, and a CHANGED key FAILS loudly. With routine
# applies no longer rotating the host key (we removed /ip ssh
# regenerate-host-key from config.rsc), a mismatch now genuinely
# means something unusual — cold bootstrap, manual rotation, or
# RouterOS upgrade. README.md Recovery covers the `ssh-keygen -R`
# step for the cold-bootstrap case.
#
# Post-reset calls (poll loop + marker check) use SSH_NOKHOST as
# defense-in-depth — if a cold-bootstrap happened and known_hosts
# wasn't cleaned, apply.sh still completes. Routine applies don't
# need it (host key persists) but it's harmless and keeps the
# script tolerant of weird states.
SSH="ssh -q -o StrictHostKeyChecking=accept-new"
SCP="scp -q -o StrictHostKeyChecking=accept-new"
SSH_NOKHOST="ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Run from the directory containing this script so relative paths
# (config.rsc, snapshots/) resolve regardless of caller's cwd.
cd "$(dirname "${BASH_SOURCE[0]}")"

PARSE_ONLY=0
case "${1:-}" in
    --parse-only) PARSE_ONLY=1 ;;
    "")           ;;
    *) echo "unknown argument: $1" >&2; echo "usage: $0 [--parse-only]" >&2; exit 2 ;;
esac

# Per-apply nonce: injected into the final "config.rsc: done" :log
# message so step 5's marker check verifies THIS apply's marker
# rather than risk false-passing on a prior successful apply's
# marker still in /log. (RouterOS may preserve /log entries across
# reset-configuration -- we've observed it -- so a bare "grep done"
# isn't sufficient.)
NONCE="$(date +%Y%m%d-%H%M%S)-$$"
SCP_CONFIG="${TMPDIR:-/tmp}/config.rsc.apply.$$"
trap 'rm -f "$SCP_CONFIG"' EXIT
sed "s|\"config.rsc: done\"|\"config.rsc: done apply-$NONCE\"|" "$CONFIG" > "$SCP_CONFIG"

# === 1. parse-check ===========================================================
echo "==> scp $CONFIG to router (apply-nonce $NONCE)"
$SCP "$SCP_CONFIG" "$ROUTER:$CONFIG"

echo "==> parse-check"
if ! $SSH "$ROUTER" ":parse [/file get $CONFIG contents]; :put PARSEOK" | grep -q PARSEOK; then
    echo "ERROR: parse failed; aborting before any destructive action" >&2
    exit 1
fi
echo "    parse OK"

if [ "$PARSE_ONLY" = 1 ]; then
    echo "==> --parse-only set; not applying"
    exit 0
fi

# === 2. backup ================================================================
echo "==> save pre-apply backup"
$SSH "$ROUTER" "/system backup save name=$BACKUP_NAME dont-encrypt=yes" >/dev/null

ts=$(date -u +%Y-%m-%dT%H%M%SZ)
SNAPSHOT="snapshots/${ts}-${BACKUP_NAME}.backup"
echo "==> scp backup to $SNAPSHOT"
$SCP "$ROUTER:${BACKUP_NAME}.backup" "$SNAPSHOT" >/dev/null

echo "==> remove on-router backup"
$SSH "$ROUTER" "/file remove ${BACKUP_NAME}.backup" >/dev/null

# === 3. apply =================================================================
echo "==> APPLY (wipe-and-replay) — router will reboot"
$SSH "$ROUTER" "/system reset-configuration no-defaults=yes skip-backup=yes keep-users=yes run-after-reset=$CONFIG" || true

# === 4. wait for router ======================================================
echo "==> polling for router"
attempt=0
while true; do
    # No trailing `quit` -- RouterOS treats it as a session interrupt
    # and exits the ssh client with code 1, which `set -o pipefail`
    # then propagates through grep, causing the loop to never detect
    # router-back. Letting stdin EOF close the session is sufficient.
    if $SSH_NOKHOST -o ConnectTimeout=1 "$ROUTER" ":put alive" 2>/dev/null | grep -q alive; then
        break
    fi
    attempt=$((attempt + 1))
    if [ $attempt -gt 90 ]; then
        echo "ERROR: router did not return within 3 minutes" >&2
        echo "       try the IPv6 link-local backdoor — see README.md Recovery" >&2
        exit 1
    fi
    sleep 1
done
echo "    router back after $attempt polls"

# With `/ip ssh regenerate-host-key` removed from config.rsc, the
# router's SSH host key now persists across routine `/system
# reset-configuration` applies. known_hosts stays valid; no refresh
# needed. Cold-bootstrap (button reset / netinstall) does regenerate
# the host key as part of factory state, and is documented as a
# manual `ssh-keygen -R 192.168.88.1` step in README.md Recovery.

# === 5. verify completion =====================================================
# Poll for THIS apply's nonced "config.rsc: done" marker. The nonce
# makes the check robust against (a) SSH coming up before import
# is done (the race -- we poll until the marker appears or timeout)
# and (b) /log preserving prior applies' "done" entries across reset
# (the false-pass -- only matching the per-apply nonce avoids this).
echo "==> polling for config.rsc: done apply-$NONCE marker"
attempt=0
marker_seen=0
while [ $attempt -lt 60 ]; do
    if $SSH_NOKHOST "$ROUTER" '/log print' 2>/dev/null | grep -qF "config.rsc: done apply-$NONCE"; then
        marker_seen=1
        break
    fi
    attempt=$((attempt + 1))
    sleep 2
done
if [ "$marker_seen" -eq 0 ]; then
    echo "ERROR: 'config.rsc: done apply-$NONCE' marker not observed within ~2 minutes — import likely aborted mid-script" >&2
    echo "       last 10 config.rsc log entries:" >&2
    $SSH_NOKHOST "$ROUTER" '/log print' 2>/dev/null | grep "config.rsc" | tail -10 >&2 || true
    exit 1
fi
echo "    config.rsc: done marker present (apply-$NONCE, $attempt polls)"

echo "==> apply complete"
