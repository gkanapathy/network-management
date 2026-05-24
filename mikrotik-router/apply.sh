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
SSH="ssh -q"
SCP="scp -q"

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
# The reset-configuration regenerates SSH host keys, so the next
# connection would fail on host-key-changed. Clear our entry first.
echo "==> polling for router (host key will rotate)"
ssh-keygen -R "$ROUTER_HOST" >/dev/null 2>&1 || true

attempt=0
while true; do
    if ssh -o ConnectTimeout=1 -o StrictHostKeyChecking=accept-new \
           "$ROUTER" ":put alive; quit" 2>/dev/null | grep -q alive; then
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

# === 5. verify completion =====================================================
# Give the log a moment to flush.
sleep 3

if ! $SSH "$ROUTER" '/log print where message="config.rsc: done"' | grep -q done; then
    echo "ERROR: 'config.rsc: done' marker MISSING — import aborted mid-script" >&2
    echo "       inspect: ssh $ROUTER '/log print'" >&2
    exit 1
fi
echo "    config.rsc: done marker present"

echo "==> apply complete"
