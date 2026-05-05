# rb5009 — IPv6 enablement plan

This document is the working plan for adding IPv6 to every VLAN on the
rb5009. Live router intent remains [`config.rsc`](config.rsc) until a
future apply incorporates the steps below.

## Terms

- **ULA (Unique Local Address):** Private IPv6 space (`fd00::/8`), not
  routed on the public Internet. Lets you run IPv6 internally without
  waiting for the ISP.
- **PD (Prefix Delegation):** The ISP (via DHCPv6-IA_PD) delegates a
  prefix to your router; you sub-allocate `/64`s per VLAN for global IPv6.

## Current baseline

- IPv4 only on `vlan88` / `vlan10` / `vlan20` / `vlan30`; WAN is DHCP on
  `ether2`.
- `/ipv6 firewall` rules exist (defconf-style hardening) but IPv6 is not
  actively addressed on LAN VLANs.
- Management services already allow `fe80::/10` in `address=` alongside
  RFC1918 nets so **link-local SSH recovery** in [`README.md`](README.md)
  stays valid.

## Phase A — ULA on all VLANs (no ISP dependency)

### 1. Choose a ULA /48

Per RFC 4193, pick a random **`fd00::/8` ULA `/48`** before implementation
(do not copy documentation examples blindly). One way: roll 40 bits of
randomness after `fd` and format as `fdXX:XXXX:XXXX::/48`.

The **subnet ID** (next 16 bits after the /48) can follow a mnemonic so each
VLAN maps to one `/64`:

| VLAN | Role     | Example subnet (replace prefix with yours) | Router address (typical) |
|------|----------|----------------------------------------------|---------------------------|
| 88   | mgmt     | `fdXX:XXXX:XXXX:88::/64`                     | `...::1/64`               |
| 10   | plumtree | `fdXX:XXXX:XXXX:10::/64`                     | `...::1/64`               |
| 20   | guest    | `fdXX:XXXX:XXXX:20::/64`                     | `...::1/64`               |
| 30   | iot      | `fdXX:XXXX:XXXX:30::/64`                     | `...::1/64`               |

Implement with **`/ipv6 address add address=<...::1/64> interface=vlanNN`**
on each VLAN interface (same interfaces as IPv4).

### 2. Router advertisement (SLAAC + DNS)

On each VLAN, configure **`/ipv6 nd`** so hosts autoconfigure and learn DNS:

- Enable RA on `vlan88`, `vlan10`, `vlan20`, `vlan30`.
- Set **RDNSS** to the router’s ULA on that VLAN (`...::1`) so clients use
  the router as resolver (same role as IPv4 DHCP “DNS = gateway”).
- If you use non-default MTU on WAN, set consistent **MTU** hints where
  RouterOS exposes them.

### 3. Optional DHCPv6

**`/ipv6 dhcp-server`** (stateless or stateful) is optional for Phase A.
Add it if you want reservations or hostname behavior analogous to IPv4
leases.

### 4. Static DNS name for the router

Mirror the existing `router.lan` A record: add **`type=AAAA`** in
`/ip dns static` pointing at the router’s ULA (mgmt `vlan88` is the natural
choice for a single name).

### 5. Default route expectation

In ULA-only mode there may be **no default IPv6 route**; that is expected.
Hosts still get ULA for internal traffic and for validating firewall rules.

### Phase A checklist

- [ ] Generated own ULA `/48`; documented final hex in this file or in
      `config.rsc` comments.
- [ ] `/ipv6 address` on `vlan88`, `vlan10`, `vlan20`, `vlan30`.
- [ ] `/ipv6 nd` per VLAN with RDNSS.
- [ ] `router.lan` AAAA static entry.
- [ ] Smoke test: each SSID obtains an address in the expected `/64`.

## Phase B — WAN prefix delegation (when ISP supports IA_PD)

### 1. Confirm PD on ether2

On the live router (before baking into `config.rsc`):

- Add **`/ipv6 dhcp-client`** on `ether2` with `request=prefix` (exact
  property names: verify with `/ipv6 dhcp-client print` and RouterOS docs
  for your minor version).
- Inspect **`/ipv6 dhcp-client print detail`** and pool/prefix assignment.

If no prefix appears, **stop**: stay on Phase A until the ISP or a
different WAN offers PD.

### 2. Pool and per-VLAN global /64

Preferred shape:

- Create an **`/ipv6 pool`** fed by the delegated prefix.
- Assign **global `/64`s** to each VLAN from that pool (RouterOS 7 pattern:
  verify `from-pool=` / equivalent on your installed version).

Goal: clients get **global unicast** addresses and route to the internet
without NPT/NAT66.

### 3. Fallback if PD is awkward

If the ISP only delegates a single `/64` or an odd length, document the
actual lease, then evaluate **NPTv6** or a constrained layout. Avoid NAT66
unless required; capture the chosen design in this file when you hit that
case.

### 4. Default IPv6 route

Once a global prefix works on WAN, ensure **`::/0`** is installed via the
DHCP client or static route as appropriate, then re-test `ping6` to a
global target from plumtree, guest, and iot.

### Phase B checklist

- [ ] PD visible on `ether2`; pool created.
- [ ] Global `/64` per VLAN (or documented exception).
- [ ] Default IPv6 route present; global `ping6` works where policy allows.
- [ ] Optional second `router.lan` AAAA for global if you publish global on
      the router.

## IPv6 firewall parity with IPv4

Today’s `/ipv6 firewall filter` does not encode inter-VLAN policy. Before
treating IPv6 as production, add **forward** rules mirroring IPv4 in
`config.rsc`:

- Guest (`vlan20`) → all LAN: **drop**.
- IoT (`vlan30`) → mgmt (`vlan88`): **drop**.
- IoT → plumtree (`vlan10`): **drop** new connections (same
  `connection-state=new` pattern as IPv4 so return traffic from
  plumtree-initiated flows still works).
- IoT → guest (`vlan20`): **drop**.

Place these **before** any broad “drop everything not from LAN” rules so
ordering matches IPv4 intent.

**ICMPv6:** Keep essential **Neighbor Discovery** working (RS/RA/NS/NA);
the existing `protocol=icmpv6` accept rules usually suffice—verify after
changes.

**NAT:** Do **not** add `/ipv6 firewall nat` unless you explicitly adopt
NPTv6/NAT66.

## Omada / APs

SSIDs already map to VLANs 10/20/30; APs bridge IPv6 like IPv4. If the
controller exposes per-SSID IPv6 toggles, leave them consistent with “RA
from the gateway” unless you have a reason to override.

## Where to edit in `config.rsc` (future apply)

Rough insertion order for the eventual script (exact lines will shift):

1. After IPv4 `/ip address` (or parallel block): **`/ipv6 address`** ULA
   (and later global from pool).
2. After WAN `dhcp-client` block: **`/ipv6 dhcp-client`** for PD when ready.
3. Near DNS static: **AAAA** for `router.lan`.
4. **`/ipv6 nd`** after addresses exist on each VLAN.
5. **`/ipv6 firewall filter`**: inter-VLAN drops aligned with IPv4.

Always follow the apply workflow in [`README.md`](README.md): stage file,
`:parse` pre-flight, reset+import, confirm `config.rsc: done` in the log.

## Verification commands

After apply (subset):

```text
/ipv6 address print
/ipv6 nd print
/ipv6 dhcp-client print detail
/ipv6 firewall filter print
/ping 2606:4700:4700::1111
```

From clients: `ping6` to ULA gateway, then (Phase B) to a global address.

## Risks

- **ISP unknowns:** PD may be absent or sized poorly; Phase B is conditional.
- **Firewall ordering:** Mistakes black-hole IPv6 or break ND; test from
  each SSID after changes.
- **RouterOS schema:** Verify every `set`/`add` property on the running
  version before relying on it in `config.rsc` (see README “Common
  pitfalls”).

## Out of scope here

- Sonic second WAN or per-SSID IPv6 policy (see project `CLAUDE.md`).
- Changing `config.rsc` in this pass — that is a separate apply after you
  are satisfied with lab verification.
