# Netgear Orbi → OpenWrt

Two pieces of Netgear hardware (RBR50 v1 router + RBS50 v1 satellite)
flashed to OpenWrt and **shelved as spares**. They are not part of the
live network — the Omada-managed EAP770 mesh on the rb5009 trunk is
doing all the actual Wi-Fi.

This subproject covered getting OpenWrt on the boxes and confirming
they boot. Integration as APs / extenders was explored but **not
pursued** — see [Decision: shelved](#decision-shelved) below.

## Status

- RBR50 v1: **flashed 2026-05-07 → OpenWrt 25.12.3 → factory-reset
  (`firstboot`) and shelved 2026-05-08**
- RBS50 v1: **flashed 2026-05-07 → OpenWrt 25.12.3 → shelved 2026-05-08**
  (factory-reset state TBC; may have been left with SSH key still
  installed for next-time-pickup convenience)

After `firstboot`: no root password, no SSH authorized_keys, default
LAN at `192.168.1.1`, all three radios probed (`phy0/1/2`, ath10k for
QCA9984 + both IPQ4019 internal radios) but with every `wifi-iface`
having `option disabled '1'` (so no SSIDs broadcasting, no wifi
netdevs). Identical to the as-flashed state from `nmrpflash`.

To revive: ssh `root@192.168.1.1` from a bench LAN, `passwd`, then
re-install the admin SSH pubkey (procedure in
[`FLASH.md`](FLASH.md) section 4). Picks up exactly where 2026-05-07
flash session ended.

## Decision: shelved

Explored on 2026-05-08; decided not to deploy. Factors:

- **No actual coverage gap to fill.** The Omada EAP770 mesh
  (one wired root + one wireless satellite over 6 GHz channel 197)
  covers the house. Adding more APs would be answer-in-search-of-a-
  problem.
- **Wireless backhaul is the only deployable option** — locations
  aren't wireable. But wireless backhaul to the EAP770 root forces
  STA-mode bridging via `relayd`, which means single-VLAN reach
  (only `plumtree`, no guest/iot at the new locations), no 802.11r
  fast-transition roaming across the EAP770/Orbi boundary, and
  IPv6-multicast gaps. Tolerable for "fill a dead spot" but lousy
  for "augment a working mesh."
- **EAP770 is Omada-Mesh-only.** Doesn't peer with anything OpenWrt
  speaks (802.11s, EasyMesh-via-prplmesh, open WDS) per
  [TP-Link's own product comparison](https://www.omadanetworks.com/uk/blog/1296/tp-link-deco-mesh-vs-easymesh-vs-onemesh-vs-omada-mesh-what-s-the-difference-/).
  No path to multi-VLAN over wireless backhaul without empirically
  verifying 4-address-mode WDS frames against the EAP770 (deferred
  experiment, not scheduled).
- **Wi-Fi 5–era hardware.** Even with a clean deploy, throughput
  ceiling is well below what the existing EAP770s already deliver.
  Adding more SSIDs in the airspace also mildly hurts the queued
  Wi-Fi-bufferbloat investigation in `CLAUDE.md`'s "What's next."
- **Rehoming with stock firmware isn't viable.** Stock RBR50 v1
  firmware no longer talks to current Chrome/Safari (TLS/cert
  handling Netgear has EOL'd); only Firefox still permits the
  bypass. So "give them away as factory units" isn't a real gift.

The flashing exercise wasn't wasted — see [`FLASH.md`](FLASH.md)
which now documents `nmrpflash` + OpenWrt 25.x quirks (subtarget
`generic` not `mmc`, filenames have no `-v1` suffix, package manager
is `apk` not `opkg`, dropbear authorized-keys path) for any future
run.

When to revisit: only if a real coverage gap appears, or if the
EAP770 mesh fails and we want a quick replacement, or if the
4-address-WDS test ever gets done and changes the design space.

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

## Why OpenWrt (and not stock)

Stock Orbi firmware on the RBR50 v1 has been EOL'd by Netgear — no
security updates, and the OEM web UI's TLS / cert handling is no
longer accepted by current Chrome or Safari. Only Firefox still
permits the bypass, and even that's a temporary reprieve. OpenWrt
keeps these units patchable and accessible from any modern browser
via LuCI, which is the bare minimum for "shelved spare we might want
to pick up again."

Stock also doesn't expose the knobs we'd want for any future
deployment — 802.1q VLAN trunking, bridged AP-only mode without a
forced cloud account, per-radio control over SSIDs. OpenWrt does.

These are explicitly **not** Omada devices — different vendor, no
chance of adoption into the OC200. They run standalone OpenWrt
end-to-end.

## Recovery

`firstboot -y && reboot` on the unit. Wipes the JFFS2 overlay
(passwords, SSH keys, wifi config, hostname) and reboots into the
same as-flashed state we had right after `nmrpflash`. ~30s. **No
reflash required.** This is the recommended "blow away changes"
path.

Rollback to **Netgear stock** firmware is technically possible
(download from netgear.com, `nmrpflash` it back per
[`FLASH.md`](FLASH.md) section 6), but isn't recommended for these
units — stock is EOL and unusable in modern browsers. Only do this
if specifically needed (e.g. a recipient who insists on stock-UX).

If `nmrpflash` and the `debug.htm` fallback both fail on a unit,
stop and escalate before attempting serial console — the TTL UART
headers exist on the PCB but reaching them is a tear-open job and
warrants a fresh discussion.
