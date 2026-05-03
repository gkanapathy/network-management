# rb5009 — target configuration. Source of truth.
# Apply via wipe + import; see README.md.
#
# Topology:
#   ether1        trunk to root AP — untagged 88 (mgmt) + tagged 10/20/30
#   ether2        WAN (monkeybrains, DHCP client)
#   ether3-7      bridge access ports, untagged VLAN 88 (mgmt)
#   ether8        bridge access port, untagged VLAN 88 — Mac (en7) + colima
#   sfp-sfpplus1  unconfigured (future sonic WAN)
#
# VLANs (all L3 lives on /interface vlan; never on bridge directly):
#   88   mgmt      192.168.88.0/24    vlan88
#   10   plumtree  192.168.10.0/24    vlan10
#   20   guest     192.168.20.0/24    vlan20
#   30   iot       192.168.30.0/24    vlan30
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

# --- LEDs ---
# Turn off the front-panel LEDs after 1h of uptime. Lets us see boot
# health visually for the first hour, then dark. Try it; flip to
# immediate or never if we want different behavior.
/system leds settings
set all-leds-off=after-1h

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

# --- L3 addresses (all on VLAN sub-interfaces) ---
/ip address
add address=192.168.88.1/24 interface=vlan88 network=192.168.88.0
add address=192.168.10.1/24 interface=vlan10 network=192.168.10.0
add address=192.168.20.1/24 interface=vlan20 network=192.168.20.0
add address=192.168.30.1/24 interface=vlan30 network=192.168.30.0

# --- admin SSH key (early: regain key auth ASAP) ---
# Idempotent: with `keep-users=yes` on reset, the previous key survives.
# Clear before re-importing so we don't accumulate duplicates each apply.
:if ([:len [/file/find name=gkanapathy-mbpmx.pub]] > 0) do={
    /user/ssh-keys/remove [find user=admin]
    /user/ssh-keys/import public-key-file=gkanapathy-mbpmx.pub user=admin
    :log info "config.rsc: ssh key imported"
} else={
    :log warning "config.rsc: gkanapathy-mbpmx.pub not present; existing keys (if any) retained"
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
add address=192.168.88.251 client-id=1:52:55:55:ca:b3:fb mac-address=52:55:55:CA:B3:FB server=mgmt-dhcp comment="omada controller (colima)"
add address=192.168.88.252 mac-address=24:2F:D0:02:07:5A server=mgmt-dhcp comment="OC200"

# --- WAN: DHCP client on ether2 (monkeybrains) ---
/ip dhcp-client
add interface=ether2

# --- DNS ---
/ip dns
set allow-remote-requests=yes
/ip dns static
add address=192.168.88.1 name=router.lan type=A

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

# --- IPv6 firewall (defconf hardening; IPv6 not in active use) ---
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

# --- enable VLAN filtering (LAST; after all VLAN entries are in place) ---
/interface bridge
set [find name=bridge] vlan-filtering=yes

:log info "config.rsc: done"
