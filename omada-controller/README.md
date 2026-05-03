# Omada Controller

Self-hosted TP-Link Omada Controller running in a container on Apple Silicon
via Colima. Bridged onto the Omada management LAN (`192.168.88.0/24`) so the
EAPs auto-discover the controller via UDP broadcasts.

## What's running

- **Colima VM** (vz, 2 CPU / 4 GB / 60 GB disk), bridged to host interface
  `en7` (USB Ethernet → MikroTik on 192.168.88.0/24).
- **`omada-controller` container** — `mbentley/omada-controller:6.2` (native
  arm64), `network_mode: host` so it sees L2 broadcasts. The compose file
  sets `stop_grace_period: 60s` so MongoDB has time to shut down cleanly on
  any `docker compose down` / recreate (default 10s risks DB corruption).
- **Persistent data**: `./omada/{data,logs,work,backup}` (bind-mounted into
  the container).

## URLs

| URL | Purpose |
|---|---|
| <https://192.168.88.251:8043/> | Management UI (HTTPS) |
| <http://192.168.88.251:8088/>  | Redirects to HTTPS |
| <https://192.168.88.251:8843/> | Captive-portal HTTPS (for guest networks) |

The IP is reserved on the MikroTik for the VM MAC `52:55:55:ca:b3:fb`. If
that reservation is removed, the VM will get a different DHCP lease and
adopted APs (which cache the URL) will lose contact — re-adopt via the
controller UI or fall back to "Set inform URL" on each AP.

## Start / stop

The Mac does **not** auto-start Colima after a reboot. To bring everything up:

```sh
colima start                # uses last config (bridged to en7)
docker compose -f /Users/gkanapathy/network-management/omada-controller/docker-compose.yaml up -d
```

The container has `restart: unless-stopped`, so it comes back automatically
whenever the VM is running.

To stop:

```sh
docker compose -f /Users/gkanapathy/network-management/omada-controller/docker-compose.yaml down
colima stop
```

To check status:

```sh
colima status
docker ps
docker compose -f /Users/gkanapathy/network-management/omada-controller/docker-compose.yaml logs -f
```

## Day-to-day operations

- **Adopt a new AP**: plug it into the 192.168.88.0/24 LAN. Within ~30s it
  broadcasts on UDP 29810 and appears in the controller UI under **Devices**
  as *Pending*. Click *Adopt*.
- **Backups**: snapshot `./omada/data` and `./omada/backup` (or use the UI's
  *Maintenance → Backup & Restore*).
- **Upgrade**: see the dedicated [Upgrades](#upgrades) section below.
- **Resource sanity**: `docker stats omada-controller`. RSS settles around
  ~1.5 GB; if it pins at the 4 GB ceiling, raise `JAVA_MAX_HEAP_SIZE` in
  the compose file or switch to the `:6.0-openj9` image variant.

## Upgrades

**Always upgrade by replacing the image, never via the controller UI** — the
binary lives inside an immutable image layer, so an in-app upgrade either
fails or gets clobbered the next time the container is recreated.

mbentley publishes multi-arch tags (native arm64) on Docker Hub:

| Tag | Tracks |
|---|---|
| `:6` | latest v6 (currently 6.2.x) |
| `:6.2`, `:6.1`, `:6.0` | latest patch on that minor |
| `:6.2.10.17` (etc.) | pinned exact version |
| `:latest` | currently v5 — **don't use** for this controller |

`-openj9` variants (e.g. `:6.2-openj9`) trade ~30–50% RAM for slightly
slower startup.

Procedure:

```sh
# 1. Take a UI backup: Settings → Maintenance → Backup & Restore (download)
# 2. Optionally snapshot the data dir for fast rollback:
cp -a omada/data omada/data.bak-pre-<version>

# 3. Edit docker-compose.yaml — change the image tag, e.g. :6.2 → :6.3

docker compose pull
docker compose stop                           # uses 60s grace period from compose
docker compose up -d
docker compose logs -f omada-controller       # wait for "Omada Controller started"
```

Within v6.x no special migration is needed — the controller runs DB schema
upgrades on first boot and logs e.g. `DB version from 6.0.0 to 6.2.12`.
Major-version jumps (5.x → 6.x) historically required a one-shot migration
container; check mbentley's release notes before crossing one.

To roll back: `docker compose stop`, restore `omada/data` from the snapshot,
flip the image tag back, `docker compose up -d`.

## After a Mac reboot

`colima start` is enough — the static netplan override and the bridged
network config persist on the VM disk. The `--network-mode bridged
--network-interface en7` settings are remembered from the last `colima start`.

## Troubleshooting

**APs don't show up as pending:**

1. Confirm the VM is bridged to the right interface:
   `ps aux | grep socket_vmnet` — look for `--vmnet-interface en7`.
2. Confirm the VM has a `192.168.88.x` IP on `col0`:
   `colima ssh -- ip -4 addr show col0`.
3. Confirm packets are arriving:
   `colima ssh -- sudo tcpdump -ni col0 'udp port 29810'` —
   each EAP broadcasts once every ~30s.
4. If broadcasts arrive but APs aren't *pending*, restart the controller:
   `docker compose restart omada-controller`.

**Manual adoption (if discovery is broken):** SSH to the AP (default creds
`admin`/`admin` in standalone state) and run:
```
set inform url https://192.168.88.251:29814/inform
```
Or set DHCP option 138 → `192.168.88.251` on the MikroTik for fleet-wide
auto-pointing.

**Bridged interface lost its IP / DHCP failing:** edit
`/etc/netplan/50-cloud-init.yaml` inside the VM (`colima ssh`) or drop a
static override in `/etc/netplan/99-static-col0.yaml`, then `sudo netplan
apply`.

## Files in this directory

```
docker-compose.yaml   # container definition (host network, bind mounts)
omada/data/           # MongoDB + controller config — back this up
omada/logs/           # controller + mongod logs
omada/work/           # transient working state
omada/backup/         # UI-triggered backups land here
PLAN.md               # original design + reasoning
README.md             # this file
```

## Networking notes (why it's wired this way)

- `network_mode: host` is required because Omada device discovery uses L2
  UDP broadcasts that don't traverse Docker NAT.
- The Colima VM is bridged via socket_vmnet to **en7** (Ethernet to the
  Omada LAN), not en0 (Wi-Fi). Bridged-over-Wi-Fi on Apple Silicon doesn't
  get DHCP responses — APs on en7 are reachable; APs on en0 wouldn't be.
- `socket_vmnet` itself lives at `/opt/socket_vmnet/bin/` (root-owned),
  with a sudoers rule at `/etc/sudoers.d/lima` for non-interactive launch.
