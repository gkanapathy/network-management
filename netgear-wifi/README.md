# Netgear Orbi → OpenWrt

Two pieces of Netgear hardware being reflashed to OpenWrt for use as
additional APs / extenders on the plumtree network. **Bench project, not
deployed.** They are not part of the live network — the Omada-managed
EAP770 mesh on the rb5009 trunk is still doing all the actual Wi-Fi.

This subproject only covers getting OpenWrt on the boxes and confirming
they boot. How they get integrated (wired AP vs mesh extender, SSID/VLAN
trunking, whether they replace or augment the EAP770s, IaC workflow style)
is a separate plan to write once both units are confirmed running OpenWrt.

## Status

- RBR50 v1: **pending flash**
- RBS50 v1: **pending flash**

Update each line above to "flashed YYYY-MM-DD on OpenWrt <ver>" as the
flashes complete.

## Layout

- [`README.md`](README.md) — this file (status, hardware inventory,
  post-flash facts).
- [`FLASH.md`](FLASH.md) — runbook: `nmrpflash` steps + `debug.htm`
  fallback.

## Hardware inventory

Filled in during the pre-flight step of [`FLASH.md`](FLASH.md). Sticker
hardware-rev MUST read `RBR50` / `RBS50` (not `RBR50V2` / `RBS50V2` —
V2 is a different SoC and would brick on the v1 image).

| Role            | Sticker rev | Serial | LAN MAC | 2.4 GHz MAC | 5 GHz-low MAC | 5 GHz-high MAC | Notes |
|-----------------|-------------|--------|---------|-------------|---------------|----------------|-------|
| RBR50 router    |             |        |         |             |               |                |       |
| RBS50 satellite |             |        |         |             |               |                |       |

## Post-flash facts

Filled in after each unit comes up on OpenWrt. Capture
`cat /etc/openwrt_release; uname -a; ip a` and paste the relevant lines.

### RBR50 router

- OpenWrt version:
- Kernel:
- `br-lan` MAC:
- First-boot date:

### RBS50 satellite

- OpenWrt version:
- Kernel:
- `br-lan` MAC:
- First-boot date:

## Why OpenWrt

Stock Orbi firmware doesn't expose the knobs we need: 802.1q VLAN trunking
to carry plumtree / plumtree-guest / plumtree-iot, bridged AP-only mode
without a forced cloud account, and per-radio control over which SSIDs
broadcast where. OpenWrt does. Once the deployment plan picks a role
(wired AP vs mesh extender vs WDS), the relevant config slots into the
existing rb5009 trunk model.

These are also explicitly **not** Omada devices — different vendor, no
chance of adoption into the OC200. They will run standalone OpenWrt if
and when they're deployed.

## Recovery

Rollback is re-flashing stock Netgear firmware. Per-unit pre-flash
backups were intentionally skipped, so there is no captured state to
restore — instead, download the current stock RBR50 / RBS50 firmware
from netgear.com and `nmrpflash` it back. See the last section of
[`FLASH.md`](FLASH.md).

If `nmrpflash` and the `debug.htm` fallback both fail on a unit, stop
and escalate before attempting serial console — the TTL UART headers
exist on the PCB but reaching them is a tear-open job and warrants a
fresh discussion.
