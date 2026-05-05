# Plan: Run TP-Link Omada Controller on M1 Max via Colima

## Context

You want to run the TP-Link Omada Controller, but TP-Link only ships native binaries
for Windows/Linux on x86_64. The community image at
[mbentley/docker-omada-controller](https://github.com/mbentley/docker-omada-controller)
solves both problems: it packages the controller in a container **and publishes
multi-arch images including native `linux/arm64`**, so no QEMU emulation is needed
on Apple Silicon. Your environment already has Docker Desktop 29.4.1, Colima 0.10.1,
and Lima 2.1.1 installed; the working directory `/Users/gkanapathy/runcontainers` is
empty and will hold the compose file plus persistent data.

You picked **Colima with bridged networking** + **bind-mounted data in
`/Users/gkanapathy/runcontainers`**.

## Quick answers to the questions you raised

**"Can I set the inform URL on an AP without the controller?"** Yes, three ways
(any of them lets manual adoption work without auto-discovery on the LAN):

1. **SSH into the AP** (default creds usually `admin/admin`) and run
   `set inform url https://<controller-ip>:29814/inform` — works on every Omada
   AP/switch/gateway in standalone mode. Most reliable per-device method.
2. **DHCP Option 138** — set this on your router/DHCP server to the controller's
   IP. Every Omada device that boots picks it up automatically. This is TP-Link's
   official recommendation for off-LAN controllers.
3. **TP-Link Omada / Deco app** — only useful for *standalone* configuration of
   the AP itself; it does not set the controller inform URL. Skip it for this.

That said, you went with Colima bridged networking, which is the right call —
it gives you LAN-level discovery for free and avoids per-device fiddling, so
auto-discovery should just work and you can keep manual methods (1) and (2) as
fallbacks.

## Why Colima (not Docker Desktop, not Lima alone)

- **Docker Desktop**: works for the controller process, but its VM doesn't sit on
  your LAN, so UDP broadcasts from APs (29810, 27001, 19810) never reach the
  container. Auto-discovery would be broken. Also has commercial licensing
  considerations.
- **Lima alone**: you'd manage a Linux VM and install Docker (or the controller)
  inside it manually. Maximum flexibility but more setup than you need.
- **Colima** is Lima under the hood, but it preconfigures Docker, sets up a
  docker CLI context automatically, and supports `--network-address` (via
  `socket_vmnet`) to give the VM a real LAN IP. This is the sweet spot.

## Requirements summary

| Resource | Recommendation |
|---|---|
| CPU | 2 vCPU to the Colima VM |
| RAM | 4 GB to the Colima VM, JVM heap default 1024m (the OpenJ9 image variant cuts ~30–50% RAM if you want to go lighter) |
| Disk | 60 GB to the VM; MongoDB grows over time |
| Image | `mbentley/omada-controller:6.0` (or `:6.0-openj9` for lower memory) — both are multi-arch with native `arm64` |
| Ports (TCP) | 8088 HTTP, 8043 HTTPS mgmt, 8843 user portal HTTPS, 29811–29816 device mgmt |
| Ports (UDP) | 19810, 27001, 29810 device discovery |
| Volumes | `/opt/tplink/EAPController/data`, `/opt/tplink/EAPController/logs` (and `/opt/tplink/EAPController/work` + `/opt/tplink/EAPController/backup` if you want full coverage) |

Networking gotcha: UDP discovery requires the container to receive **L2 broadcasts**
from your APs. The pattern that works with Colima is `network_mode: host` inside
the VM (the container shares the VM's network namespace, and the VM has a real
LAN IP via `socket_vmnet`). Don't try `ports:` mapping for the UDP discovery
ports — broadcasts won't traverse the NAT.

## Implementation steps (after approval)

### 1. One-time host setup

- `brew install socket_vmnet` and follow its post-install instructions
  (it needs a setuid helper; brew prints the exact `sudo` command). Verify it's
  registered as the lima default by checking `~/.lima/_config/networks.yaml`.
- Stop Docker Desktop (or at least don't rely on it for this stack), so docker
  CLI doesn't compete for the default context.

### 2. Start the Colima VM with bridged networking

```
colima start \
  --cpu 2 --memory 4 --disk 60 \
  --network-address \
  --vm-type vz --mount-type virtiofs
```

- `--network-address` enables the shared `socket_vmnet` interface; the VM gets
  a routable IP on your LAN. `colima status` will print it.
- `--vm-type vz` uses Apple's Virtualization.framework (faster on M-series),
  with `virtiofs` for fast bind mounts.
- This also sets the `colima` docker context as default, so plain `docker` and
  `docker compose` commands target this VM.

### 3. Lay out the working directory

```
/Users/gkanapathy/runcontainers/
├── docker-compose.yaml
└── omada/
    ├── data/
    ├── logs/
    ├── work/
    └── backup/
```

The `omada/` subtree is bind-mounted into the container. You'll back up `data/`
to keep your controller config.

### 4. Write `docker-compose.yaml`

Critical files to create (only one — a compose file at
`/Users/gkanapathy/runcontainers/docker-compose.yaml`):

```yaml
services:
  omada-controller:
    image: mbentley/omada-controller:6.0
    container_name: omada-controller
    restart: unless-stopped
    network_mode: host        # required for L2 UDP discovery
    environment:
      TZ: America/Los_Angeles
      JAVA_MAX_HEAP_SIZE: 1024m
      JAVA_MIN_HEAP_SIZE: 256m
      MANAGE_HTTP_PORT: 8088
      MANAGE_HTTPS_PORT: 8043
      PORTAL_HTTP_PORT: 8088
      PORTAL_HTTPS_PORT: 8843
      PORT_APP_DISCOVERY: 27001
      PORT_DISCOVERY: 29810
      PORT_MANAGER_V1: 29811
      PORT_MANAGER_V2: 29814
      PORT_ADOPT_V1: 29812
      PORT_UPGRADE_V1: 29813
      PORT_TRANSFER_V2: 29815
      PORT_RTTY: 29816
      SHOW_SERVER_LOGS: "true"
      SHOW_MONGODB_LOGS: "false"
    volumes:
      - ./omada/data:/opt/tplink/EAPController/data
      - ./omada/logs:/opt/tplink/EAPController/logs
      - ./omada/work:/opt/tplink/EAPController/work
      - ./omada/backup:/opt/tplink/EAPController/backup
```

Pin to a specific version (e.g. `:6.0.0.25`) once you're happy with one — the
floating `:6.0` tag is fine for evaluation.

### 5. First boot

```
cd /Users/gkanapathy/runcontainers
mkdir -p omada/{data,logs,work,backup}
docker compose up -d
docker compose logs -f omada-controller   # wait for "Started Omada Controller"
```

Then open `https://<colima-vm-ip>:8043/` in a browser (use `colima status` to
get the IP). Walk the setup wizard.

## Verification

End-to-end checks before you call this done:

1. **Controller reachable on LAN**: from another device on the same network,
   `https://<colima-vm-ip>:8043/` loads the wizard. (Not just `localhost`.)
2. **Persistence**: `docker compose down && docker compose up -d` — settings
   survive (the wizard does not reappear).
3. **UDP discovery wired up** (only relevant if you have an Omada AP/switch
   on the LAN): `colima ssh -- sudo tcpdump -ni any udp port 29810` should show
   discovery packets when the AP boots. If you see them, auto-discovery is live.
4. **Resource sanity**: `docker stats omada-controller` — RSS should settle
   under ~1.5 GB; if it's pinned at the ceiling, bump `JAVA_MAX_HEAP_SIZE` or
   switch to the `-openj9` image variant.

## Things to be aware of

- **macOS upgrades / restarts**: Colima needs `colima start` after a reboot
  unless you set up a launchd plist. The controller restarts inside the VM
  automatically thanks to `restart: unless-stopped`.
- **Backups**: snapshot `/Users/gkanapathy/runcontainers/omada/data` (and
  `backup/`) periodically. The controller can also export config from the UI.
- **Upgrades**: bump the image tag in `docker-compose.yaml`, then
  `docker compose pull && docker compose up -d`. Read mbentley's release notes
  before major version jumps (5.x → 6.x required a one-shot data migration).
- **Inform URL after move**: if you ever change the host's LAN IP, devices
  already adopted will lose contact. Either keep the IP static (DHCP
  reservation) or use a hostname + DHCP Option 138.
- **Docker Desktop coexistence**: keep it stopped or remember which docker
  context is active (`docker context ls`). Mixing the two leads to "where did
  my container go?" confusion.
