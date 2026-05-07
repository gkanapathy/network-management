# OC200 hardware controller

Active Omada Controller for the home network. Hardware **OC200 v1**, web
UI at `https://192.168.88.252/`. Adopted both EAP770s and runs the
plumtree / plumtree-guest / plumtree-iot SSIDs on VLANs 10/20/30.

Migrated here from the software controller in `../macos-software/` on
2026-05-03 via Omada's Site Migration tool.

## ⚠ Beta firmware — should move to stable eventually

Currently running TP-Link **beta** firmware
`OC200(UN)_V1_1.40.17_pre-release` (built-in Omada SDN Controller
**v6.2.10.17**). This was needed to bridge a version-skew during the
migration: the source software controller was on v6.2.10.17 and Omada
strictly requires destination ≥ source for both Site Migration and
Backup/Restore. The OC200 v1 only had v5.12.9 from the factory, the
mainline online-upgrade only got it to v6.2.10.15, and v6.2.10.17 was
only available as a pre-release on the TP-Link community forum.

**TODO**: move to stable when TP-Link ships an OC200 v1 stable bundling
Controller ≥ 6.2.10.17.

- Watch the index thread:
  <https://community.tp-link.com/en/business/forum/topic/245226>
  ("Get the Latest Omada SDN Controller Releases — Subscribe for Updates")
- Pre-release thread that this firmware came from:
  <https://community.tp-link.com/en/business/forum/topic/861796>

Risks of staying on beta:
- May contain bugs not yet caught in stable
- TP-Link doesn't guarantee a stable→beta→stable upgrade path is clean
- The OC200 v1 hardware is older; TP-Link may EOL beta updates without
  ever shipping a stable that bundles 6.2.10.17 or later. If that
  happens, plan a hardware refresh (OC200 V3, OC300, OC400) — all of
  those are on active mainline release lines.

## Layout

```
README.md            # this file
backups/             # controller .cfg files from Settings → Maintenance → Backup & Restore
```

## Backups

Take a fresh backup any time you make significant config changes
(adding/removing a device, SSID/VLAN edits, firmware upgrades):

1. UI → Settings → Maintenance → Backup & Restore → **Backup**
2. Save the downloaded `.cfg` to
   `omada-controller/oc200/backups/YYYY-MM-DD-<short-note>.cfg`
3. Commit:
   ```sh
   git add omada-controller/oc200/backups/<file>.cfg
   git commit -m "oc200: backup before <change>"
   ```

To restore: same UI, click **Restore**, upload a `.cfg`. Restore
requires destination version ≥ source version (Omada enforces strictly),
so a backup taken on v6.2.10.17 will only restore on v6.2.10.17 or
later. Don't expect old backups to import after a future firmware
downgrade or a hardware swap to a controller running an older bundled
version.

## Recovery

If the OC200 fails: the software controller in `../macos-software/` is
preserved as a fallback. See its README for the revival procedure. (That
fallback will be removed by a scheduled audit on 2026-05-17 if no
rollback was needed in the meantime.)
