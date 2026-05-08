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

- A dedicated bench Ethernet path on a USB-Ethernet adapter. Any
  adapter is fine as long as the cable goes only from the Mac to the
  Orbi (NMRP needs an isolated L2 segment, so this can't ride on the
  same cable as the live plumtree LAN). The `en7` USB adapter that
  used to bridge to the rb5009 / retired colima software controller is
  fair game now that the macos-software path is dormant.

  ```fish
  ifconfig | grep -E '^en[0-9]+:'
  # if you plugged in a fresh adapter, note the newly appeared entry;
  # otherwise the existing en7 is fine.
  ```

- One Cat5e+ cable, plugged into the LAN port nearest the power button
  on the Orbi. (The WAN-labeled port doesn't carry NMRP.)

## 2. Image selection

Confirm the current stable release at <https://downloads.openwrt.org/releases/>
at flash time. As of 2026-05-07 the latest is **25.12.3**.

Important deviations from earlier docs:

- **Subtarget is `generic`, not `mmc`.** The `mmc` subtarget was folded
  into `generic` before 25.x. Use `targets/ipq40xx/generic/`.
- **Image filenames have no `-v1` suffix.** OpenWrt only supports the v1
  hardware (RBR50/RBS50 v2 use a different SoC and live in a different
  target entirely), so the filenames are unambiguously v1.

Filenames (substitute `<ver>`):

- `openwrt-<ver>-ipq40xx-generic-netgear_rbr50-squashfs-factory.img`
- `openwrt-<ver>-ipq40xx-generic-netgear_rbs50-squashfs-factory.img`

Download both into `~/Downloads/` (we don't store firmware in this
repo). Verify against the published `sha256sums` file in the same
release directory:

```fish
cd ~/Downloads
curl -O https://downloads.openwrt.org/releases/<ver>/targets/ipq40xx/generic/openwrt-<ver>-ipq40xx-generic-netgear_rbr50-squashfs-factory.img
curl -O https://downloads.openwrt.org/releases/<ver>/targets/ipq40xx/generic/openwrt-<ver>-ipq40xx-generic-netgear_rbs50-squashfs-factory.img
curl -O https://downloads.openwrt.org/releases/<ver>/targets/ipq40xx/generic/sha256sums
shasum -a 256 -c sha256sums --ignore-missing
# expect "OK" lines for both factory images
```

### Last flash (record here for traceability)

- 2026-05-07: OpenWrt **25.12.3** (`r32912-6639b15f62`), kernel 6.12.85,
  flashed to both RBR50 v1 and RBS50 v1. SHA256 verification for both
  factory images: OK.

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

3. **There is no separate `nmrpflash` probe step.** `nmrpflash -L` only
   lists the local Mac's interfaces — it does not detect devices on the
   wire. Detection happens inside the real flash command (section 4):
   `nmrpflash` waits for the Orbi's NMRP advertisement, prints the
   detected MAC, then uploads the image. So treat section 4 itself as
   the "is the Orbi reachable in NMRP mode" test, not a separate probe.

## 4. Flash

Power off the Orbi first, start `nmrpflash` (it'll hang on
`Advertising NMRP server on <iface>`), then power on the Orbi —
`nmrpflash` needs to be listening before the Orbi enters its brief
NMRP-advertise window during boot:

```fish
sudo nmrpflash -i <iface> \
  -f ~/Downloads/openwrt-<ver>-ipq40xx-generic-netgear_rbr50-squashfs-factory.img
```

(Substitute the `rbs50` filename for the satellite.)

Expected sequence:

```
Advertising NMRP server on <iface> ... -
Received configuration request from <mac>.
Sending configuration: 10.x.y.z/24.
Received upload request: filename 'firmware'.
Uploading openwrt-...-factory.img ...  OK (<bytes>)
Waiting for remote to respond.
Remote finished. Closing connection.
Reboot your device now.
```

Power-cycle the Orbi when prompted. ~30–60 s later it boots into
OpenWrt. `nmrpflash` exits 0 on success.

After the reboot, OpenWrt comes up at `192.168.1.1` on the LAN port
with no root password. **Set a root password immediately** — until
you do, anyone on that Ethernet segment can ssh in as root with no
auth. Also clear any stale 192.168.1.1 host key from `known_hosts`
first so the new fingerprint is picked up cleanly:

```fish
ssh-keygen -R 192.168.1.1
ssh root@192.168.1.1
# in the OpenWrt shell:
passwd
exit
```

Then install the same admin SSH pubkey we use on the rb5009 — OpenWrt
runs dropbear, so authorized keys live at `/etc/dropbear/authorized_keys`,
not the OpenSSH `~/.ssh/authorized_keys`:

```fish
cat ~/network-management/mikrotik-router/gkanapathy-mbpmx.pub | \
  ssh root@192.168.1.1 'cat >> /etc/dropbear/authorized_keys && chmod 600 /etc/dropbear/authorized_keys'
```

Capture post-flash facts back into the README's "Post-flash facts"
section for that unit:

```fish
ssh root@192.168.1.1 'cat /etc/openwrt_release; uname -a; ip a; iw phy | grep -E "^Wiphy|^\s+Band"'
ssh root@192.168.1.1 'for p in /sys/class/ieee80211/phy*; do echo "$(basename $p): $(cat $p/macaddress)"; done'
```

Note: `iw dev` returns nothing on a freshly-flashed unit because the
auto-generated `/etc/config/wireless` ships with every `wifi-iface`
having `option disabled '1'` — no enabled iface, no netdev. The phys
themselves are alive (`iw phy` and `/sys/class/ieee80211/` confirm
this); broadcasting an SSID is a config step in the integration phase.

Note: `opkg` is gone in 25.x. The package manager is now `apk` (the
Alpine one). Use `apk list -I` instead of `opkg list-installed`.

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
