# OC200 hardware controller

Active Omada Controller for the home network. Hardware **OC200 v1**, web
UI at `https://192.168.88.252/`. Running stable firmware
`1.40.18 Build 20260506 Rel.74003`. Adopted both EAP770s and runs the
plumtree / plumtree-guest / plumtree-iot SSIDs on VLANs 10/20/30.

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
so don't expect backups to import after a firmware downgrade or a
hardware swap to a controller running an older bundled version.

## Recovery

If the OC200 fails: the software controller setup is no longer maintained; you'd need to either swap to different hardware or rebuild the controller from a `omada-controller/oc200/backups/*.cfg` on a fresh deployment.
