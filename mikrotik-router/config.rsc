# rb5009 — target configuration. Source of truth.
# Apply via wipe + import; see README.md.
#
# Topology:
#   ether1        trunk to root AP — untagged 88 (mgmt) + tagged 10/20/30
#   ether2        WAN (monkeybrains, DHCP client)
#   ether3-7      bridge access ports, untagged VLAN 88 (mgmt)
#   ether8        bridge access port, untagged VLAN 88 — Mac (en7) + colima
#   sfp-sfpplus1  WAN (sonic, DHCP client)
#
# VLANs (all L3 lives on /interface vlan; never on bridge directly):
#   88   mgmt      192.168.88.0/24    fd7f:aee1:6ce0:88::/64    vlan88
#   10   plumtree  192.168.10.0/24    fd7f:aee1:6ce0:10::/64    vlan10
#   20   guest     192.168.20.0/24    fd7f:aee1:6ce0:20::/64    vlan20
#   30   iot       192.168.30.0/24    fd7f:aee1:6ce0:30::/64    vlan30
#
# Firewall policy (forward chain):
#   - guest fully isolated from internal (all LAN VLANs blocked, WAN allowed)
#   - iot one-way: plumtree -> iot allowed; iot -> plumtree only on est/related
#   - iot blocked from mgmt, guest

:log info "config.rsc: starting"

# --- identity ---
/system identity
set name=plumtree-rtr

# --- IP-stack hardening ---
# Defconf doesn't touch /ip settings; defaults are too lax. Safe in a
# single-WAN topology with no asymmetric routing — revisit when sonic
# comes online and per-SSID failover may introduce asymmetry.
/ip settings
set rp-filter=strict tcp-syncookies=yes send-redirects=no

# --- LEDs + reset-button-press toggle ---
# Default: turn off the front-panel LEDs after 1h of uptime. Lets us
# see boot health visually for the first hour, then dark.
/system leds settings
set all-leds-off=after-1h

# Bind a brief (<2s) press of the front Reset button — only while
# RouterOS is running, so it doesn't interfere with the boot-time
# factory-reset / netinstall behavior — to a script that toggles the
# LEDs between "on permanently" (never) and "off immediately"
# (immediate). Useful for visual inspection without re-applying config.
# The toggle persists until the next reset+replay, which restores
# all-leds-off=after-1h.
/system script
:if ([:len [/system/script/find name=toggle-leds]] > 0) do={
    /system/script/remove [find name=toggle-leds]
}
add name=toggle-leds source={
    :local cur [/system/leds/settings/get all-leds-off]
    :if ($cur = "never") do={
        /system/leds/settings/set all-leds-off=immediate
    } else={
        /system/leds/settings/set all-leds-off=never
    }
}
/system routerboard reset-button
set enabled=yes hold-time=0s..2s on-event=toggle-leds

# --- timezone + NTP ---
# Pin time-zone explicitly; turn off autodetect (which uses IP-geolocation
# via a MikroTik service over the WAN). Router is stationary, so we don't
# need autodetect, and pinning avoids a surprise override if the geo
# lookup ever decides we're somewhere else.
/system clock
set time-zone-autodetect=no time-zone-name=America/Los_Angeles
# NTP via Cloudflare + Google anycast. Defaults to unicast mode.
/system ntp client
set enabled=yes servers=time.cloudflare.com,time.google.com

# --- bridge (vlan-filtering enabled at the END after VLAN table is populated) ---
/interface bridge
add admin-mac=04:F4:1C:51:BA:D8 auto-mac=no name=bridge

# --- bridge ports ---
# ether1 = trunk, others = access ports on VLAN 88. PVID=88 stamps untagged ingress.
# Access ports get bpdu-guard=yes edge=yes: a downstream device sending BPDUs
# (rogue switch / malicious endpoint) gets the port disabled instantly. ether1
# is the trunk to the AP and intentionally not bpdu-guarded — the AP could
# legitimately speak STP.
/interface bridge port
add bridge=bridge interface=ether1 pvid=88 comment="trunk to root AP"
add bridge=bridge interface=ether3 pvid=88 bpdu-guard=yes edge=yes
add bridge=bridge interface=ether4 pvid=88 bpdu-guard=yes edge=yes
add bridge=bridge interface=ether5 pvid=88 bpdu-guard=yes edge=yes
add bridge=bridge interface=ether6 pvid=88 bpdu-guard=yes edge=yes
add bridge=bridge interface=ether7 pvid=88 bpdu-guard=yes edge=yes
add bridge=bridge interface=ether8 pvid=88 bpdu-guard=yes edge=yes

# --- VLAN L3 sub-interfaces on the bridge ---
# All L3 (including mgmt) lives on /interface vlan; nothing on bridge directly.
# When vlan-filtering=yes, frames tagged with VID X reach IP only via the matching
# /interface vlan VID=X. Putting an IP on the bridge interface itself would never
# receive tagged-on-bridge VLAN traffic.
/interface vlan
add interface=bridge name=vlan88 vlan-id=88 comment=mgmt
add interface=bridge name=vlan10 vlan-id=10 comment=plumtree
add interface=bridge name=vlan20 vlan-id=20 comment=guest
add interface=bridge name=vlan30 vlan-id=30 comment=iot

# --- bridge VLAN table ---
# VLAN 88 (mgmt): tagged on bridge (CPU), untagged on all access + trunk
# VLAN 10/20/30:  tagged on bridge + ether1 (trunk only); other ports never see them
/interface bridge vlan
add bridge=bridge tagged=bridge,ether1 vlan-ids=10
add bridge=bridge tagged=bridge,ether1 vlan-ids=20
add bridge=bridge tagged=bridge,ether1 vlan-ids=30
add bridge=bridge tagged=bridge untagged=ether1,ether3,ether4,ether5,ether6,ether7,ether8 vlan-ids=88

# --- interface lists ---
# LAN list drives input firewall + inter-VLAN drops. All four VLAN sub-interfaces.
/interface list
add name=WAN
add name=LAN
/interface list member
add interface=vlan88 list=LAN
add interface=vlan10 list=LAN
add interface=vlan20 list=LAN
add interface=vlan30 list=LAN
add interface=ether2 list=WAN
add interface=sfp-sfpplus1 list=WAN

# --- routing tables for Stage 2 source-based PBR ---
# mb and sonic are selected by /routing rule (below) based on src-address
# per LAN VLAN. Each table carries both 0.0.0.0/0 entries (local WAN d=1,
# other WAN d=2) so a WAN failure falls through within the table.
# `fib` is a flag (not `fib=yes`) in RouterOS 7.21.4 — the assignment
# form parses as "expected end of command" and aborts the import.
# (Historically that aborted-mid-import locked us out by skipping the
# vlan-filtering=yes line that used to sit at the bottom of this file;
# that line has since moved up to after /ip service for partial-apply
# lockout safety, so this failure mode is less severe, but still
# avoid.) Discovered 2026-05-21 after two failed Stage 2 apply
# attempts.
/routing table
add name=mb    fib
add name=sonic fib

# --- L3 addresses (all on VLAN sub-interfaces) ---
/ip address
add address=192.168.88.1/24 interface=vlan88 network=192.168.88.0
add address=192.168.10.1/24 interface=vlan10 network=192.168.10.0
add address=192.168.20.1/24 interface=vlan20 network=192.168.20.0
add address=192.168.30.1/24 interface=vlan30 network=192.168.30.0

# --- IPv6 ULA addresses (Phase A — no ISP dependency) ---
# ULA /48: fd7f:aee1:6ce0::/48 — RFC 4193 random, generated 2026-05-08.
# Subnet ID is VLAN-ID-as-hex (mnemonic only): :88::/64 = mgmt, :10::/64 =
# plumtree, etc. The hex digits happen to mirror the decimal VLAN IDs;
# they are not a numeric encoding (e.g., :10:: is hex 0x10 = dec 16).
# advertise=yes makes the prefix appear in RAs (paired with /ipv6 nd below).
/ipv6 address
add address=fd7f:aee1:6ce0:88::1/64 interface=vlan88 advertise=yes
add address=fd7f:aee1:6ce0:10::1/64 interface=vlan10 advertise=yes
add address=fd7f:aee1:6ce0:20::1/64 interface=vlan20 advertise=yes
add address=fd7f:aee1:6ce0:30::1/64 interface=vlan30 advertise=yes

# --- IPv6 RA + RDNSS per VLAN (Phase A) ---
# Hosts SLAAC from the advertised /64; RDNSS points at the router's per-VLAN
# ULA ::1 so DNS lookups stay on-VLAN (no inter-VLAN firewall hop). Same role
# as IPv4 dhcp-server-network "dns-server=<gateway>".
# Default rule (interface=all) is disabled to avoid overlap with the explicit
# per-VLAN rules below; we'll add explicit rules for any future interface
# that needs RAs.
/ipv6 nd
set [find default=yes] disabled=yes
add interface=vlan88 advertise-dns=yes dns=fd7f:aee1:6ce0:88::1
add interface=vlan10 advertise-dns=yes dns=fd7f:aee1:6ce0:10::1
add interface=vlan20 advertise-dns=yes dns=fd7f:aee1:6ce0:20::1
add interface=vlan30 advertise-dns=yes dns=fd7f:aee1:6ce0:30::1

# --- admin SSH key (cold-bootstrap only) ---
# Routine reset-configuration with keep-users=yes preserves /user/ssh-keys
# from the previous apply, so re-importing each time would just be churn —
# and /user/ssh-keys/import consumes the .pub on success, forcing a re-scp
# every apply. Skip when the key is already loaded; only import on cold
# bootstrap (factory button reset / netinstall) where the user db starts
# empty. To rotate the key: SSH in, /user/ssh-keys/remove [find user=admin],
# scp the new .pub, then re-apply.
:if ([:len [/user/ssh-keys/find user=admin]] > 0) do={
    :log info "config.rsc: admin ssh key already present, skipping import"
} else={
    :if ([:len [/file/find name=gkanapathy-mbpmx.pub]] > 0) do={
        /user/ssh-keys/import public-key-file=gkanapathy-mbpmx.pub user=admin
        :log info "config.rsc: ssh key imported (cold bootstrap)"
    } else={
        :log warning "config.rsc: no admin ssh key registered and gkanapathy-mbpmx.pub absent; password fallback only"
    }
}

# SSH server hardening + behavior:
# - password-authentication=yes: keep password fallback while we iterate.
#   RouterOS default is `yes-if-no-key`, which rejects passwords once a user
#   has any registered key. Tighten back later.
# - strong-crypto=yes: prefer modern ciphers/MACs/KEX. Doesn't add
#   post-quantum KEX (RouterOS 7.21.4 has none), so OpenSSH 9.x will still
#   warn about "store now, decrypt later"; that warning won't go away until
#   MikroTik ships PQ-KEX support upstream.
# - host-key-type=ed25519: smaller, faster, modern key.
# - host-key-size=4096: dormant for ed25519, only matters if anyone ever
#   flips host-key-type back to rsa; cheap to set.
# - forwarding-enabled=no: refuse SSH-tunnel/jump-host use of the router.
# - regenerate-host-key: explicit rotation. Apply flow already does
#   `ssh-keygen -R`, so the new fingerprint is no surprise.
# Note: there is no `max-auth-tries` property on /ip ssh in 7.21.4 (that's
# OpenSSH's MaxAuthTries). Brute-force resistance lives elsewhere — we
# rely on key-only auth + service `address=` scoping below.
/ip ssh
set password-authentication=yes strong-crypto=yes host-key-type=ed25519 host-key-size=4096 forwarding-enabled=no
/ip ssh regenerate-host-key

# --- service surface ---
# Lock down management services. Bind interactive surfaces to mgmt+plumtree
# only (plus IPv6 link-local so README.md's recovery path stays usable);
# disable everything else.
# - /ip service `address=` applies to both IPv4 and IPv6 sources, so an
#   IPv4-only list would silently fence off IPv6 link-local recovery.
# - api-ssl is disabled by default (no cert); not setting it.
/ip service
set telnet disabled=yes
set ftp    disabled=yes
set api    disabled=yes
set ssh    address=192.168.88.0/24,192.168.10.0/24,fe80::/10
set winbox address=192.168.88.0/24,192.168.10.0/24,fe80::/10
set www    address=192.168.88.0/24,192.168.10.0/24,fe80::/10

# --- enable VLAN filtering (early; lockout-safety on partial apply) ---
# Hard prereq is /interface bridge vlan above (lines 107-111), which
# populates the per-port-per-VID table that vlan-filtering enforces.
# Once that's set, the bridge is safe to switch into filtering mode.
#
# This line used to live at the very END of config.rsc. Moved here on
# 2026-05-22: if a later block (DHCP, firewall, /routing rule,
# /system script, ...) errors during /import and aborts the script,
# the bridge would otherwise stay in legacy no-VLAN-tag mode, locking
# plumtree clients out of the router. Anchoring vlan-filtering=yes
# right after /ip address + /ip ssh + /ip service means SSH-via-LAN-IP
# survives partial applies, so the next "diagnose via /log/print, fix
# config.rsc, re-apply" cycle doesn't need a button-reset cold
# bootstrap. Cost two such recoveries during the Stage 2 buildout
# before this moved up.
/interface bridge
set [find name=bridge] vlan-filtering=yes

# --- DHCP pools ---
/ip pool
add name=mgmt-pool     ranges=192.168.88.10-192.168.88.254
add name=plumtree-pool ranges=192.168.10.10-192.168.10.250
add name=guest-pool    ranges=192.168.20.10-192.168.20.250
add name=iot-pool      ranges=192.168.30.10-192.168.30.250

# --- DHCP servers ---
/ip dhcp-server
add address-pool=mgmt-pool     interface=vlan88 name=mgmt-dhcp
add address-pool=plumtree-pool interface=vlan10 name=plumtree-dhcp
add address-pool=guest-pool    interface=vlan20 name=guest-dhcp
add address-pool=iot-pool      interface=vlan30 name=iot-dhcp

/ip dhcp-server network
add address=192.168.88.0/24 dns-server=192.168.88.1 gateway=192.168.88.1
add address=192.168.10.0/24 dns-server=192.168.10.1 gateway=192.168.10.1
add address=192.168.20.0/24 dns-server=192.168.20.1 gateway=192.168.20.1
add address=192.168.30.0/24 dns-server=192.168.30.1 gateway=192.168.30.1

# --- DHCP reservations ---
/ip dhcp-server lease
add address=192.168.88.252 mac-address=24:2F:D0:02:07:5A server=mgmt-dhcp comment="OC200"

# --- WAN: DHCP clients (Stage 2: add-default-route=no) ---
# Both clients still bind addresses and learn gateway from the ISP;
# /ip route below installs the per-table defaults manually with the
# literal gateways captured at Stage 0 probe D / Stage 1 bind.
# use-peer-dns=yes keeps both ISPs' resolvers in /ip dns dynamic-servers.
/ip dhcp-client
add interface=ether2       add-default-route=no use-peer-dns=yes
add interface=sfp-sfpplus1 add-default-route=no use-peer-dns=yes

# --- WAN: DHCPv6-PD clients (Stage 2: add-default-route=no) ---
# MB delegates prefix-only (probe 1, 2026-05-07); Sonic delegates
# IA_NA + IA_PD (Stage 0 probe D, 2026-05-21).
# accept-prefix-without-address=yes is required for MB, harmless on
# Sonic — keep on both for shape parity.
# pool-prefix-length=64 is the per-from-pool sub-allocation size, not an
# ISP hint — ISPs delegate whatever length they delegate.
# add-default-route=no: ::/0 entries installed manually in /ipv6 route
# below, so each routing table gets the right primary/failover pair.
# /ipv6 dhcp-client add-default-route defaults to `no` on 7.21.4
# (unlike /ip dhcp-client which defaults to yes), so the explicit `no`
# here also serves as belt-and-suspenders against future schema drift.
# use-peer-dns inherits the default `yes`, parallel to /ip dhcp-client.
/ipv6 dhcp-client
add interface=ether2       request=address,prefix pool-name=mb-pd    pool-prefix-length=64 accept-prefix-without-address=yes add-default-route=no
add interface=sfp-sfpplus1 request=address,prefix pool-name=sonic-pd pool-prefix-length=64 accept-prefix-without-address=yes add-default-route=no

# --- IPv6 GUA per VLAN, from the Monkeybrains pool (Phase B-MB) ---
# RouterOS 7.21.4 `from-pool=` semantics is prefix-only-to-interface: the
# pool's /64 is assigned to the VLAN as a network address for RA emission;
# the router gets NO host address from this entry (probe 1 confirmed several
# `address=` and `eui-64=` variants are INVALID). Clients SLAAC their own
# GUAs; the router itself stays reachable on the per-VLAN ULA ::1 (Phase A)
# and link-local. Re-derives automatically on renewal (probe 3).
/ipv6 address
add from-pool=mb-pd interface=vlan88 advertise=yes
add from-pool=mb-pd interface=vlan10 advertise=yes
add from-pool=mb-pd interface=vlan20 advertise=yes
add from-pool=mb-pd interface=vlan30 advertise=yes

# --- WAN default routes per routing table (Stage 2) ---
# Six routes total (3 tables × 2 WANs):
#   main : router-originated traffic + LAN dsts via /routing rule — MB primary
#   mb   : selected by /routing rule for src=vlan20/30/88 subnets
#   sonic: selected by /routing rule for src=vlan10 (plumtree) subnet
# Each table has the local WAN at distance 1 (active) and the other at
# distance 2 (failover). check-gateway=ping on the d=1 routes triggers
# fall-through when the upstream stops responding (Stage 0 probe C
# confirmed MB upstream answers ICMP; Sonic upstream is the symmetric
# assumption — verify at apply-time).
# Literal next-hops captured at Stage 0 probe D / Stage 1 bind.
/ip route
add dst-address=0.0.0.0/0 gateway=162.217.74.129 routing-table=main  distance=1 check-gateway=ping
add dst-address=0.0.0.0/0 gateway=23.93.120.1    routing-table=main  distance=2
add dst-address=0.0.0.0/0 gateway=162.217.74.129 routing-table=mb    distance=1 check-gateway=ping
add dst-address=0.0.0.0/0 gateway=23.93.120.1    routing-table=mb    distance=2
add dst-address=0.0.0.0/0 gateway=23.93.120.1    routing-table=sonic distance=1 check-gateway=ping
add dst-address=0.0.0.0/0 gateway=162.217.74.129 routing-table=sonic distance=2

# --- routing rules for per-VLAN source-based PBR (Stage 2) ---
# Source-based PBR via /routing rule, NOT mangle mark-routing. The
# mangle-based approach we tried first failed because:
#  - RouterOS 7.x has no implicit fallback from a custom table to main,
#    and no longest-prefix-match across tables.
#  - When mangle set routing-mark=sonic on a plumtree outbound packet,
#    the reply packet (NAT-reversed dst=192.168.10.x) was also routed
#    via the sonic table (conntrack carries the mark forward), which
#    only has 0.0.0.0/0; the reply egressed back out Sonic with a
#    private-IP destination and was dropped upstream. Mac never saw
#    replies. Adding LAN connected routes to mb/sonic didn't fix it
#    (suspect: scope/target-scope mismatch vs main's connected route).
#    Cost three Stage 2 apply attempts + cold-bootstrap recoveries.
#
# Source-based PBR sidesteps the whole question:
#  - Rule 1: dst in 192.168.0.0/16 -> main. This catches reply traffic
#    (dst = LAN client) AND inter-VLAN traffic BEFORE the per-VLAN src
#    rules fire. Reply packets naturally route to vlan10 via main's
#    connected route. No conntrack-stickiness because routing-mark is
#    never set.
#  - Rules 2-5: per-VLAN src -> table. Outbound LAN-to-WAN traffic
#    matches src, gets steered to the right table. Replies don't match
#    (they come from external src), so they bypass these rules
#    and fall through to main.
# Validated 2026-05-22 via live probe: plumtree -> Sonic and reply ->
# Mac, with LAN-to-router and inter-VLAN traffic intact.
/routing rule
add dst-address=192.168.0.0/16  action=lookup table=main  comment="LAN dsts -> main (catches reply + inter-VLAN before src rules)"
add src-address=192.168.10.0/24 action=lookup table=sonic comment="plumtree -> sonic"
add src-address=192.168.20.0/24 action=lookup table=mb    comment="guest -> mb"
add src-address=192.168.30.0/24 action=lookup table=mb    comment="iot -> mb"
add src-address=192.168.88.0/24 action=lookup table=mb    comment="mgmt -> mb"

# --- v6 default routes per routing table (Stage 2) ---
# Same shape as /ip route above; gateways are the upstream link-locals
# (visible in /ipv6 dhcp-client print detail as dhcp-server-v6=).
# Caveat: link-locals are derived from the upstream router's MAC. If
# either ISP swaps their CPE hardware the LL changes and these routes
# go stale. Re-capture from /ipv6 dhcp-client print detail and update
# config.rsc when that happens.
/ipv6 route
add dst-address=::/0 gateway=fe80::f61e:57ff:fe09:94ab%ether2       routing-table=main  distance=1 check-gateway=ping
add dst-address=::/0 gateway=fe80::5e5e:abff:feda:ebc0%sfp-sfpplus1 routing-table=main  distance=2
add dst-address=::/0 gateway=fe80::f61e:57ff:fe09:94ab%ether2       routing-table=mb    distance=1 check-gateway=ping
add dst-address=::/0 gateway=fe80::5e5e:abff:feda:ebc0%sfp-sfpplus1 routing-table=mb    distance=2
add dst-address=::/0 gateway=fe80::5e5e:abff:feda:ebc0%sfp-sfpplus1 routing-table=sonic distance=1 check-gateway=ping
add dst-address=::/0 gateway=fe80::f61e:57ff:fe09:94ab%ether2       routing-table=sonic distance=2

# --- DNS ---
/ip dns
set allow-remote-requests=yes
/ip dns static
add address=192.168.88.1 name=router.lan type=A
# Single-name AAAA pinned to the mgmt-VLAN ULA. Stable across renewals because
# ULAs don't depend on PD; per-VLAN GUA AAAAs are intentionally NOT published —
# pool-derived /64s rotate on prefix renewal (see IPV6-PLAN.md).
add address=fd7f:aee1:6ce0:88::1 name=router.lan type=AAAA

# --- IPv4 firewall ---
/ip firewall filter
# --- input chain ---
add action=accept chain=input comment="accept established,related,untracked" connection-state=established,related,untracked
add action=drop   chain=input comment="drop invalid" connection-state=invalid
add action=accept chain=input comment="accept ICMP" protocol=icmp
add action=accept chain=input comment="accept loopback" in-interface=lo src-address=127.0.0.1 dst-address=127.0.0.1
add action=drop   chain=input comment="drop everything not from LAN" in-interface-list=!LAN

# --- forward chain ---
add action=accept chain=forward comment="accept in ipsec policy"  ipsec-policy=in,ipsec
add action=accept chain=forward comment="accept out ipsec policy" ipsec-policy=out,ipsec
add action=fasttrack-connection chain=forward comment="fasttrack" connection-state=established,related
add action=accept chain=forward comment="accept established,related,untracked" connection-state=established,related,untracked
add action=drop   chain=forward comment="drop invalid" connection-state=invalid
add action=drop   chain=forward comment="drop WAN-originated, non-DSTNATed" connection-nat-state=!dstnat connection-state=new in-interface-list=WAN

# inter-VLAN policy. Order doesn't matter among these (mutually exclusive matches).
add action=drop chain=forward in-interface=vlan20 out-interface-list=LAN comment="guest -> LAN: blocked"
add action=drop chain=forward in-interface=vlan30 out-interface=vlan88   comment="iot -> mgmt: blocked"
add action=drop chain=forward in-interface=vlan30 out-interface=vlan10 connection-state=new comment="iot -> plumtree: new conns blocked (returns OK)"
add action=drop chain=forward in-interface=vlan30 out-interface=vlan20   comment="iot -> guest: blocked"

# --- NAT (masquerade out the WAN) ---
/ip firewall nat
add action=masquerade chain=srcnat ipsec-policy=out,none out-interface-list=WAN comment="masquerade WAN egress"

# --- IPv6 firewall (defconf hardening + Phase A inter-VLAN parity) ---
/ipv6 firewall address-list
add address=::/128            list=bad_ipv6 comment="unspecified"
add address=::1/128           list=bad_ipv6 comment="loopback"
add address=fec0::/10         list=bad_ipv6 comment="site-local"
add address=::ffff:0.0.0.0/96 list=bad_ipv6 comment="ipv4-mapped"
add address=::/96             list=bad_ipv6 comment="ipv4-compat"
add address=100::/64          list=bad_ipv6 comment="discard-only"
add address=2001:db8::/32     list=bad_ipv6 comment="documentation"
add address=2001:10::/28      list=bad_ipv6 comment="ORCHID"
add address=3ffe::/16         list=bad_ipv6 comment="6bone"

/ipv6 firewall filter
add action=accept chain=input comment="accept established,related,untracked" connection-state=established,related,untracked
add action=drop   chain=input comment="drop invalid" connection-state=invalid
add action=accept chain=input comment="accept ICMPv6" protocol=icmpv6
add action=accept chain=input comment="accept UDP traceroute" dst-port=33434-33534 protocol=udp
add action=accept chain=input comment="accept DHCPv6 PD" dst-port=546 protocol=udp src-address=fe80::/10
add action=accept chain=input comment="accept IKE" dst-port=500,4500 protocol=udp
add action=accept chain=input comment="accept ipsec AH"  protocol=ipsec-ah
add action=accept chain=input comment="accept ipsec ESP" protocol=ipsec-esp
add action=accept chain=input comment="accept ipsec policy" ipsec-policy=in,ipsec
add action=drop   chain=input comment="drop everything not from LAN" in-interface-list=!LAN

add action=fasttrack-connection chain=forward comment="fasttrack6" connection-state=established,related
add action=accept chain=forward comment="accept established,related,untracked" connection-state=established,related,untracked
add action=drop   chain=forward comment="drop invalid" connection-state=invalid
add action=drop   chain=forward comment="drop bad src ipv6" src-address-list=bad_ipv6
add action=drop   chain=forward comment="drop bad dst ipv6" dst-address-list=bad_ipv6
add action=drop   chain=forward comment="rfc4890 hop-limit=1" hop-limit=equal:1 protocol=icmpv6

# Inter-VLAN policy parity with the IPv4 forward-chain drops above.
# Placed BEFORE the broad ICMPv6 accept below so iot->plumtree ICMPv6 echo
# (etc.) is dropped consistently with v4. Same-VLAN ND is link-local and
# never traverses forward, so the ICMPv6 accept below still covers ND.
add action=drop chain=forward in-interface=vlan20 out-interface-list=LAN comment="guest -> LAN: blocked"
add action=drop chain=forward in-interface=vlan30 out-interface=vlan88 comment="iot -> mgmt: blocked"
add action=drop chain=forward in-interface=vlan30 out-interface=vlan10 connection-state=new comment="iot -> plumtree: new conns blocked (returns OK)"
add action=drop chain=forward in-interface=vlan30 out-interface=vlan20 comment="iot -> guest: blocked"

add action=accept chain=forward comment="accept ICMPv6" protocol=icmpv6
add action=accept chain=forward comment="accept HIP" protocol=139
add action=accept chain=forward comment="accept IKE" dst-port=500,4500 protocol=udp
add action=accept chain=forward comment="accept ipsec AH"  protocol=ipsec-ah
add action=accept chain=forward comment="accept ipsec ESP" protocol=ipsec-esp
add action=accept chain=forward comment="accept ipsec policy" ipsec-policy=in,ipsec
add action=drop   chain=forward comment="drop everything not from LAN" in-interface-list=!LAN

# --- neighbor discovery + mac-server: LAN only ---
/ip neighbor discovery-settings
set discover-interface-list=LAN
/tool mac-server
set allowed-interface-list=LAN
/tool mac-server mac-winbox
set allowed-interface-list=LAN

# --- bandwidth-server: off ---
# Default is enabled+authenticate, exposes a btest server. Unused here.
/tool bandwidth-server
set enabled=no

:log info "config.rsc: done"
