# Omada Controller (RETIRED)

> **Note:** This software controller was used to bootstrap the network —
> initial AP adoption, SSID/VLAN/mesh setup. It has been **retired**: the
> entire site was migrated to a hardware OC200 v1 at
> `https://192.168.88.252/` on 2026-05-03 via Omada's Site Migration tool.
> The container and Colima VM are stopped. This directory is preserved
> only as a recovery fallback in case the OC200 fails.

## What's here

```
docker-compose.yaml   # mbentley/omada-controller:6.2, host network, bind mounts
omada/data/           # frozen state of the software controller as of cutover
omada/logs/           # last logs before shutdown
omada/{work,backup}/  # empty
PLAN.md               # original design + reasoning (historical)
README.md             # this file
```

The data dir reflects state as of the migration to OC200 — site config,
SSIDs, device records. Because Site Migration was used, this state is
fully reproduced on the OC200; it's preserved here only as a recovery
artifact.

## Reviving for recovery

If the OC200 dies and you need to fall back to the software controller:

```sh
colima start
docker compose -f /Users/gkanapathy/network-management/omada-controller/macos-software/docker-compose.yaml up -d
```

UI returns at `https://192.168.88.251:8043/` after ~30s. Then in the
**hardware controller** (or directly on each EAP):

- If the OC200 is partly alive: change Settings → Controller → "Controller
  Hostname/IP for Device Management" back to `192.168.88.251`.
- If the OC200 is fully dead: SSH each EAP and
  `set inform url https://192.168.88.251:29814/inform`.

The colima VM is bridged to `en7` (USB → MikroTik). Bridge config and
DHCP reservation for the VM MAC `52:55:55:ca:b3:fb` → `192.168.88.251`
remain in place on the rb5009.

## Decommissioning entirely

Once you're confident the OC200 is stable (a couple of weeks of run time,
all clients reconnect cleanly across a reboot, no missing state noticed),
this whole directory can be deleted along with the colima VM:

```sh
colima delete
rm -rf /Users/gkanapathy/network-management/omada-controller
```

(A scheduled audit agent will open a cleanup PR on 2026-05-17 that does
the in-repo half of this for you — see the `oc200/` README.)

Drop the `192.168.88.251` DHCP reservation from the rb5009 at the same
time.
