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
# verify against it, and a CHANGED key (stale entry from a previous
# apply not cleaned up, or actual MITM) FAILS loudly. That's the
# correct security signal — apply.sh shouldn't silently accept a
# rotated key before it's done the rotation itself.
#
# Post-reset calls (poll loop + marker check) use SSH_NOKHOST instead
# because we just rotated the host key ourselves; known_hosts is
# expected to mismatch until the cleanup at the end of step 4.
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

# === 1. parse-check ===========================================================
echo "==> scp $CONFIG to router"
$SCP "$CONFIG" "$ROUTER:"

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
    if $SSH_NOKHOST -o ConnectTimeout=1 "$ROUTER" ":put alive; quit" 2>/dev/null | grep -q alive; then
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

# Best-effort known_hosts refresh so interactive SSH outside apply.sh
# doesn't trip over a stale host key. Failures (e.g., read-only ~/.ssh
# in a sandboxed environment) are tolerated — the apply itself doesn't
# depend on known_hosts being clean.
ssh-keygen -R "$ROUTER_HOST" >/dev/null 2>&1 || true
ssh-keyscan -T 5 -t ed25519 "$ROUTER_HOST" 2>/dev/null >> ~/.ssh/known_hosts 2>/dev/null || true

# === 5. verify completion =====================================================
# Give the log a moment to flush.
sleep 3

if ! $SSH_NOKHOST "$ROUTER" '/log print where message="config.rsc: done"' | grep -q done; then
    echo "ERROR: 'config.rsc: done' marker MISSING — import aborted mid-script" >&2
    echo "       inspect: ssh $ROUTER '/log print'" >&2
    exit 1
fi
echo "    config.rsc: done marker present"

echo "==> apply complete"
