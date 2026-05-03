# Plan: rb5009 VLAN + DHCP + firewall buildout

> **Historical.** The original buildout plan; substantively shipped during the
> IaC pass. Live intent now lives in [`config.rsc`](config.rsc); operational
> notes in [`README.md`](README.md). Kept for context on the original
> motivations, ordering, and per-step rationale.

## Context

Omada controller and APs are set up: two EAP770s adopted, mesh formed on
6 GHz, three client SSIDs (`plumtree`, `plumtree-guest`, `plumtree-iot`)
created with VLAN tags 10/20/30 on the Omada side. Clients can associate
but no DHCP / no internet — the rb5009 doesn't have those VLANs yet.

End state for this pass:

- ether1 (the only 2.5 GbE port) = trunk to root AP: untagged 88 (mgmt) +
  tagged 10/20/30.
- ether2 = monkeybrains WAN (DHCP client + masquerade). Currently no link;
  config is set up so plugging it in Just Works.
- sfp-sfpplus1 = future sonic WAN (~10 Gbps). Not configured yet — when
  sonic is provisioned, mirror the ether2 setup on this port.
- ether8 = Mac (en7), stays untagged 88, controller traffic.
- ether3–7 = unused, stay in bridge as untagged 88.
- VLAN interfaces vlan10/20/30 on the bridge with router IPs `.1`, DHCP
  servers, DNS pointing back to the router.
- Inter-VLAN firewall: guest fully isolated from internal, iot one-way
  (plumtree can reach iot, iot cannot initiate to plumtree).
- Single-WAN routing today (everything out monkeybrains). Per-SSID WAN
  failover (plumtree → sonic primary, guest/iot → monkeybrains primary) is
  a *later* pass once sonic exists.

## Current state of the rb5009

Per the user: close to factory config + one DHCP reservation for the Omada
controller (`192.168.88.251` / VM MAC `52:55:55:ca:b3:fb`). Factory defconf
has ether1 as WAN, ether2–8 + sfp-sfpplus1 in `bridge` with
`192.168.88.0/24`.

Access: SSH (user preference). Pasteable RouterOS commands.

## IP / VLAN scheme

| VLAN | Name        | Subnet           | Gateway        | DHCP pool                       |
|------|-------------|------------------|----------------|---------------------------------|
| 88   | management  | 192.168.88.0/24  | 192.168.88.1   | (factory; controller reservation already exists) |
| 10   | plumtree    | 192.168.10.0/24  | 192.168.10.1   | 192.168.10.10–192.168.10.250    |
| 20   | guest       | 192.168.20.0/24  | 192.168.20.1   | 192.168.20.10–192.168.20.250    |
| 30   | iot         | 192.168.30.0/24  | 192.168.30.1   | 192.168.30.10–192.168.30.250    |

## Sequence of operations

Each step is its own paste-able block. Verify SSH still works between
steps. Use Ctrl+X (RouterOS safe-mode) before the bridge-vlan-filtering
step — auto-revert on disconnect is the cheap safety net.

1. **Backup + export.** `/system backup save name=before-vlans
   dont-encrypt=yes` then `/export hide-sensitive`. Paste the export back
   to the assistant; the next steps are written against actual state, not
   assumed defconf.
2. **WAN reassignment.** Move DHCP-client + WAN list membership from
   ether1 to ether2. Remove ether1 from defconf-detect.
3. **Bridge restructure.** Pull ether2 and sfp-sfpplus1 out of `bridge`;
   add ether1 in (still no VLAN filtering yet).
4. **VLAN setup, two halves:**
   - 4a. Create `/interface vlan` entries vlan10/20/30 on bridge.
   - 4b. Populate `/interface bridge vlan` table with VLAN 88 (untagged on
     ether1,3–8; tagged on bridge) and VLANs 10/20/30 (tagged on
     bridge,ether1).
   - 4c. Set PVID=88 on every bridged port.
   - 4d. **Enable bridge vlan-filtering=yes (under safe-mode).** Test SSH
     stays alive on 192.168.88.1, then commit safe-mode.
5. **L3 + DHCP + DNS for new VLANs.** IPs on vlan10/20/30, DHCP pools, DHCP
   servers + networks (DNS = the gateway IP). Add vlan10/20/30 to the LAN
   interface list so input chain firewall lets DNS through.
6. **Inter-VLAN firewall.** Add forward-chain drops:
   - `in-interface=vlan20 out-interface-list=LAN action=drop` (guest blocked
     from all internal)
   - `in-interface=vlan30 out-interface=bridge action=drop` (iot blocked
     from mgmt)
   - `in-interface=vlan30 out-interface=vlan10 connection-state=new
     action=drop` (iot can't initiate to plumtree; established return from
     plumtree-initiated flows still works via the existing accept rule)
   - `in-interface=vlan30 out-interface=vlan20 action=drop` (iot blocked
     from guest, cleanliness)

   Default end-of-chain accept handles trusted → iot, all → WAN, etc.

7. **Physical move.** Power down the root AP, move its cable from its
   current bridge port to ether1, power back up. Verify in the controller:
   AP reconnects, SSIDs broadcast, clients on each SSID get IPs from the
   right pool, inter-VLAN policy actually blocks what it should
   (`plumtree-guest` client → ping `192.168.10.1` should fail; ping
   `8.8.8.8` should work once monkeybrains is up).

## Immediate next action when this work resumes

Run on the rb5009:

```
/system backup save name=before-vlans dont-encrypt=yes
/export hide-sensitive
```

Paste the export output back to the assistant. The remaining steps are
written against the actual state once that's seen. The export is large but
`hide-sensitive` strips passwords and keys, so it's safe to paste.

## Verification (end of pass)

- `/interface bridge vlan print` — see VLAN entries match the table above.
- `/ip address print` — vlan10/20/30 each have a `.1/24`.
- Connect a client to each SSID, confirm IP from the right pool.
- From a guest client: `ping 192.168.88.1` and `ping 192.168.10.1` should
  both fail; DNS lookups succeed.
- From a plumtree client: `ping 192.168.30.x` (some iot device) should
  succeed; from that iot device, attempting to ping the plumtree client
  should fail.
- Once monkeybrains is plugged into ether2: `ping 8.8.8.8` from a client on
  any SSID succeeds, with the source NAT'd via ether2.

## Out of scope for this pass

- Per-SSID WAN failover routing. Needs sonic to exist first. Will use
  mangle marks + routing tables. Plan that as a separate doc once sonic
  comes online.
- IPv6. Factory defconf has it off; revisit if/when an ISP hands out an
  IPv6 prefix.
- Wireguard / VPN access from outside.
