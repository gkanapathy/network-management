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

- RBR50 v1: **flashed 2026-05-07 to OpenWrt 25.12.3, on the bench**
- RBS50 v1: **flashed 2026-05-07 to OpenWrt 25.12.3, on the bench**

Both units boot to a clean OpenWrt LAN at `192.168.1.1`, three radios
probed (`phy0/1/2`, ath10k for QCA9984 + both IPQ4019 internal radios),
SSH key auth set up using the same `gkanapathy-mbpmx` admin key as the
rb5009. The auto-generated `/etc/config/wireless` has three `wifi-device`
blocks (radio0/1/2, all enabled) and three matching `wifi-iface` blocks
all with `option disabled '1'` — so no SSIDs are broadcasting and no
wifi netdevs exist yet. Configuring them is the integration phase.

## Layout

- [`README.md`](README.md) — this file (status, hardware inventory,
  post-flash facts).
- [`FLASH.md`](FLASH.md) — runbook: `nmrpflash` steps + `debug.htm`
  fallback.

## Hardware inventory

Filled in during the pre-flight step of [`FLASH.md`](FLASH.md). Sticker
hardware-rev MUST read `RBR50` / `RBS50` (not `RBR50V2` / `RBS50V2` —
V2 is a different SoC and would brick on the v1 image).

| Role            | Sticker rev | Serial | LAN MAC             | 2.4 GHz MAC         | 5 GHz-low MAC       | 5 GHz-high MAC      | Notes |
|-----------------|-------------|--------|---------------------|---------------------|---------------------|---------------------|-------|
| RBR50 router    | RBR50       | TBD    | `8c:3b:ad:ab:80:6f` | TBD                 | TBD                 | TBD                 | WAN MAC `8c:3b:ad:ab:80:70`. Radio MACs not captured before power-off — fill in next boot via `for p in /sys/class/ieee80211/phy*; do echo "$(basename $p): $(cat $p/macaddress)"; done`. Mapping is phy0 = QCA9984 5g-high, phy1 = 2.4g, phy2 = IPQ4019 5g-low. |
| RBS50 satellite | RBS50       | TBD    | `8c:3b:ad:ab:99:88` | `8c:3b:ad:ab:99:88` | `8c:3b:ad:ab:99:8a` | `8c:3b:ad:ab:99:8b` | Has 4 LAN ports, no WAN port (satellite hardware). 2.4 GHz MAC matches LAN MAC, which is the IPQ4019's primary identity. |

## Post-flash facts

Filled in after each unit comes up on OpenWrt. Capture
`cat /etc/openwrt_release; uname -a; ip a` and paste the relevant lines.

### RBR50 router

- OpenWrt version: 25.12.3 (`r32912-6639b15f62`)
- Kernel: Linux 6.12.85 SMP armv7l (built 2026-05-04)
- `br-lan` MAC: `8c:3b:ad:ab:80:6f` (192.168.1.1/24, ULA `fdcd:131b:bf79::/60`)
- Subtarget: `ipq40xx/generic` (the `mmc` subtarget that older docs reference no longer exists in 25.x — RBR50 is built under `generic`)
- First-boot date: 2026-05-07

### RBS50 satellite

- OpenWrt version: 25.12.3 (`r32912-6639b15f62`)
- Kernel: Linux 6.12.85 SMP armv7l (built 2026-05-04)
- `br-lan` MAC: `8c:3b:ad:ab:99:88` (192.168.1.1/24, ULA `fdc4:4943:1cdc::/60`)
- Subtarget: `ipq40xx/generic`
- First-boot date: 2026-05-07

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
