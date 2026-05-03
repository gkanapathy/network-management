# 2026-04-20 06:51:23 by RouterOS 7.21.4
# software id = 8U9Q-SQF0
#
# model = RB5009UG+S+
# serial number = HJW0AGSSCGS
/interface bridge
add admin-mac=04:F4:1C:51:BA:D8 auto-mac=no name=bridge
/interface list
add name=WAN
add name=LAN
/ip pool
add name=lan-pool ranges=192.168.88.10-192.168.88.254
/ip dhcp-server
add address-pool=lan-pool interface=bridge name=lan-dhcp
/interface bridge port
add bridge=bridge interface=ether2
add bridge=bridge interface=ether3
add bridge=bridge interface=ether4
add bridge=bridge interface=ether5
add bridge=bridge interface=ether6
add bridge=bridge interface=ether7
add bridge=bridge interface=ether8
add bridge=bridge interface=sfp-sfpplus1
/ip neighbor discovery-settings
set discover-interface-list=LAN
/interface list member
add interface=bridge list=LAN
add interface=ether1 list=WAN
/ip address
add address=192.168.88.1/24 interface=bridge network=192.168.88.0
/ip dhcp-client
# Interface not active
add interface=ether1
/ip dhcp-server lease
add address=192.168.88.251 client-id=1:52:55:55:ca:b3:fb comment=\
    "omada controller (colima)" mac-address=52:55:55:CA:B3:FB server=lan-dhcp
/ip dhcp-server network
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
add action=accept chain=input comment="accept to local loopback (CAPsMAN)" \
    dst-address=127.0.0.1
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
/ip firewall nat
add action=masquerade chain=srcnat comment="masquerade WAN egress" \
    ipsec-policy=out,none out-interface-list=WAN
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
/system identity
set name=plumtree-rtr
/tool mac-server
set allowed-interface-list=LAN
/tool mac-server mac-winbox
set allowed-interface-list=LAN
