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
# Defconf doesn't touch /ip settings; defaults are too lax. rp-filter
# is `loose` (not strict) because per-VLAN PBR + main=Sonic creates
# legitimate asymmetric routing (guest/iot/mgmt egress via mb while
# main defaults to Sonic). Loose still catches src-not-reachable-via-
# any-interface (anti-spoof / bogon role); it just doesn't require
# src reachable via the SAME interface. See LESSONS.md for the
# probe-based rationale.
/ip settings
set rp-filter=loose tcp-syncookies=yes send-redirects=no

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

# --- wan-reconciler: reconciles WAN-derived config from live DHCP state ---
# Single script, idempotent, comment-tagged identifiers. Reconciles:
#  - /routing rule v6 src/dst entries against /ipv6 dhcp-client prefix
#    (PD-delegated /56 -- volatile; ISP renewals can rotate it)
#  - /ip route gateway against /ip dhcp-client gateway (v4 next-hop --
#    stable, changes only on ISP infra changes)
#  - /ipv6 route gateway against /ipv6 dhcp-client dhcp-server-v6
#    (upstream link-local -- stable, changes only on ISP CPE swap)
#
# Triggered three ways (hybrid):
#  - Event-driven: /ip dhcp-client and /ipv6 dhcp-client `script=`
#    hooks call this on lease bind/value-change. Fast reaction.
#  - Polling: /system scheduler at 10 min interval. Belt-and-suspenders
#    against drift from manual edits / missed events / bugs.
#  - Implicit apply-day bootstrap: dhcp-client first bind after
#    config.rsc import naturally fires the event-driven trigger.
#
# Identifiers it manages (find by comment):
#  - /routing rule comment="auto-v6-{src,dst}-<pool>"
#  - /ip route comment="auto-v4-route-<table>-<pri|sec>-<wan>"
#  - /ipv6 route comment="auto-v6-route-<table>-<pri|sec>-<wan>"
# Don't reuse those comment strings elsewhere.
#
# Defined here (before /ip dhcp-client) so the named script exists
# when dhcp-client's `script=` property gets set during import --
# otherwise there's a race where the dhcp-client could bind and call a
# script that doesn't exist yet.
/system script
:if ([:len [/system script find name=wan-reconciler]] > 0) do={
    /system script remove [find name=wan-reconciler]
}
add name=wan-reconciler source={
    # Uses RouterOS native typed values throughout -- /ipv6 pool gives a
    # clean ip6-prefix (no lifetime suffix to parse), dhcp-server-v6 is
    # ip6, /ip dhcp-client gateway is ip, /routing rule src/dst-address
    # is ip6-prefix. Equality is canonicalized; concat auto-coerces.
    # --- v6 reconciler: per pool, update /routing rule + /ipv6 route ---
    :local v6Reconcile do={
        :local poolName $1
        :local tableName $2
        :local wanName $3
        # /ipv6 pool is populated when dhcp-client is bound + IA_PD granted.
        # Absence is the cleanest "not ready" signal -- skip and let
        # the next reconciler call retry.
        :local pools [/ipv6 pool find name=$poolName]
        :if ([:len $pools] = 0) do={
            :log warning ("wan-reconciler: pool " . $poolName . " not delegated yet")
            :return true
        }
        :local prefix [/ipv6 pool get [:pick $pools 0] prefix]
        # /routing rule v6 src/dst: declared statically in /routing rule
        # block; reconciler only sets in-place. Set-only is race-free
        # (the dhcp-client script= hook fires from multiple sub-events
        # in close succession; find-then-add would create duplicates).
        # If the comment-tagged entry is missing, log loudly and skip
        # -- restoration requires re-apply or manual re-declare.
        :local srcCmt ("auto-v6-src-" . $poolName)
        :local srcExisting [/routing rule find comment=$srcCmt]
        :if ([:len $srcExisting] = 0) do={
            :log warning ("wan-reconciler: " . $srcCmt . " missing -- re-declare in /routing rule (config.rsc) or re-apply")
        } else={
            :local id [:pick $srcExisting 0]
            :local cur [/routing rule get $id src-address]
            :if ($cur != $prefix) do={
                /routing rule set $id src-address=$prefix table=$tableName
                :log info ("wan-reconciler: ROTATED v6 src " . $poolName . ": " . $cur . " -> " . $prefix)
            }
        }
        :local dstCmt ("auto-v6-dst-" . $poolName)
        :local dstExisting [/routing rule find comment=$dstCmt]
        :if ([:len $dstExisting] = 0) do={
            :log warning ("wan-reconciler: " . $dstCmt . " missing -- re-declare in /routing rule (config.rsc) or re-apply")
        } else={
            :local id [:pick $dstExisting 0]
            :local cur [/routing rule get $id dst-address]
            :if ($cur != $prefix) do={
                /routing rule set $id dst-address=$prefix
                :log info ("wan-reconciler: ROTATED v6 dst " . $poolName . ": " . $cur . " -> " . $prefix)
            }
        }
        # /ipv6 route gateways from upstream link-local (only in dhcp-client,
        # not in pool). Gateway field is stored as string "LL%interface",
        # so we compare strings here.
        :local clients [/ipv6 dhcp-client find pool-name=$poolName]
        :if ([:len $clients] > 0) do={
            :local cid [:pick $clients 0]
            :local llv6 [/ipv6 dhcp-client get $cid dhcp-server-v6]
            :local intf [/ipv6 dhcp-client get $cid interface]
            :if ([:typeof $llv6] != "nothing" and [:typeof $intf] != "nothing") do={
                :local gw ($llv6 . "%" . $intf)
                :foreach r in=[/ipv6 route find comment~("^auto-v6-route-.*-" . $wanName . "\$")] do={
                    :local cur [/ipv6 route get $r gateway]
                    :if ($cur != $gw) do={
                        /ipv6 route set $r gateway=$gw
                        :log info ("wan-reconciler: ROTATED v6 gw " . $wanName . " in " . [/ipv6 route get $r comment] . ": " . $cur . " -> " . $gw)
                    }
                }
            }
        }
    }
    # --- v4 reconciler: per WAN interface, update /ip route gateway ---
    :local v4Reconcile do={
        :local ifName $1
        :local wanName $2
        :local clients [/ip dhcp-client find interface=$ifName]
        :if ([:len $clients] = 0) do={
            :log warning ("wan-reconciler: no v4 dhcp-client on " . $ifName)
            :return true
        }
        :local cid [:pick $clients 0]
        :local status [/ip dhcp-client get $cid status]
        :if ($status != "bound") do={
            :log warning ("wan-reconciler: v4 " . $ifName . " status=" . $status)
            :return true
        }
        :local gw [/ip dhcp-client get $cid gateway]
        :if ([:typeof $gw] = "nothing") do={ :return true }
        # Both sides are ip type -- typed equality, no :tostr needed.
        :foreach r in=[/ip route find comment~("^auto-v4-route-.*-" . $wanName . "\$")] do={
            :local cur [/ip route get $r gateway]
            :if ($cur != $gw) do={
                /ip route set $r gateway=$gw
                :log info ("wan-reconciler: ROTATED v4 gw " . $wanName . " in " . [/ip route get $r comment] . ": " . $cur . " -> " . $gw)
            }
        }
    }
    # --- v6 nd-prefix reconciler: per (VLAN, pool), keep the static
    # /ipv6 nd prefix entry's prefix= in sync with the bound /64 from
    # /ipv6 address from-pool=, and keep valid-lifetime + (for the
    # preferred entries only) preferred-lifetime tracking the live
    # lease from /ipv6 pool, clamped at the ceiling below.
    #
    # The 30m clamp: stale-prefix exposure on /56 rotation is capped at
    # 30m (RAs stop refreshing the old prefix; valid counts down on
    # clients). Normal operation: pool's lifetime is hours/days, clamp
    # always trims it; if the lease ever drops below 30m, the smaller
    # pool value passes through. Stage 4 territory is preferred-lifetime
    # *value* (0s vs not); this reconciler doesn't override the 0s
    # deprecation -- if the field is 0s, it stays 0s.
    :local v6NdReconcile do={
        :local vlanName $1
        :local poolName $2
        :local ltCap 30m
        :local addrId [:pick [/ipv6 address find interface=$vlanName from-pool=$poolName] 0]
        :if ([:typeof $addrId] = "nothing") do={
            :log warning ("wan-reconciler: no /ipv6 address " . $vlanName . " " . $poolName)
            :return true
        }
        :local bound [/ipv6 address get $addrId address]
        # During apply-day binding, /ipv6 address from-pool= briefly
        # shows "::/64" as a placeholder before the pool is populated.
        # Don't capture that into /ipv6 nd prefix -- skip this VLAN/pool
        # and let the next reconciler tick catch up once binding lands.
        # (Observed in the wild: apply-day bug where transient ::/64 got
        # written to /ipv6 nd prefix entries and persisted because the
        # bind-event script= only fires once per lease event, not
        # continuously. The 10m polling tick eventually heals; this
        # check just avoids creating the bad state in the first place.)
        :if ($bound = "::/64") do={
            :log warning ("wan-reconciler: " . $vlanName . "-" . $poolName . " /ipv6 address bind in progress (::/64), retry next tick")
            :return true
        }
        :local cmt ("auto-nd-" . $vlanName . "-" . $poolName)
        :local ndExisting [/ipv6 nd prefix find comment=$cmt]
        :if ([:len $ndExisting] = 0) do={
            :log warning ("wan-reconciler: " . $cmt . " missing -- re-declare in /ipv6 nd prefix (config.rsc) or re-apply")
            :return true
        }
        :local ndId [:pick $ndExisting 0]
        # prefix= update (only on /56 rotation)
        :local cur [/ipv6 nd prefix get $ndId prefix]
        :if ($cur != $bound) do={
            /ipv6 nd prefix set $ndId prefix=$bound
            :log info ("wan-reconciler: ROTATED nd " . $vlanName . "-" . $poolName . ": " . $cur . " -> " . $bound)
        }
        # lifetime tracking from pool, clamped
        :local poolId [:pick [/ipv6 pool find name=$poolName] 0]
        :if ([:typeof $poolId] != "nothing") do={
            :local poolValid [/ipv6 pool get $poolId valid-lifetime]
            :if ($poolValid > $ltCap) do={ :set poolValid $ltCap }
            :local ndValid [/ipv6 nd prefix get $ndId valid-lifetime]
            :if ($ndValid != $poolValid) do={
                /ipv6 nd prefix set $ndId valid-lifetime=$poolValid
            }
            # preferred-lifetime: only for "preferred" entries (current >0s).
            # Deprecated entries (current=0s) are Stage-4-managed; don't override.
            :local ndPref [/ipv6 nd prefix get $ndId preferred-lifetime]
            :if ($ndPref > 0s) do={
                :local poolPref [/ipv6 pool get $poolId preferred-lifetime]
                :if ($poolPref > $ltCap) do={ :set poolPref $ltCap }
                :if ($ndPref != $poolPref) do={
                    /ipv6 nd prefix set $ndId preferred-lifetime=$poolPref
                }
            }
        }
    }
    $v6Reconcile "mb-pd"    "mb"    "mb"
    $v6Reconcile "sonic-pd" "sonic" "sonic"
    $v4Reconcile "ether2"       "mb"
    $v4Reconcile "sfp-sfpplus1" "sonic"
    $v6NdReconcile "vlan88" "mb-pd"
    $v6NdReconcile "vlan88" "sonic-pd"
    $v6NdReconcile "vlan10" "mb-pd"
    $v6NdReconcile "vlan10" "sonic-pd"
    $v6NdReconcile "vlan20" "mb-pd"
    $v6NdReconcile "vlan20" "sonic-pd"
    $v6NdReconcile "vlan30" "mb-pd"
    $v6NdReconcile "vlan30" "sonic-pd"
}

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
# mb and sonic are selected by /routing rule (below) based on
# src-address per LAN VLAN. Each table carries both 0.0.0.0/0 entries
# (local WAN d=1, other WAN d=2) so a WAN failure falls through within
# the table. `fib` is a FLAG here, not `fib=yes` — the property form
# aborts the import (see README pitfalls).
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
# Hard prereq is /interface bridge vlan above, which populates the
# per-port-per-VID table that vlan-filtering enforces.
#
# Anchored here (right after /ip address + /ip ssh + /ip service)
# rather than at the end of config.rsc, so that if a later block
# errors during /import and aborts the script, SSH-via-LAN-IP still
# works — the next "diagnose, fix, re-apply" cycle doesn't need a
# button-reset cold bootstrap.
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
# literal gateways captured at Stage 0 probe D / Stage 1 bind. The
# wan-reconciler script updates those gateways in-place when the ISP
# rotates next-hop IPs.
# use-peer-dns=yes keeps both ISPs' resolvers in /ip dns dynamic-servers.
# script= fires the wan-reconciler on lease bind/value-change (event-
# driven trigger; complements the /system scheduler 10m tick).
/ip dhcp-client
add interface=ether2       add-default-route=no use-peer-dns=yes script="/system script run wan-reconciler"
add interface=sfp-sfpplus1 add-default-route=no use-peer-dns=yes script="/system script run wan-reconciler"

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
# script= fires the wan-reconciler when prefix/address is acquired or
# expires -- catches PD rotation and CPE-MAC LL changes.
/ipv6 dhcp-client
add interface=ether2       request=address,prefix pool-name=mb-pd    pool-prefix-length=64 accept-prefix-without-address=yes add-default-route=no script="/system script run wan-reconciler"
add interface=sfp-sfpplus1 request=address,prefix pool-name=sonic-pd pool-prefix-length=64 accept-prefix-without-address=yes add-default-route=no script="/system script run wan-reconciler"

# --- IPv6 GUA per-VLAN from DHCPv6-PD pools (Phase B-MB + Phase C) ---
# from-pool= on 7.21.4 is prefix-only-to-interface: the pool's /64 is
# bound to the VLAN as a network address (for routing); the router has
# no host GUA on the interface. Clients SLAAC their own GUAs; router
# stays reachable via per-VLAN ULA ::1 (Phase A) and link-local. /64
# re-derives automatically on lease renewal.
#
# All entries advertise=no -- the dynamic /ipv6 nd prefix entries that
# would otherwise be auto-derived can't be `set`-mutated (the original
# Phase C plan ran into this on 7.21.4; see LESSONS.md). Instead, RA
# emission is driven by EXPLICIT static /ipv6 nd prefix entries (below)
# with per-VLAN-per-pool preferred-lifetime bias, which IS settable
# and is the mechanism Stage 4 will use for failover.
#
# Both pools stay bound on every VLAN so source-PBR can match either
# /64. Clients get TWO GUAs per VLAN -- the primary pool's preferred,
# the secondary pool's deprecated.
/ipv6 address
add from-pool=mb-pd    interface=vlan88 advertise=no
add from-pool=mb-pd    interface=vlan10 advertise=no
add from-pool=mb-pd    interface=vlan20 advertise=no
add from-pool=mb-pd    interface=vlan30 advertise=no
add from-pool=sonic-pd interface=vlan88 advertise=no
add from-pool=sonic-pd interface=vlan10 advertise=no
add from-pool=sonic-pd interface=vlan20 advertise=no
add from-pool=sonic-pd interface=vlan30 advertise=no

# --- RA prefix info per-VLAN per-pool (Phase C / Stage 3 v2) ---
# Static /ipv6 nd prefix entries replace what would otherwise be the
# auto-derived dynamic entries (suppressed via advertise=no above).
# Each per-VLAN-per-pool entry carries an explicit preferred-lifetime
# that biases client RFC-6724 source-address selection:
#   preferred-lifetime=30m -> preferred for new flows
#   preferred-lifetime=0s  -> deprecated (existing flows keep, new
#                             flows pick the other GUA)
#
# Per-VLAN policy (steady state):
#   vlan10 (plumtree), vlan88 (mgmt) -> sonic-pd PREFERRED, mb-pd DEPRECATED
#   vlan20 (guest), vlan30 (iot)     -> mb-pd PREFERRED, sonic-pd DEPRECATED
#
# Stage 4 Netwatch scripts will flip preferred-lifetime on these
# entries on WAN-down events to migrate clients to the surviving GUA.
#
# Lifetime values (30m) are the CEILING; wan-reconciler reads the
# current lease lifetime from /ipv6 pool and sets the static entry to
# min(pool_lifetime, 30m). In normal operation the pool's lifetime is
# hours-to-days (3d for MB lease, 6h for Sonic), gets clamped to 30m,
# clients see 30m in every RA. If the lease ever drops below 30m
# (lease expiring without renewal), clamp lets the smaller value
# through -- clients see the realistic remaining lease. Net: address
# persistence on clients is capped at 30m after RA loss, which gives
# fast cleanup on /56 rotation while still comfortably surviving any
# normal router reboot or apply outage.
#
# prefix= literals are bootstrap defaults matching the deterministic
# RouterOS /64 allocation from each /56 (sequential by /ipv6 address
# add order above: vlan88 gets the first /64, vlan10 the second, etc).
# wan-reconciler reads the actually-bound /64 from /ipv6 address and
# `set prefix=` if the /56 ever rotates.
/ipv6 nd prefix
add interface=vlan88 prefix=2607:f598:d488:6100::/64 preferred-lifetime=0s  valid-lifetime=30m comment="auto-nd-vlan88-mb-pd"
add interface=vlan88 prefix=2001:5a8:6a5:4600::/64   preferred-lifetime=30m valid-lifetime=30m comment="auto-nd-vlan88-sonic-pd"
add interface=vlan10 prefix=2607:f598:d488:6101::/64 preferred-lifetime=0s  valid-lifetime=30m comment="auto-nd-vlan10-mb-pd"
add interface=vlan10 prefix=2001:5a8:6a5:4601::/64   preferred-lifetime=30m valid-lifetime=30m comment="auto-nd-vlan10-sonic-pd"
add interface=vlan20 prefix=2607:f598:d488:6102::/64 preferred-lifetime=30m valid-lifetime=30m comment="auto-nd-vlan20-mb-pd"
add interface=vlan20 prefix=2001:5a8:6a5:4602::/64   preferred-lifetime=0s  valid-lifetime=30m comment="auto-nd-vlan20-sonic-pd"
add interface=vlan30 prefix=2607:f598:d488:6103::/64 preferred-lifetime=30m valid-lifetime=30m comment="auto-nd-vlan30-mb-pd"
add interface=vlan30 prefix=2001:5a8:6a5:4603::/64   preferred-lifetime=0s  valid-lifetime=30m comment="auto-nd-vlan30-sonic-pd"

# --- WAN default routes per routing table (Stage 2) ---
# Six routes total (3 tables × 2 WANs):
#   main : router-originated traffic + anything not matching /routing
#          rule src/dst rules — Sonic primary (faster, better latency)
#   mb   : selected by /routing rule for src in mb-pd /56 (v6) and
#          src=vlan20/30/88 subnets (v4)
#   sonic: selected by /routing rule for src in sonic-pd /56 (v6) and
#          src=vlan10 (plumtree) subnet (v4)
# Each table has the local WAN at distance 1 (active) and the other at
# distance 2 (failover). check-gateway=ping on the d=1 routes triggers
# fall-through when the upstream stops responding.
# Literal next-hops captured at Stage 0 probe D / Stage 1 bind.
/ip route
add dst-address=0.0.0.0/0 gateway=23.93.120.1    routing-table=main  distance=1 check-gateway=ping comment="auto-v4-route-main-pri-sonic"
add dst-address=0.0.0.0/0 gateway=162.217.74.129 routing-table=main  distance=2                    comment="auto-v4-route-main-sec-mb"
add dst-address=0.0.0.0/0 gateway=162.217.74.129 routing-table=mb    distance=1 check-gateway=ping comment="auto-v4-route-mb-pri-mb"
add dst-address=0.0.0.0/0 gateway=23.93.120.1    routing-table=mb    distance=2                    comment="auto-v4-route-mb-sec-sonic"
add dst-address=0.0.0.0/0 gateway=23.93.120.1    routing-table=sonic distance=1 check-gateway=ping comment="auto-v4-route-sonic-pri-sonic"
add dst-address=0.0.0.0/0 gateway=162.217.74.129 routing-table=sonic distance=2                    comment="auto-v4-route-sonic-sec-mb"

# --- routing rules for per-VLAN source-based PBR (Stage 2) ---
# Source-based PBR via /routing rule, NOT mangle mark-routing (see
# LESSONS.md for the retrospective on why mangle is a trap on 7.x).
# Order matters:
#  - Rule 1 (dst=LAN supernet -> main) catches reply traffic and
#    inter-VLAN before the per-VLAN src rules fire. Reply packets
#    route to LAN via main's connected routes; no conntrack
#    stickiness because routing-mark is never set.
#  - Rules 2-5 (per-VLAN src -> table) steer outbound LAN-to-WAN
#    traffic to the right table. Replies don't match (their src is
#    the external endpoint) so they bypass these rules and fall
#    through to main.
/routing rule
add dst-address=192.168.0.0/16  action=lookup table=main  comment="LAN dsts -> main (catches reply + inter-VLAN before src rules)"
add src-address=192.168.10.0/24 action=lookup table=sonic comment="plumtree -> sonic"
add src-address=192.168.20.0/24 action=lookup table=mb    comment="guest -> mb"
add src-address=192.168.30.0/24 action=lookup table=mb    comment="iot -> mb"
add src-address=192.168.88.0/24 action=lookup table=sonic comment="mgmt -> sonic"
# --- Stage 3: v6 source-based PBR per pool ---
# Same shape as v4 above (dst-LAN priority + per-pool src rules). The
# entries referencing DHCPv6-PD-delegated /56 prefixes are declared
# here with bootstrap literals (current ISP /56s) and tagged with
# comment="auto-v6-{src,dst}-<pool>"; the wan-reconciler script (near
# the top of this file) finds them by comment and updates the
# src/dst-address in place when the ISP rotates the delegation.
# Bootstrap-literals-with-reconciler-update mirrors the /ip route +
# /ipv6 route pattern below.
#
# Why declare and `set` rather than `add` from the script: the script=
# hook on /ipv6 dhcp-client fires on BOTH dhcp-client/bind and
# dhcp-ia/acquire sub-events near-simultaneously. A find-then-add
# pattern races and creates duplicate rules. Declaring statically +
# only ever updating via `set` is race-free (idempotent set with same
# value).
add dst-address=fd7f:aee1:6ce0::/48      action=lookup table=main  comment="v6 ULA LAN dsts -> main"
add src-address=2607:f598:d488:6100::/56 action=lookup table=mb    comment="auto-v6-src-mb-pd"
add dst-address=2607:f598:d488:6100::/56 action=lookup table=main  comment="auto-v6-dst-mb-pd"
add src-address=2001:5a8:6a5:4600::/56   action=lookup table=sonic comment="auto-v6-src-sonic-pd"
add dst-address=2001:5a8:6a5:4600::/56   action=lookup table=main  comment="auto-v6-dst-sonic-pd"

# --- v6 default routes per routing table (Stage 2) ---
# Same shape as /ip route above; gateways are the upstream link-locals
# (visible in /ipv6 dhcp-client print detail as dhcp-server-v6=).
# The literal gateways here are bootstrap defaults; the wan-reconciler
# script updates them in-place when the upstream LL changes (e.g.,
# ISP swaps CPE hardware -> new upstream MAC -> new LL).
/ipv6 route
add dst-address=::/0 gateway=fe80::5e5e:abff:feda:ebc0%sfp-sfpplus1 routing-table=main  distance=1 check-gateway=ping comment="auto-v6-route-main-pri-sonic"
add dst-address=::/0 gateway=fe80::f61e:57ff:fe09:94ab%ether2       routing-table=main  distance=2                    comment="auto-v6-route-main-sec-mb"
add dst-address=::/0 gateway=fe80::f61e:57ff:fe09:94ab%ether2       routing-table=mb    distance=1 check-gateway=ping comment="auto-v6-route-mb-pri-mb"
add dst-address=::/0 gateway=fe80::5e5e:abff:feda:ebc0%sfp-sfpplus1 routing-table=mb    distance=2                    comment="auto-v6-route-mb-sec-sonic"
add dst-address=::/0 gateway=fe80::5e5e:abff:feda:ebc0%sfp-sfpplus1 routing-table=sonic distance=1 check-gateway=ping comment="auto-v6-route-sonic-pri-sonic"
add dst-address=::/0 gateway=fe80::f61e:57ff:fe09:94ab%ether2       routing-table=sonic distance=2                    comment="auto-v6-route-sonic-sec-mb"

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

# --- wan-reconciler scheduler tick (belt-and-suspenders) ---
# Event-driven trigger is the dhcp-client script= hook above (fires on
# lease bind/value-change, immediate reaction). This 10m tick catches
# drift from any source the event misses -- manual edits, missed
# events, bugs.
#
# /system scheduler is gated by /system device-mode. scheduler=yes is
# already set on this router and persists across routine
# wipe-and-replay applies, but a deeper reset (button-hold factory
# reset, netinstall) restores device-mode to its defaults
# (scheduler=no). Without the :do/on-error wrap, the `add` below would
# raise an unhandled "not allowed by device-mode" error on cold
# bootstrap and abort the import partway through -- leaving the
# router half-configured. The wrap lets the import complete; the
# event-driven script= hooks on dhcp-clients still work (they don't
# need /system scheduler), so the loss is just the 10m polling
# safety net. Recovery: `/system device-mode update scheduler=yes`
# + front-button confirm, then re-apply (see README.md Recovery).
:do {
    /system scheduler add name=wan-reconciler-tick on-event="/system script run wan-reconciler" interval=10m
} on-error={
    :log warning "config.rsc: /system scheduler add failed (cold-bootstrap device-mode reset?). Event-driven reconciler still active; re-enable scheduler via /system device-mode + button-confirm to restore polling."
}

:log info "config.rsc: done"
