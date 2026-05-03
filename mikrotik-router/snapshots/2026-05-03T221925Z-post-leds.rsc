# 2026-05-03 15:19:24 by RouterOS 7.21.4
# software id = 8U9Q-SQF0
#
# model = RB5009UG+S+
# serial number = HJW0AGSSCGS
/interface bridge
add admin-mac=04:F4:1C:51:BA:D8 auto-mac=no name=bridge vlan-filtering=yes
/interface vlan
add comment=plumtree interface=bridge name=vlan10 vlan-id=10
add comment=guest interface=bridge name=vlan20 vlan-id=20
add comment=iot interface=bridge name=vlan30 vlan-id=30
add comment=mgmt interface=bridge name=vlan88 vlan-id=88
/interface list
add name=WAN
add name=LAN
/ip pool
add name=mgmt-pool ranges=192.168.88.10-192.168.88.254
add name=plumtree-pool ranges=192.168.10.10-192.168.10.250
add name=guest-pool ranges=192.168.20.10-192.168.20.250
add name=iot-pool ranges=192.168.30.10-192.168.30.250
/ip dhcp-server
add address-pool=mgmt-pool interface=vlan88 name=mgmt-dhcp
add address-pool=plumtree-pool interface=vlan10 name=plumtree-dhcp
add address-pool=guest-pool interface=vlan20 name=guest-dhcp
add address-pool=iot-pool interface=vlan30 name=iot-dhcp
/interface bridge port
add bridge=bridge comment="trunk to root AP" interface=ether1 pvid=88
add bpdu-guard=yes bridge=bridge edge=yes interface=ether3 pvid=88
add bpdu-guard=yes bridge=bridge edge=yes interface=ether4 pvid=88
add bpdu-guard=yes bridge=bridge edge=yes interface=ether5 pvid=88
add bpdu-guard=yes bridge=bridge edge=yes interface=ether6 pvid=88
add bpdu-guard=yes bridge=bridge edge=yes interface=ether7 pvid=88
add bpdu-guard=yes bridge=bridge edge=yes interface=ether8 pvid=88
/ip neighbor discovery-settings
set discover-interface-list=LAN
/ip settings
set rp-filter=strict send-redirects=no tcp-syncookies=yes
/interface bridge vlan
add bridge=bridge tagged=bridge,ether1 vlan-ids=10
add bridge=bridge tagged=bridge,ether1 vlan-ids=20
add bridge=bridge tagged=bridge,ether1 vlan-ids=30
add bridge=bridge tagged=bridge untagged=\
    ether1,ether3,ether4,ether5,ether6,ether7,ether8 vlan-ids=88
/interface list member
add interface=vlan88 list=LAN
add interface=vlan10 list=LAN
add interface=vlan20 list=LAN
add interface=vlan30 list=LAN
add interface=ether2 list=WAN
/ip address
add address=192.168.88.1/24 interface=vlan88 network=192.168.88.0
add address=192.168.10.1/24 interface=vlan10 network=192.168.10.0
add address=192.168.20.1/24 interface=vlan20 network=192.168.20.0
add address=192.168.30.1/24 interface=vlan30 network=192.168.30.0
/ip dhcp-client
add interface=ether2
/ip dhcp-server lease
add address=192.168.88.251 client-id=1:52:55:55:ca:b3:fb comment=\
    "omada controller (colima)" mac-address=52:55:55:CA:B3:FB server=\
    mgmt-dhcp
add address=192.168.88.252 comment=OC200 mac-address=24:2F:D0:02:07:5A \
    server=mgmt-dhcp
/ip dhcp-server network
add address=192.168.10.0/24 dns-server=192.168.10.1 gateway=192.168.10.1
add address=192.168.20.0/24 dns-server=192.168.20.1 gateway=192.168.20.1
add address=192.168.30.0/24 dns-server=192.168.30.1 gateway=192.168.30.1
add address=192.168.88.0/24 dns-server=192.168.88.1 gateway=192.168.88.1
/ip dns
set allow-remote-requests=yes
/ip dns static
add address=192.168.88.1 name=router.lan type=A
/ip firewall filter
add action=accept chain=input comment="accept established,related,untracked" \
    connection-state=established,related,untracked
add action=drop chain=input comment="drop invalid" connection-state=invalid
add action=accept chain=input comment="accept ICMP" protocol=icmp
add action=accept chain=input comment="accept loopback" dst-address=127.0.0.1 \
    in-interface=lo src-address=127.0.0.1
add action=drop chain=input comment="drop everything not from LAN" \
    in-interface-list=!LAN
add action=accept chain=forward comment="accept in ipsec policy" \
    ipsec-policy=in,ipsec
add action=accept chain=forward comment="accept out ipsec policy" \
    ipsec-policy=out,ipsec
add action=fasttrack-connection chain=forward comment=fasttrack \
    connection-state=established,related
add action=accept chain=forward comment=\
    "accept established,related,untracked" connection-state=\
    established,related,untracked
add action=drop chain=forward comment="drop invalid" connection-state=invalid
add action=drop chain=forward comment="drop WAN-originated, non-DSTNATed" \
    connection-nat-state=!dstnat connection-state=new in-interface-list=WAN
add action=drop chain=forward comment="guest -> LAN: blocked" in-interface=\
    vlan20 out-interface-list=LAN
add action=drop chain=forward comment="iot -> mgmt: blocked" in-interface=\
    vlan30 out-interface=vlan88
add action=drop chain=forward comment=\
    "iot -> plumtree: new conns blocked (returns OK)" connection-state=new \
    in-interface=vlan30 out-interface=vlan10
add action=drop chain=forward comment="iot -> guest: blocked" in-interface=\
    vlan30 out-interface=vlan20
/ip firewall nat
add action=masquerade chain=srcnat comment="masquerade WAN egress" \
    ipsec-policy=out,none out-interface-list=WAN
/ip service
set ftp disabled=yes
set ssh address=192.168.88.0/24,192.168.10.0/24,fe80::/10
set telnet disabled=yes
set www address=192.168.88.0/24,192.168.10.0/24,fe80::/10
set winbox address=192.168.88.0/24,192.168.10.0/24,fe80::/10
set api disabled=yes
/ip ssh
set host-key-size=4096 host-key-type=ed25519 password-authentication=yes \
    strong-crypto=yes
/ipv6 firewall address-list
add address=::/128 comment=unspecified list=bad_ipv6
add address=::1/128 comment=loopback list=bad_ipv6
add address=fec0::/10 comment=site-local list=bad_ipv6
add address=::ffff:0.0.0.0/96 comment=ipv4-mapped list=bad_ipv6
add address=::/96 comment=ipv4-compat list=bad_ipv6
add address=100::/64 comment=discard-only list=bad_ipv6
add address=2001:db8::/32 comment=documentation list=bad_ipv6
add address=2001:10::/28 comment=ORCHID list=bad_ipv6
add address=3ffe::/16 comment=6bone list=bad_ipv6
/ipv6 firewall filter
add action=accept chain=input comment="accept established,related,untracked" \
    connection-state=established,related,untracked
add action=drop chain=input comment="drop invalid" connection-state=invalid
add action=accept chain=input comment="accept ICMPv6" protocol=icmpv6
add action=accept chain=input comment="accept UDP traceroute" dst-port=\
    33434-33534 protocol=udp
add action=accept chain=input comment="accept DHCPv6 PD" dst-port=546 \
    protocol=udp src-address=fe80::/10
add action=accept chain=input comment="accept IKE" dst-port=500,4500 \
    protocol=udp
add action=accept chain=input comment="accept ipsec AH" protocol=ipsec-ah
add action=accept chain=input comment="accept ipsec ESP" protocol=ipsec-esp
add action=accept chain=input comment="accept ipsec policy" ipsec-policy=\
    in,ipsec
add action=drop chain=input comment="drop everything not from LAN" \
    in-interface-list=!LAN
add action=fasttrack-connection chain=forward comment=fasttrack6 \
    connection-state=established,related
add action=accept chain=forward comment=\
    "accept established,related,untracked" connection-state=\
    established,related,untracked
add action=drop chain=forward comment="drop invalid" connection-state=invalid
add action=drop chain=forward comment="drop bad src ipv6" src-address-list=\
    bad_ipv6
add action=drop chain=forward comment="drop bad dst ipv6" dst-address-list=\
    bad_ipv6
add action=drop chain=forward comment="rfc4890 hop-limit=1" hop-limit=equal:1 \
    protocol=icmpv6
add action=accept chain=forward comment="accept ICMPv6" protocol=icmpv6
add action=accept chain=forward comment="accept HIP" protocol=139
add action=accept chain=forward comment="accept IKE" dst-port=500,4500 \
    protocol=udp
add action=accept chain=forward comment="accept ipsec AH" protocol=ipsec-ah
add action=accept chain=forward comment="accept ipsec ESP" protocol=ipsec-esp
add action=accept chain=forward comment="accept ipsec policy" ipsec-policy=\
    in,ipsec
add action=drop chain=forward comment="drop everything not from LAN" \
    in-interface-list=!LAN
/system clock
set time-zone-autodetect=no time-zone-name=America/Los_Angeles
/system identity
set name=plumtree-rtr
/system leds settings
set all-leds-off=after-1h
/system ntp client
set enabled=yes
/system ntp client servers
add address=time.cloudflare.com
add address=time.google.com
/tool bandwidth-server
set enabled=no
/tool mac-server
set allowed-interface-list=LAN
/tool mac-server mac-winbox
set allowed-interface-list=LAN
