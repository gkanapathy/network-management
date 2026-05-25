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
# verify against it. The pre-reset side relies on known_hosts being
# up-to-date from the prior apply (which refreshed it via the
# ssh-keygen -R + ssh-keyscan block after polling). On a totally
# fresh machine, the first apply ever TOFUs the key.
#
# Post-reset calls (poll loop + marker check) use SSH_NOKHOST.
# /system reset-configuration regenerates the host key on every
# apply as part of factory-state restoration, so known_hosts is
# stale until the ssh-keygen -R + ssh-keyscan refresh at the end
# of step 4 puts the new key in place. Bypassing known_hosts for
# the polling avoids a wedge there.
# BatchMode=yes makes SSH/SCP fail fast on auth errors instead of
# prompting for a password on stdin. Without it, a cold bootstrap
# where the .pub wasn't staged (router falls back to password auth)
# would hang the poll loop forever waiting for input, and the 90-poll
# timeout would never trigger.
SSH="ssh -q -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
SCP="scp -q -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
SSH_NOKHOST="ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

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
echo "==> polling for router (host key will rotate)"
attempt=0
while true; do
    # No trailing `quit` -- RouterOS treats it as a session interrupt
    # and exits the ssh client with code 1, which `set -o pipefail`
    # then propagates through grep, causing the loop to never detect
    # router-back. Letting stdin EOF close the session is sufficient.
    # ConnectTimeout=2: a 1s ceiling was too tight against the SYN-
    # retransmit window during the reboot's "TCP listens but stalls
    # before handshake" sliver -- bumping to 2s makes detection
    # more reliable. Each iteration is then up to ~3s (2s connect +
    # 1s sleep) during the down window; ~90 polls is ~3-4 min worst
    # case, with typical recovery in under a minute.
    if $SSH_NOKHOST -o ConnectTimeout=2 "$ROUTER" ":put alive" 2>/dev/null | grep -q alive; then
        break
    fi
    attempt=$((attempt + 1))
    if [ $attempt -gt 90 ]; then
        echo "ERROR: router did not return within 90 polls (~3-4 min)" >&2
        echo "       try the IPv6 link-local backdoor — see README.md Recovery" >&2
        exit 1
    fi
    sleep 1
done
echo "    router back after $attempt polls"

# Refresh known_hosts. /system reset-configuration regenerates the
# SSH host key on every routine apply as part of factory-state
# restoration -- this happens regardless of what /ip ssh settings
# config.rsc lays down afterwards. Empirically verified post-apply:
# known_hosts entry differs from the live key after each apply.
# Without this refresh, the next interactive SSH outside apply.sh
# would hit host-key-changed and require manual `ssh-keygen -R`.
# Failures here (e.g., read-only ~/.ssh in a sandboxed environment)
# are tolerated; the apply itself doesn't depend on known_hosts
# being clean.
ssh-keygen -R "$ROUTER_HOST" >/dev/null 2>&1 || true
# -q suppresses ssh-keyscan's banner-line header so it doesn't
# accumulate in known_hosts on every apply.
ssh-keyscan -q -T 5 -t ed25519 "$ROUTER_HOST" 2>/dev/null >> ~/.ssh/known_hosts || true

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
    if $SSH_NOKHOST "$ROUTER" '/log print where message~"config.rsc"' 2>/dev/null | grep -qF "config.rsc: done apply-$NONCE"; then
        marker_seen=1
        break
    fi
    attempt=$((attempt + 1))
    sleep 2
done
if [ "$marker_seen" -eq 0 ]; then
    echo "ERROR: 'config.rsc: done apply-$NONCE' marker not observed within ~2 minutes — import likely aborted mid-script" >&2
    echo "       last 10 config.rsc log entries:" >&2
    $SSH_NOKHOST "$ROUTER" '/log print where message~"config.rsc"' 2>/dev/null | tail -10 >&2 || true
    exit 1
fi
echo "    config.rsc: done marker present (apply-$NONCE, $attempt polls)"

echo "==> apply complete"
