# Flash runbook: Orbi RBR50 v1 / RBS50 v1 → OpenWrt

The primary path is `nmrpflash` over a bench Ethernet link. No serial,
no telnet on stock — Netgear's NMRP recovery protocol is always
listening at boot. If `nmrpflash` won't complete, fall back to the
`debug.htm` partition-flip + OEM web upload procedure (section 5).

Do this with the unit on a **bench LAN, not the live plumtree
network** — NMRP frames are L2 broadcasts and you don't want them
landing on the wrong device, and you don't want stock-firmware DHCP
fighting with the rb5009.

## 1. Prerequisites

- `nmrpflash` installed:

  ```fish
  brew install nmrpflash
  ```

- A dedicated bench Ethernet path. Get one with a USB-Ethernet adapter
  if needed. **Don't reuse `en7`** — that's the colima→rb5009 bridge
  per [`omada-controller/macos-software/README.md`](../omada-controller/macos-software/README.md).
  Plug in a separate adapter, then pick the new iface name fresh:

  ```fish
  ifconfig | grep -E '^en[0-9]+:'
  # note the new entry that appeared after plugging in the adapter; use
  # that name as <iface> below.
  ```

- One Cat5e+ cable, plugged into the LAN port nearest the power button
  on the Orbi. (The WAN-labeled port doesn't carry NMRP.)

## 2. Image selection

Latest OpenWrt stable as of mid-2026 is the 24.10.x branch. Confirm the
exact current version against the index at
<https://downloads.openwrt.org/releases/> at flash time.

Filenames (substitute `<ver>`):

- `openwrt-<ver>-ipq40xx-mmc-netgear_orbi-rbr50-v1-squashfs-factory.img`
- `openwrt-<ver>-ipq40xx-mmc-netgear_orbi-rbs50-v1-squashfs-factory.img`

Download both into `~/Downloads/` (we don't store firmware in this
repo). Verify against the published `sha256sums` file in the same
release directory:

```fish
cd ~/Downloads
shasum -a 256 -c sha256sums --ignore-missing
# expect "OK" lines for both factory images
```

Once downloaded and verified, **paste the actual version + sha256s here**
so this file documents what was used:

- OpenWrt version flashed: `<fill in>`
- RBR50 v1 factory sha256: `<fill in>`
- RBS50 v1 factory sha256: `<fill in>`

## 3. Pre-flight (per unit)

Do RBR50 first, then RBS50. Same procedure for each.

1. **Read the bottom sticker.** It must read `RBR50` or `RBS50`.
   `RBR50V2` / `RBS50V2` are a different SoC (IPQ8074, not IPQ4019),
   different OpenWrt target, and the v1 image will brick them. If you
   see a V2, stop — this runbook does not cover them.

2. **Capture identifying info into [`README.md`](README.md)'s hardware
   inventory table.** From the bottom sticker: hardware rev, serial,
   LAN MAC. From the stock Orbi UI (browse to the unit's current IP
   on a temporary connection if needed), grab any radio MACs visible.
   Commit this before flashing — once stock firmware is gone, the
   stock-UI view of those MACs is gone with it.

3. **Probe with `nmrpflash -L`.** Power-cycle the Orbi while the
   bench cable is connected. Within ~5s:

   ```fish
   sudo nmrpflash -L -i <iface>
   # expect a line like "<mac> <model-code>" with the model code
   # matching RBR50 / RBS50.
   ```

   If nothing shows up, re-seat the cable, confirm `<iface>` is link-up
   (`ifconfig <iface>`), and try again. The detection window is short.

## 4. Flash

```fish
sudo nmrpflash -i <iface> \
  -f ~/Downloads/openwrt-<ver>-ipq40xx-mmc-netgear_orbi-rbr50-v1-squashfs-factory.img
```

(Substitute the `rbs50` filename for the satellite.)

Power-cycle the Orbi when prompted. Expected timeline: ~60–90 s of
upload + verify, then the unit reboots into OpenWrt. `nmrpflash` will
exit 0 on success.

After the reboot, OpenWrt comes up at `192.168.1.1` on the LAN port
with no root password. **Set a root password immediately** — until
you do, anyone on that Ethernet segment can ssh in as root with no
auth.

```fish
ssh root@192.168.1.1
# in the OpenWrt shell:
passwd
exit
```

Capture post-flash facts back into the README's "Post-flash facts"
section for that unit:

```fish
ssh root@192.168.1.1 'cat /etc/openwrt_release; uname -a; ip a; iw dev'
```

Power off, label the unit "OpenWrt <ver> <YYYY-MM-DD>", set aside.
Repeat section 3 + 4 for the second unit.

## 5. Fallback: `debug.htm` partition flip + OEM web upload

Use only if `nmrpflash` won't detect the unit or won't finish a flash.
Stock Orbi firmware always writes incoming flashes to the **inactive**
partition; flipping which partition is active first is what makes the
OEM web upload land where it'll boot.

1. Connect to the Orbi on its current stock IP.
2. Browse to `http://<orbi-ip>/debug.htm` and check the box that
   enables telnet.
3. `telnet <orbi-ip>` (no auth on debug-enabled stock).
4. In the telnet shell:

   ```sh
   artmtd -w boot_part 02
   reboot
   ```

   The `02` flips the active partition. After the reboot the Orbi will
   boot from the previously-inactive image.
5. Browse to the OEM Orbi web UI → Firmware Update → upload the
   OpenWrt factory `.img` for this unit.
6. Wait for reboot. OpenWrt comes up at `192.168.1.1` as in section 4.
   Set the root password, capture post-flash facts, label the unit.

## 6. Last-resort: rollback to stock

Per-unit pre-flash backups were skipped. To roll back: download the
current stock firmware from Netgear's support page for the model
(`https://www.netgear.com/support/product/<model>` → Downloads), then
`nmrpflash` it back the same way as section 4:

```fish
sudo nmrpflash -i <iface> -f ~/Downloads/<stock-firmware>.img
```

If `nmrpflash` and the `debug.htm` fallback both refuse to flash a
specific unit, stop. Serial console (TTL UART headers on the PCB) is
the next step but it requires opening the case and warrants a fresh
discussion.
