# Netgear Orbi (RBR50/RBS50 v1)

Two pieces of Netgear hardware (RBR50 v1 router + RBS50 v1 satellite),
flashed to OpenWrt (2026-05-07) and then **reflashed to Voxel custom
firmware (2026-05-31) and shelved for eventual rehoming**. They are not
part of the live network — the Omada-managed EAP770 mesh on the rb5009
trunk does all the actual Wi-Fi.

Why Voxel now: these are headed to someone else eventually (no recipient
yet), and Voxel is the best firmware to hand off — it keeps the stock
Orbi UX (Netgear app, web UI, mesh as designed) so a non-technical
recipient gets a normal Orbi, but with modern crypto/TLS that fixes the
EOL-stock problem (see [Why Voxel](#why-voxel-and-not-openwrt-or-stock)).
Deploying them *here* was explored and dropped — see
[Decision: shelved](#decision-shelved).

## Status

Both on **Voxel `9.2.5.2.44SF-HW`** (2026-05-31), in factory-setup state
(`isBlankState=1`) — ready to hand off as-is to a recipient's own Orbi
setup. Reflashed directly from OpenWrt via `nmrpflash`; no stock
intermediate was needed (see [`FLASH.md`](FLASH.md) §7).

- RBR50 v1 (router): Voxel `9.2.5.2.44SF-HW`, `DeviceMode=0` (router),
  blank state. LAN `192.168.1.1`, MAC `8c:3b:ad:ab:80:6f`.
- RBS50 v1 (satellite): Voxel `9.2.5.2.44SF-HW`, `DeviceMode=3`
  (satellite), blank state. Verified synced to the router over wired
  backhaul (leased `192.168.1.2`), MAC `8c:3b:ad:ab:99:88`.

Prior state (historical): both ran OpenWrt 25.12.3 from 2026-05-07 to
2026-05-31.

To pick back up: browse to `http://192.168.1.1` (Voxel ships modern TLS,
so current Chrome/Safari work fine) and run the Orbi setup wizard, or SSH
once an admin password is set (Voxel's dropbear accepts root with the
web-UI password). To go back to OpenWrt, just `nmrpflash` the OpenWrt
factory image (see [`FLASH.md`](FLASH.md) §4).

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
- **Rehoming on stock firmware isn't viable — Voxel fixes this.** Stock
  RBR50 v1 firmware no longer talks to current Chrome/Safari (TLS/cert
  handling Netgear has EOL'd); only Firefox still permits the bypass. So
  "give them away as factory units" isn't a real gift. Voxel rebuilds the
  same stock Orbi UX with modern crypto, which is why the rehoming plan
  (2026-05-31) reflashed them to Voxel rather than stock.

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
- [`FLASH.md`](FLASH.md) — runbook: `nmrpflash` steps (stock→OpenWrt,
  OpenWrt→Voxel) + `debug.htm` fallback.

## Hardware inventory

Filled in during the pre-flight step of [`FLASH.md`](FLASH.md). Sticker
hardware-rev MUST read `RBR50` / `RBS50` (not `RBR50V2` / `RBS50V2` —
V2 is a different SoC and would brick on the v1 image).

| Role            | Sticker rev | Serial | LAN MAC             | 2.4 GHz MAC         | 5 GHz-low MAC       | 5 GHz-high MAC      | Notes |
|-----------------|-------------|--------|---------------------|---------------------|---------------------|---------------------|-------|
| RBR50 router    | RBR50       | TBD    | `8c:3b:ad:ab:80:6f` | TBD                 | TBD                 | TBD                 | WAN MAC `8c:3b:ad:ab:80:70`. Radio MACs not captured before power-off — fill in next boot via `for p in /sys/class/ieee80211/phy*; do echo "$(basename $p): $(cat $p/macaddress)"; done`. Mapping is phy0 = QCA9984 5g-high, phy1 = 2.4g, phy2 = IPQ4019 5g-low. |
| RBS50 satellite | RBS50       | TBD    | `8c:3b:ad:ab:99:88` | `8c:3b:ad:ab:99:88` | `8c:3b:ad:ab:99:8a` | `8c:3b:ad:ab:99:8b` | Has 4 LAN ports, no WAN port (satellite hardware). 2.4 GHz MAC matches LAN MAC, which is the IPQ4019's primary identity. |

## Post-flash facts (OpenWrt era — historical)

Captured 2026-05-07 when both ran OpenWrt 25.12.3. Kept as a reference for
a possible future OpenWrt reflash; current Voxel state is under
[Status](#status) above.

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

## Why Voxel (and not OpenWrt or stock)

Three firmwares were in play; the right one depends on who's holding the
box.

- **Stock** is out: Netgear EOL'd RBR50 v1 stock — no security updates,
  and its web-UI TLS/cert handling is rejected by current Chrome/Safari
  (Firefox-only, a temporary reprieve). Not a real gift.
- **OpenWrt** was right while *we* kept them as patchable spares — modern,
  reachable via LuCI from any browser, exposes VLAN trunking / AP-only /
  per-radio knobs. But it's an unfamiliar UX for a non-technical
  recipient, and the deploy-here idea was dropped anyway.
- **Voxel** wins for rehoming: it's stock Netgear Orbi rebuilt with modern
  crypto (OpenSSL 3.5.x, current OpenSSH/OpenVPN), so the recipient gets a
  normal Orbi — Netgear app, familiar web UI, mesh as designed — that
  still works in today's browsers and keeps getting Voxel's security
  updates. Best of both: stock UX, not-EOL guts.

These are explicitly **not** Omada devices — different vendor, no chance
of adoption into the OC200. They run standalone, end to end.

## Recovery

On **Voxel**, the hardware reset button is intentionally disabled (Voxel
can't reset NVRAM without DNI source). To wipe a Voxel unit you flash
stock first, then factory-reset on stock. For our purposes the units are
already in blank state, so there's nothing to do.

Paths if you need to change firmware:

- **Back to OpenWrt** (e.g. you decide to keep one as a spare instead):
  `nmrpflash` the OpenWrt factory image per [`FLASH.md`](FLASH.md) §4.
  That restores the OpenWrt `firstboot -y && reboot` wipe path.
- **To Netgear stock** (a recipient who insists on stock UX, or to get
  button-reset back): `nmrpflash` stock per [`FLASH.md`](FLASH.md) §6.
  Not recommended on its own — stock is EOL/unusable in modern browsers;
  Voxel is the better stock-like target.

If `nmrpflash` and the `debug.htm` fallback both fail on a unit, stop and
escalate before attempting serial console — the TTL UART headers exist on
the PCB but reaching them is a tear-open job and warrants a fresh
discussion.
