# rb5009 — target configuration. Source of truth.
# Apply via wipe + import; see README.md.
#
# NOT idempotent: apply ONLY via wipe-and-replay (apply.sh runs /system
# reset-configuration then run-after-reset). Never /import this onto a
# live config -- the target-state `add` blocks would duplicate.
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
#
# Ordering (top to bottom):
#   1. Identity + IP-stack settings (low risk)
#   2. Timekeeping (set early so log timestamps are correct)
#   3. Lockout-safety prereqs: bridge / VLAN / addresses / SSH / service
#   4. vlan-filtering=yes  <-- LOCKOUT-SAFETY GATE: SSH is locked in past here
#   5. Routing tables + script definitions (large blocks; risky parse)
#   6. DHCP servers + clients (clients added WITHOUT script= -- see step 9)
#   7. /ipv6 address from-pool, /ipv6 nd prefix, /ip route, /routing rule
#      (v4+v6 in one block), /ipv6 route — reconciler-managed entries,
#      declared with bootstrap literals
#   8. DNS + firewall + service-surface tightening
#   9. Netwatch probes + wire dhcp-client `script=` hooks + explicit
#      wan-reconciler bootstrap + scheduler tick. Automation goes last
#      (essential-first principle); script= deferred to here so the apply-
#      day dhcp-client bind doesn't fire the reconciler against half-
#      declared state.
#  10. Cosmetic: LEDs + reset-button binding (at the very end so a failure
#      above doesn't leave LEDs in a confusing state)
# Errors below the gate (step 4) don't lock us out: SSH-via-mgmt-VLAN
# (and IPv6-LL backdoor) keeps working, so the fix-and-reapply loop
# doesn't need a button-reset cold bootstrap.

:log info "config.rsc: starting"

# --- identity ---
/system identity
set name=plumtree-rtr

# --- IP-stack hardening ---
# Defconf doesn't touch /ip settings; defaults are too lax. rp-filter
# is `loose` (not strict) because per-VLAN PBR + main=Sonic creates
# legitimate asymmetric routing (guest/iot egress via mb while main
# defaults to Sonic; plumtree/mgmt egress via Sonic which matches
# main). Loose still catches src-not-reachable-via-any-interface
# (anti-spoof / bogon role); it just doesn't require src reachable
# via the SAME interface. See LESSONS.md for the probe-based rationale.
/ip settings
set rp-filter=loose tcp-syncookies=yes send-redirects=no

# --- timezone + NTP ---
# Set early so any subsequent /log entries (including errors in
# lockout-prereq blocks below) are timestamped in local time. NTP
# config is harmless before WAN is up -- the client just sits idle
# until DHCP binds a route.
# Pin time-zone explicitly; turn off autodetect (which uses IP-geolocation
# via a MikroTik service over the WAN). Router is stationary, so we don't
# need autodetect, and pinning avoids a surprise override if the geo
# lookup ever decides we're somewhere else.
/system clock
set time-zone-autodetect=no time-zone-name=America/Los_Angeles
# NTP via Cloudflare + Google anycast. Defaults to unicast mode.
/system ntp client
set enabled=yes servers=time.cloudflare.com,time.google.com

# --- bridge (vlan-filtering enabled below the lockout-safety gate) ---
/interface bridge
add admin-mac=04:F4:1C:51:BA:D8 auto-mac=no name=bridge

# --- bridge ports ---
# ether1 = trunk, others = access ports on VLAN 88. PVID=88 stamps untagged ingress.
# Access ports get bpdu-guard=yes edge=yes: a downstream device sending BPDUs
# (rogue switch / malicious endpoint) gets the port disabled instantly. ether1
# is the trunk to the AP and intentionally not bpdu-guarded — the AP could
# legitimately speak STP.
#
# frame-types on access ports: admit-only-untagged-and-priority-tagged rejects
# any VLAN-tagged frame at ingress, making the access-port intent self-
# enforcing at the port level (independent of the bridge VLAN table). Defense
# in depth against VLAN hopping. ether1 stays at the default (admit-all)
# since it's the trunk and must accept both untagged VLAN 88 and tagged
# 10/20/30.
/interface bridge port
add bridge=bridge interface=ether1 pvid=88 comment="trunk to root AP"
add bridge=bridge interface=ether3 pvid=88 bpdu-guard=yes edge=yes frame-types=admit-only-untagged-and-priority-tagged
add bridge=bridge interface=ether4 pvid=88 bpdu-guard=yes edge=yes frame-types=admit-only-untagged-and-priority-tagged
add bridge=bridge interface=ether5 pvid=88 bpdu-guard=yes edge=yes frame-types=admit-only-untagged-and-priority-tagged
add bridge=bridge interface=ether6 pvid=88 bpdu-guard=yes edge=yes frame-types=admit-only-untagged-and-priority-tagged
add bridge=bridge interface=ether7 pvid=88 bpdu-guard=yes edge=yes frame-types=admit-only-untagged-and-priority-tagged
add bridge=bridge interface=ether8 pvid=88 bpdu-guard=yes edge=yes frame-types=admit-only-untagged-and-priority-tagged

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
# ra-interval tightened from default 3m20s-10m (200s-600s) to
# 15s-30s so a preferred-lifetime flip on WAN failover reaches
# clients within ~30s worst case (one RA cycle). Modest multicast
# traffic. Syntax is min-max with a hyphen; RouterOS displays/
# parses this property as a single ra-interval=<min>-<max>.
add interface=vlan88 advertise-dns=yes dns=fd7f:aee1:6ce0:88::1 ra-interval=15s-30s
add interface=vlan10 advertise-dns=yes dns=fd7f:aee1:6ce0:10::1 ra-interval=15s-30s
add interface=vlan20 advertise-dns=yes dns=fd7f:aee1:6ce0:20::1 ra-interval=15s-30s
add interface=vlan30 advertise-dns=yes dns=fd7f:aee1:6ce0:30::1 ra-interval=15s-30s

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
#   post-quantum KEX (RouterOS 7.x has none, 7.23 included), so OpenSSH 9.x will still
#   warn about "store now, decrypt later"; that warning won't go away until
#   MikroTik ships PQ-KEX support upstream.
# - host-key-type=ed25519: smaller, faster, modern key. Setting this to
#   a value that already matches the current host-key-type is a no-op
#   (verified empirically on 7.21.4: `set host-key-type=ed25519` when
#   it's already ed25519 leaves the host key bit-for-bit unchanged).
# - host-key-size=4096: dormant for ed25519, only matters if anyone ever
#   flips host-key-type back to rsa; cheap to set.
# - forwarding-enabled=no: refuse SSH-tunnel/jump-host use of the router.
# Note: there is no `max-auth-tries` property on /ip ssh in RouterOS 7.x
# (still absent on 7.23) (that's
# OpenSSH's MaxAuthTries). Brute-force resistance lives elsewhere — we
# rely on key-only auth + service `address=` scoping below.
#
# About the host key on routine applies: the host key DOES rotate per
# apply, but the rotation happens inside `/system reset-configuration`
# itself -- factory-state restoration regenerates the SSH host key
# unconditionally. The /ip ssh `set` block here is incidental; even
# without the host-key-type line, reset would still rotate the key on
# every apply. apply.sh's ssh-keygen -R + ssh-keyscan refresh in the
# polling step is what absorbs the churn. No explicit
# `/ip ssh regenerate-host-key` call needed (reset already does it).
/ip ssh
set password-authentication=yes strong-crypto=yes host-key-type=ed25519 host-key-size=4096 forwarding-enabled=no

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

# === LOCKOUT-SAFETY GATE =====================================================
# vlan-filtering=yes — past this point SSH-via-mgmt-VLAN (and IPv6 link-local
# backdoor) is locked in. If any block below errors during /import and aborts
# the script, basic management access still works; the fix-and-reapply cycle
# doesn't need a button-reset cold bootstrap.
#
# Hard prereq is /interface bridge vlan above, which populates the
# per-port-per-VID table that vlan-filtering enforces.
/interface bridge
set [find name=bridge] vlan-filtering=yes
# === END LOCKOUT-SAFETY GATE =================================================

# --- routing tables for Stage 2 source-based PBR ---
# mb and sonic are selected by /routing rule (below) based on
# src-address per LAN VLAN. Each table carries both 0.0.0.0/0 entries
# (local WAN d=1, other WAN d=2) so a WAN failure falls through within
# the table. `fib` is a FLAG here, not `fib=yes` — the property form
# aborts the import (see README pitfalls).
/routing table
add name=mb    fib
add name=sonic fib

# --- wan-reconciler: reconciles WAN-derived config from live DHCP state ---
# Single script, idempotent, comment-tagged identifiers. Reconciles:
#  - /routing rule v6 src/dst entries against /ipv6 dhcp-client prefix
#    (PD-delegated /56 -- volatile; ISP renewals can rotate it)
#  - /ip route gateway against /ip dhcp-client gateway (v4 next-hop --
#    stable, changes only on ISP infra changes)
#  - /ipv6 route gateway against /ipv6 dhcp-client dhcp-server-v6
#    (upstream link-local -- stable, changes only on ISP CPE swap)
#  - /ipv6 nd prefix prefix= + lifetimes against /ipv6 address from-pool
#    and /ipv6 pool (per-VLAN-per-pool advertised /64; prefix rotates
#    on /56 rotation, lifetimes track pool lease clamped at 30m)
#  - /tool netwatch src-address against /ipv6 address from-pool=...
#    eui-64=yes (v6 WAN-probe src; host part stable via EUI-64 from
#    pinned bridge MAC, only the prefix part rotates)
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
#  - /ipv6 nd prefix comment="auto-nd-<vlan>-<pool>"
#  - /tool netwatch comment={sonic-probe,mb-probe} (src-address only)
# Also reads (no writes): /ipv6 address comment="probe-src-<pool>"
# to source the bound host GUA into netwatch src-address.
# Don't reuse those comment strings elsewhere.
#
# These tags are load-bearing JOIN KEYS living in three forms that must
# stay in lockstep: (a) the comment= literal on the declaration; (b) the
# parts assembled from args here in the reconciler (e.g. "auto-nd-".$vlan
# ."-".$pool); (c) the {vlan}-{pool} parts the failover scripts assemble.
# A rename is NEVER a single grep-replace -- a typo'd/renamed tag matches
# none of them, so the entry is silently skipped (logged "missing").
# Update all three forms together.
#
# Defined here (after the lockout-safety gate, before /ip dhcp-client
# below) so the named script exists when dhcp-client's `script=`
# property gets set during import -- otherwise there's a race where
# the dhcp-client could bind and call a script that doesn't exist yet.
# Kept inline (not a separate .rsc) because apply.sh imports a single file
# via run-after-reset=config.rsc; a second file would add a staging step
# and an uncaught-import-error failure mode.
/system script
:if ([:len [/system script find name=wan-reconciler]] > 0) do={
    /system script remove [find name=wan-reconciler]
}
add name=wan-reconciler policy=read,write,test source={
    # Uses RouterOS native typed values throughout -- /ipv6 pool gives a
    # clean ip6-prefix (no lifetime suffix to parse), dhcp-server-v6 is
    # ip6, /ip dhcp-client gateway is ip, /routing rule src/dst-address
    # is ip6-prefix. Equality is canonicalized; concat auto-coerces.
    # --- shared parse-guard: strip /mask, parse to ip6, verify it falls
    # inside the pool's delegated prefix. Returns the host ip6 on success,
    # "" on any transient/parse failure (caller treats a non-ip6 return as
    # "skip this tick"). One definition shared by v6NdReconcile +
    # netwatchSrcReconcile so the transient-bind guard can't silently
    # diverge between them. MUST be passed in as an argument -- a do={}
    # value can't see sibling locals (LESSONS.md: the prefixLenToMask trap).
    # The `in $poolPrefixStr` test IS the transient guard: while /ipv6
    # address is binding, RouterOS returns forms ("::/64", "::host/64",
    # "0:0:0:N::/64") whose bits aren't yet inside the real /56, so they
    # are skipped rather than written out as garbage.
    :local parseGuard do={
        :local raw $1
        :local poolPrefixStr $2
        :local label $3
        :local slashPos [:find $raw "/"]
        :local bare $raw
        :if ([:typeof $slashPos] != "nothing") do={ :set bare [:pick $raw 0 $slashPos] }
        :local ip [:toip6 $bare]
        :if ([:typeof $ip] != "ip6") do={
            :log warning ("wan-reconciler: " . $label . " unparseable /ipv6 address: " . $raw)
            :return ""
        }
        :if (!($ip in $poolPrefixStr)) do={
            :log info ("wan-reconciler: " . $label . " /ipv6 address bind in progress (" . $raw . " not in " . $poolPrefixStr . "), retry next tick")
            :return ""
        }
        :return $ip
    }
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
            :log info ("wan-reconciler: pool " . $poolName . " not delegated yet")
            :return true
        }
        # Symmetric to v4Reconcile's status check: pool existence alone
        # isn't proof of a healthy bind (it might be a stale entry from
        # a renewal cycle). Skip if dhcp-client itself isn't bound.
        :local v6clients [/ipv6 dhcp-client find pool-name=$poolName]
        :if ([:len $v6clients] > 0) do={
            :local v6status [/ipv6 dhcp-client get [:pick $v6clients 0] status]
            :if ($v6status != "bound") do={
                :log info ("wan-reconciler: v6 dhcp-client for " . $poolName . " status=" . $v6status)
                :return true
            }
        }
        :local prefix [/ipv6 pool get [:pick $pools 0] prefix]
        # /routing rule v6 src/dst: declared statically in /routing rule
        # block; reconciler only sets in-place. Set-only is race-free
        # (the dhcp-client script= hook fires from multiple sub-events
        # in close succession; find-then-add would create duplicates).
        # If the comment-tagged entry is missing, log loudly and skip
        # -- restoration requires re-apply or manual re-declare.
        # src-rule update sets both src-address (the /56 we just
        # learned from the lease) AND table (the named per-pool table
        # the src maps to). dst-rule update below sets only dst-address
        # -- dst rules always route to `main` (where the connected
        # LAN routes live), which never changes, so the table= field
        # is stable from bootstrap and doesn't need reconciling.
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
            :log info ("wan-reconciler: v4 " . $ifName . " status=" . $status)
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
    # pool value passes through. The preferred-lifetime *value*
    # (0s vs not) is managed by the up/down scripts + ndPreferredReconcile;
    # this reconciler doesn't override the 0s deprecation -- if the
    # field is 0s, it stays 0s.
    :local v6NdReconcile do={
        :local vlanName $1
        :local poolName $2
        :local parseGuard $3
        :local ltCap 30m
        # Pool-delegation check first: if the pool isn't populated,
        # /ipv6 address bound to it can't be trusted yet (RouterOS
        # may return half-bound transient values like "0:0:0:N::/64"
        # where N is the sub-allocation index but the ISP /56 prefix
        # hasn't been merged in). Skipping early here also avoids
        # races on /ipv6 pool/get later in the function.
        :local pools [/ipv6 pool find name=$poolName]
        :if ([:len $pools] = 0) do={
            :log info ("wan-reconciler: pool " . $poolName . " not delegated yet")
            :return true
        }
        :local poolId [:pick $pools 0]
        # Pool's delegated prefix (ip6-prefix typed, e.g. 2607:..:6100::/56).
        # Used directly with the native `in` operator below to test
        # whether a bound address falls inside the delegation.
        :local poolPrefixStr [/ipv6 pool get $poolId prefix]
        :local addrIds [/ipv6 address find interface=$vlanName from-pool=$poolName]
        :if ([:len $addrIds] = 0) do={
            :log warning ("wan-reconciler: no /ipv6 address " . $vlanName . " " . $poolName)
            :return true
        }
        # Read the bound /ipv6 address ("<addr>/<masklen>") and run it
        # through the shared parse-guard (strip mask, :toip6, in-pool).
        :local raw [/ipv6 address get [:pick $addrIds 0] address]
        :local hostIp [$parseGuard $raw $poolPrefixStr ($vlanName . "-" . $poolName)]
        :if ([:typeof $hostIp] != "ip6") do={ :return true }
        # We compare and write the network /64 only -- the eui-64=yes
        # entries (probe-src-*) carry a host address in the host
        # portion which we deliberately discard; /ipv6 nd prefix
        # should advertise the /64, not a host address.
        :local bound64Net ($hostIp & ffff:ffff:ffff:ffff::)
        :local boundPrefix ([:tostr $bound64Net] . "/64")
        :local cmt ("auto-nd-" . $vlanName . "-" . $poolName)
        :local ndExisting [/ipv6 nd prefix find comment=$cmt]
        :if ([:len $ndExisting] = 0) do={
            :log warning ("wan-reconciler: " . $cmt . " missing -- re-declare in /ipv6 nd prefix (config.rsc) or re-apply")
            :return true
        }
        :local ndId [:pick $ndExisting 0]
        # prefix= update (only on /56 rotation). Both sides are now
        # canonical /64 strings -- the comparison no longer false-
        # mismatches on the host-bits-with-/64-mask form coming from
        # eui-64=yes entries.
        :local cur [/ipv6 nd prefix get $ndId prefix]
        :if ($cur != $boundPrefix) do={
            /ipv6 nd prefix set $ndId prefix=$boundPrefix
            :log info ("wan-reconciler: ROTATED nd " . $vlanName . "-" . $poolName . ": " . $cur . " -> " . $boundPrefix)
        }
        # Lifetime tracking from pool, clamped at 30m. $poolId from
        # the pool-delegation check at the top of the function is
        # still valid here (the pool can't have disappeared between
        # then and now in the same script invocation).
        #
        # NB: /ipv6 pool and /ipv6 nd prefix `get` for time-typed
        # properties (valid-lifetime / preferred-lifetime) return
        # type=str, not type=time. Comparing against time literals
        # (e.g., $x = 0s, $x > $ltCap) silently fails due to type
        # mismatch. Wrap reads in [:totime ...] so the comparisons
        # actually work.
        :local poolValid [:totime [/ipv6 pool get $poolId valid-lifetime]]
        :if ($poolValid > $ltCap) do={ :set poolValid $ltCap }
        :local ndValid [:totime [/ipv6 nd prefix get $ndId valid-lifetime]]
        :if ($ndValid != $poolValid) do={
            /ipv6 nd prefix set $ndId valid-lifetime=$poolValid
        }
        # preferred-lifetime: only for "preferred" entries (current >0s).
        # Deprecated entries (current=0s) are managed by the up/down
        # scripts + ndPreferredReconcile; don't override.
        :local ndPref [:totime [/ipv6 nd prefix get $ndId preferred-lifetime]]
        :if ($ndPref > 0s) do={
            :local poolPref [:totime [/ipv6 pool get $poolId preferred-lifetime]]
            :if ($poolPref > $ltCap) do={ :set poolPref $ltCap }
            :if ($ndPref != $poolPref) do={
                /ipv6 nd prefix set $ndId preferred-lifetime=$poolPref
            }
        }
    }
    # --- nd-prefix preferred-lifetime reconciler: ensure each VLAN's
    # /ipv6 nd prefix preferred-lifetime values agree with the current
    # netwatch probe status. Belt-and-suspenders against the up/down
    # scripts not firing (RouterOS bug, race, manual config drift,
    # apply-day ordering glitches) -- the next reconciler tick (10m)
    # brings the RA-advertised state back into line with what the
    # netwatch probe believes about WAN health. Idempotent: if state
    # is already correct, no writes.
    :local ndPreferredReconcile do={
        :local vlanName $1
        :local preferredPool $2
        :local fallbackPool $3
        :local probeComment $4
        :local nwExisting [/tool netwatch find comment=$probeComment]
        :if ([:len $nwExisting] = 0) do={ :return true }
        :local nwStatus [/tool netwatch get [:pick $nwExisting 0] status]
        :local prefCmt ("auto-nd-" . $vlanName . "-" . $preferredPool)
        :local fallCmt ("auto-nd-" . $vlanName . "-" . $fallbackPool)
        # Resolve nd-prefix ids up front; skip cleanly if either is
        # missing (mirroring v6NdReconcile's pattern -- avoids passing
        # an empty find result into `get`, which would error).
        :local prefExisting [/ipv6 nd prefix find comment=$prefCmt]
        :local fallExisting [/ipv6 nd prefix find comment=$fallCmt]
        :if ([:len $prefExisting] = 0 or [:len $fallExisting] = 0) do={
            :log warning ("wan-reconciler: " . $prefCmt . " or " . $fallCmt . " missing -- re-declare in /ipv6 nd prefix (config.rsc) or re-apply")
            :return true
        }
        :local prefId [:pick $prefExisting 0]
        :local fallId [:pick $fallExisting 0]
        # Target values implied by probe status: probe up means the
        # preferred-pool entry should be preferred (30m) and the
        # fallback-pool entry deprecated (0s); probe down is the
        # inverse. Skip anything else (e.g., status=unknown during
        # startup-delay -- the up/down scripts will set values on
        # the first transition).
        :local prefTarget
        :local fallTarget
        :if ($nwStatus = "up") do={ :set prefTarget 30m; :set fallTarget 0s }
        :if ($nwStatus = "down") do={ :set prefTarget 0s; :set fallTarget 30m }
        :if ([:typeof $prefTarget] = "nothing") do={ :return true }
        # Update if different. Time-property reads wrapped in
        # [:totime ...] -- see v6NdReconcile for the type-mismatch
        # quirk this works around.
        :local prefCur [:totime [/ipv6 nd prefix get $prefId preferred-lifetime]]
        :if ($prefCur != $prefTarget) do={
            /ipv6 nd prefix set $prefId preferred-lifetime=$prefTarget
            :log warning ("wan-reconciler: RESTORED preferred-lifetime " . $prefCmt . " " . $prefCur . " -> " . $prefTarget . " (probe " . $nwStatus . ")")
        }
        :local fallCur [:totime [/ipv6 nd prefix get $fallId preferred-lifetime]]
        :if ($fallCur != $fallTarget) do={
            /ipv6 nd prefix set $fallId preferred-lifetime=$fallTarget
            :log warning ("wan-reconciler: RESTORED preferred-lifetime " . $fallCmt . " " . $fallCur . " -> " . $fallTarget . " (probe " . $nwStatus . ")")
        }
    }
    # --- v4 route-distance failover reconciler: keep each named
    # WAN's d=1 /ip route entries demoted (distance=3) when its probe
    # is down, restored (distance=1) when up. Without this, v4 relies
    # solely on /ip route check-gateway=ping for failover, which only
    # detects gateway death -- not end-to-end transit failure. The
    # netwatch probe catches transit failures via foreign-source-v6;
    # piping that signal into v4 closes the asymmetry. Backstops the
    # up/down scripts' inline distance flips the same way
    # ndPreferredReconcile backstops the v6 nd-prefix flips.
    :local v4RouteFailoverReconcile do={
        :local probeComment $1
        :local wanName $2
        :local nwExisting [/tool netwatch find comment=$probeComment]
        :if ([:len $nwExisting] = 0) do={ :return true }
        :local nwStatus [/tool netwatch get [:pick $nwExisting 0] status]
        :local targetDist
        :if ($nwStatus = "up") do={ :set targetDist 1 }
        :if ($nwStatus = "down") do={ :set targetDist 3 }
        :if ([:typeof $targetDist] = "nothing") do={ :return true }
        :foreach r in=[/ip route find comment~("^auto-v4-route-.*-pri-" . $wanName . "\$")] do={
            :local cur [:tonum [/ip route get $r distance]]
            :if ($cur != $targetDist) do={
                /ip route set $r distance=$targetDist
                :log warning ("wan-reconciler: RESTORED v4 distance " . [/ip route get $r comment] . " " . $cur . " -> " . $targetDist . " (probe " . $nwStatus . ")")
            }
        }
    }
    # --- netwatch src-address reconciler: keep each WAN-probe's
    # src-address in sync with the router's current host GUA in the
    # corresponding pool. The /ipv6 address entry (find by comment
    # "probe-src-<pool>") has eui-64=yes set, so its host part is
    # stable across /56 rotations; only the prefix changes. We read
    # the bound address, strip the /N mask, and `set` it on the
    # matching netwatch entry if it changed.
    :local netwatchSrcReconcile do={
        :local probeComment $1
        :local poolName $2
        :local parseGuard $3
        # Pool-delegation check first (same shape as v6NdReconcile):
        # if the pool isn't populated, /ipv6 address bound to it may
        # have a half-bound transient value with no real /56 prefix.
        :local pools [/ipv6 pool find name=$poolName]
        :if ([:len $pools] = 0) do={
            :log info ("wan-reconciler: pool " . $poolName . " not delegated yet")
            :return true
        }
        :local poolPrefixStr [/ipv6 pool get [:pick $pools 0] prefix]
        :local addrCmt ("probe-src-" . $poolName)
        :local addrExisting [/ipv6 address find comment=$addrCmt]
        :if ([:len $addrExisting] = 0) do={
            :log warning ("wan-reconciler: " . $addrCmt . " /ipv6 address missing -- re-declare in config.rsc or re-apply")
            :return true
        }
        :local raw [/ipv6 address get [:pick $addrExisting 0] address]
        :local addrIp [$parseGuard $raw $poolPrefixStr $addrCmt]
        :if ([:typeof $addrIp] != "ip6") do={ :return true }
        :local nwExisting [/tool netwatch find comment=$probeComment]
        :if ([:len $nwExisting] = 0) do={
            :log warning ("wan-reconciler: netwatch " . $probeComment . " missing -- re-declare in config.rsc or re-apply")
            :return true
        }
        :local nwId [:pick $nwExisting 0]
        # netwatch src-address is typed ip6; compare via :tostr to avoid
        # canonicalization mismatches (e.g., literal vs zero-suppressed).
        :local curSrc [:tostr [/tool netwatch get $nwId src-address]]
        :if ($curSrc != [:tostr $addrIp]) do={
            /tool netwatch set $nwId src-address=$addrIp
            :log info ("wan-reconciler: ROTATED netwatch " . $probeComment . " src-address: " . $curSrc . " -> " . [:tostr $addrIp])
        }
    }
    $v6Reconcile "mb-pd"    "mb"    "mb"
    $v6Reconcile "sonic-pd" "sonic" "sonic"
    $v4Reconcile "ether2"       "mb"
    $v4Reconcile "sfp-sfpplus1" "sonic"
    # v6NdReconcile: 4 VLANs x 2 pools = 8 calls; keep in lockstep with the
    # /ipv6 address from-pool= entries. $parseGuard is passed in because a
    # do={} value can't see sibling locals (LESSONS.md).
    $v6NdReconcile "vlan88" "mb-pd"    $parseGuard
    $v6NdReconcile "vlan88" "sonic-pd" $parseGuard
    $v6NdReconcile "vlan10" "mb-pd"    $parseGuard
    $v6NdReconcile "vlan10" "sonic-pd" $parseGuard
    $v6NdReconcile "vlan20" "mb-pd"    $parseGuard
    $v6NdReconcile "vlan20" "sonic-pd" $parseGuard
    $v6NdReconcile "vlan30" "mb-pd"    $parseGuard
    $v6NdReconcile "vlan30" "sonic-pd" $parseGuard
    # Update netwatch src-address BEFORE ndPreferredReconcile reads
    # probe status, so a /56 rotation doesn't leave the probe pointing
    # at a stale src for a full reconciler tick (10m) before catching up.
    $netwatchSrcReconcile "sonic-probe" "sonic-pd" $parseGuard
    $netwatchSrcReconcile "mb-probe"    "mb-pd"    $parseGuard
    # nd preferred-lifetime reconcile -- args: vlan, preferred-pool, fallback-pool, probe-comment
    # (per-VLAN WAN-affinity policy -- see the /ipv6 nd prefix manifest below)
    $ndPreferredReconcile "vlan10" "sonic-pd" "mb-pd"    "sonic-probe"
    $ndPreferredReconcile "vlan88" "sonic-pd" "mb-pd"    "sonic-probe"
    $ndPreferredReconcile "vlan20" "mb-pd"    "sonic-pd" "mb-probe"
    $ndPreferredReconcile "vlan30" "mb-pd"    "sonic-pd" "mb-probe"
    # v4 route-distance reconcile -- args: probe-comment, wan-name
    $v4RouteFailoverReconcile "sonic-probe" "sonic"
    $v4RouteFailoverReconcile "mb-probe"    "mb"
}

# --- Per-WAN failover scripts (up/down events) ---
# Netwatch probes Cloudflare v6 anycast (2606:4700:4700::1111) from a
# router host GUA in each pool; src-PBR steers via /routing rule. On
# probe status transition, the appropriate script fires to flip
# preferred-lifetime on the affected VLANs' /ipv6 nd prefix entries
# -- clients receive the new RA, RFC 6724 Rule 3 makes them source
# from the non-deprecated pool's GUA, traffic egresses via the
# matching WAN. No DAD wait: clients already hold both GUAs from the
# dual-GUA design. See the netwatch block below for the
# why-this-detects-failure design note.
#
# Each *-down script handles the 2 VLANs whose primary is that WAN:
#   sonic-{up,down} -> vlan10 (plumtree) + vlan88 (mgmt)
#   mb-{up,down}    -> vlan20 (guest) + vlan30 (iot)
#
# policy=read,write,test,reboot: Netwatch invokes scripts as *sys with
# its own policy envelope of {read,write,test,reboot}. Scripts with
# any policy outside that set are refused with "not enough permissions"
# (the default-on-add policy includes policy/password/sniff/sensitive
# /ftp/romon, which exceeds netwatch's envelope -- so they MUST be
# trimmed). See LESSONS.md.
/system script
:if ([:len [/system script find name=sonic-down]] > 0) do={ /system script remove [find name=sonic-down] }
:if ([:len [/system script find name=sonic-up]]   > 0) do={ /system script remove [find name=sonic-up]   }
:if ([:len [/system script find name=mb-down]]    > 0) do={ /system script remove [find name=mb-down]    }
:if ([:len [/system script find name=mb-up]]      > 0) do={ /system script remove [find name=mb-up]      }
# Promote-to-30m sets pin valid-lifetime=30m alongside
# preferred-lifetime=30m to keep RFC 4861's preferred <= valid
# invariant if v6NdReconcile's pool-lifetime clamp had previously
# trimmed valid below 30m (e.g., during a long WAN outage where the
# lease was expiring). RouterOS rejects set commands that violate
# the invariant; without co-setting valid we'd risk aborting the
# script mid-flip and leaving half the VLANs unflipped. The
# reconciler will re-clamp valid to min(pool_lifetime, 30m) on its
# next tick if the pool lease is still small.
add name=sonic-down policy=read,write,test,reboot source={
    :log info "sonic-down: deprecating sonic-pd on vlan10+vlan88, promoting mb-pd; demoting v4 sonic routes"
    :foreach v in={"vlan10";"vlan88"} do={
        /ipv6 nd prefix set [find comment=("auto-nd-" . $v . "-sonic-pd")] preferred-lifetime=0s
        /ipv6 nd prefix set [find comment=("auto-nd-" . $v . "-mb-pd")] preferred-lifetime=30m valid-lifetime=30m
    }
    # v4 failover by netwatch signal (not just check-gateway). Demote the
    # d=1 sonic routes so the d=2 mb fallback wins. Without this, v4 stays
    # stuck on a transit-broken-but-gateway-alive Sonic -- the split-
    # failover case where v6 migrates but v4 doesn't. Uses the SAME regex
    # as v4RouteFailoverReconcile, so a new routing table is demoted by both
    # automatically -- no literal route list to keep in sync.
    :foreach r in=[/ip route find comment~"^auto-v4-route-.*-pri-sonic\$"] do={ /ip route set $r distance=3 }
}
add name=sonic-up policy=read,write,test,reboot source={
    :log info "sonic-up: restoring sonic-pd preferred on vlan10+vlan88, deprecating mb-pd; restoring v4 sonic routes"
    :foreach v in={"vlan10";"vlan88"} do={
        /ipv6 nd prefix set [find comment=("auto-nd-" . $v . "-sonic-pd")] preferred-lifetime=30m valid-lifetime=30m
        /ipv6 nd prefix set [find comment=("auto-nd-" . $v . "-mb-pd")] preferred-lifetime=0s
    }
    :foreach r in=[/ip route find comment~"^auto-v4-route-.*-pri-sonic\$"] do={ /ip route set $r distance=1 }
}
add name=mb-down policy=read,write,test,reboot source={
    :log info "mb-down: deprecating mb-pd on vlan20+vlan30, promoting sonic-pd; demoting v4 mb routes"
    :foreach v in={"vlan20";"vlan30"} do={
        /ipv6 nd prefix set [find comment=("auto-nd-" . $v . "-mb-pd")] preferred-lifetime=0s
        /ipv6 nd prefix set [find comment=("auto-nd-" . $v . "-sonic-pd")] preferred-lifetime=30m valid-lifetime=30m
    }
    # Same regex as v4RouteFailoverReconcile (auto-demotes any new pri-mb route).
    :foreach r in=[/ip route find comment~"^auto-v4-route-.*-pri-mb\$"] do={ /ip route set $r distance=3 }
}
add name=mb-up policy=read,write,test,reboot source={
    :log info "mb-up: restoring mb-pd preferred on vlan20+vlan30, deprecating sonic-pd; restoring v4 mb routes"
    :foreach v in={"vlan20";"vlan30"} do={
        /ipv6 nd prefix set [find comment=("auto-nd-" . $v . "-mb-pd")] preferred-lifetime=30m valid-lifetime=30m
        /ipv6 nd prefix set [find comment=("auto-nd-" . $v . "-sonic-pd")] preferred-lifetime=0s
    }
    :foreach r in=[/ip route find comment~"^auto-v4-route-.*-pri-mb\$"] do={ /ip route set $r distance=1 }
}

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
#
# NB: script= is NOT set here. It gets wired up near the end of the
# script (after all reconciler-managed entries -- routing rules,
# routes, /ipv6 nd prefix, /tool netwatch -- have been declared). If
# we set script= here, the dhcp-client `add` would bind immediately
# during apply and fire wan-reconciler against half-declared state,
# spamming "missing" warnings for every entry not yet created.
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
# /ipv6 dhcp-client add-default-route defaults to `no` on RouterOS 7.x
# (unlike /ip dhcp-client which defaults to yes), so the explicit `no`
# here also serves as belt-and-suspenders against future schema drift.
# use-peer-dns inherits the default `yes`, parallel to /ip dhcp-client.
#
# script= deferred to the end of the script -- see /ip dhcp-client
# above for the rationale.
/ipv6 dhcp-client
add interface=ether2       request=address,prefix pool-name=mb-pd    pool-prefix-length=64 accept-prefix-without-address=yes add-default-route=no
add interface=sfp-sfpplus1 request=address,prefix pool-name=sonic-pd pool-prefix-length=64 accept-prefix-without-address=yes add-default-route=no

# --- IPv6 GUA per-VLAN from DHCPv6-PD pools (Phase B-MB + Phase C) ---
# from-pool= on RouterOS 7.x is prefix-only-to-interface by default: the
# pool's /64 binds to the VLAN as a network address (for routing); the
# router gets no host GUA on the interface. Clients SLAAC their own
# GUAs; router stays reachable via per-VLAN ULA ::1 (Phase A) and
# link-local. /64 re-derives automatically on lease renewal.
#
# All entries advertise=no -- the dynamic /ipv6 nd prefix entries that
# would otherwise be auto-derived can't be `set`-mutated on RouterOS
# 7.x (confirmed through 7.23: `set` on a dynamic entry still returns
# "failure: can not change dynamic prefix"; see LESSONS.md). Instead,
# RA emission is driven by EXPLICIT static
# /ipv6 nd prefix entries (below) with per-VLAN-per-pool
# preferred-lifetime bias, which IS settable and is the mechanism the
# up/down failover scripts use.
#
# Both pools stay bound on every VLAN so source-PBR can match either
# /64. Clients get TWO GUAs per VLAN -- the primary pool's preferred,
# the secondary pool's deprecated.
#
# vlan88's entries set eui-64=yes -- gives the router a stable host
# GUA per pool (prefix from pool + EUI-64 from bridge MAC), used as
# the v6 Netwatch probe src-address. mgmt VLAN chosen because that's
# where router-originated probe traffic naturally belongs. The host
# part is stable across /56 rotations (MAC is pinned admin-mac);
# only the prefix changes. wan-reconciler tracks the prefix change
# into the netwatch src-address field. See LESSONS.md (netwatch
# probes via foreign-source v6) for the design rationale.
/ipv6 address
add from-pool=mb-pd    interface=vlan88 advertise=no eui-64=yes comment="probe-src-mb-pd"
add from-pool=mb-pd    interface=vlan10 advertise=no
add from-pool=mb-pd    interface=vlan20 advertise=no
add from-pool=mb-pd    interface=vlan30 advertise=no
add from-pool=sonic-pd interface=vlan88 advertise=no eui-64=yes comment="probe-src-sonic-pd"
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
# Per-VLAN WAN-affinity policy (steady state) -- THE canonical manifest.
# All sites below implement it; keep them in lockstep when repointing a
# VLAN or adding one:
#   vlan10 (plumtree), vlan88 (mgmt) -> sonic-pd PREFERRED, mb-pd DEPRECATED
#   vlan20 (guest), vlan30 (iot)     -> mb-pd PREFERRED, sonic-pd DEPRECATED
# Sites that encode this policy (edit together):
#   1. the preferred-lifetime 30m/0s pairs in this /ipv6 nd prefix block
#   2. /routing rule -- v4 src->table and v6 src->table
#   3. ndPreferredReconcile call args (wan-reconciler call-list)
#   4. the sonic-/mb-{up,down} failover scripts
#   5. (adding a VLAN only) the /ipv6 address from-pool= entries
#
# The Netwatch up/down scripts flip preferred-lifetime on these
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
# BOOTSTRAP — prefix= literals are seeds matching the *expected*
# RouterOS /64 sub-allocation from each /56 (sequential by /ipv6
# address add order above: vlan88 gets the first /64, vlan10 the
# second, etc). NB: this suffix is an ISP sub-allocation index, NOT
# the ULA VLAN-id-as-hex scheme (:10::, :88::) used in Phase A above.
# wan-reconciler reads the actually-bound /64 from /ipv6 address and
# `set prefix=` if it differs.
#
# Empirical quirk (observed 2026-05-24): when /ipv6 address entries
# are declared before the dhcp-client (i.e., from-pool waits on the
# lease), mb-pd's sub-allocation order doesn't strictly follow
# declaration order -- vlan88 (eui-64=yes, first add) ends up at
# /6104::/64 instead of /6100::/64. sonic-pd doesn't show the same
# skew; both pools get the same declaration order, so it appears
# RouterOS-specific to mb-pd's binding sequence. The reconciler
# heals it (one ROTATED line in the apply-day log); since the
# stored bootstrap doesn't predict the sub-allocation reliably,
# we leave /6100 as the literal and accept the one-line drift
# rather than chase a moving target.
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
# BOOTSTRAP — gateway literals are seeds captured at Stage 0/1 bind;
# wan-reconciler heals them from the live dhcp-client gateway.
/ip route
add dst-address=0.0.0.0/0 gateway=23.93.120.1    routing-table=main  distance=1 check-gateway=ping comment="auto-v4-route-main-pri-sonic"
add dst-address=0.0.0.0/0 gateway=162.217.74.129 routing-table=main  distance=2                    comment="auto-v4-route-main-sec-mb"
add dst-address=0.0.0.0/0 gateway=162.217.74.129 routing-table=mb    distance=1 check-gateway=ping comment="auto-v4-route-mb-pri-mb"
add dst-address=0.0.0.0/0 gateway=23.93.120.1    routing-table=mb    distance=2                    comment="auto-v4-route-mb-sec-sonic"
add dst-address=0.0.0.0/0 gateway=23.93.120.1    routing-table=sonic distance=1 check-gateway=ping comment="auto-v4-route-sonic-pri-sonic"
add dst-address=0.0.0.0/0 gateway=162.217.74.129 routing-table=sonic distance=2                    comment="auto-v4-route-sonic-sec-mb"

# --- routing rules for per-VLAN source-based PBR (Stage 2) ---
# Per-VLAN src->table assignments here implement the WAN-affinity policy;
# see the canonical manifest in the /ipv6 nd prefix block above.
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
# here as BOOTSTRAP seeds (current ISP /56s, healed by wan-reconciler) and tagged with
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
# All dst-rules grouped above src-rules: routing rules are evaluated
# top-down, first match wins. A LAN-to-LAN packet between two clients
# whose GUAs are in the same PD /56 needs to match the dst rule
# (-> main, where the connected /64 routes live) BEFORE the src rule
# (-> table=<wan>, which would shunt the inter-LAN packet out the WAN).
# Mirrors the v4 structure above where dst=192.168.0.0/16 -> main
# is first.
add dst-address=fd7f:aee1:6ce0::/48      action=lookup table=main  comment="v6 ULA LAN dsts -> main"
add dst-address=2607:f598:d488:6100::/56 action=lookup table=main  comment="auto-v6-dst-mb-pd"
add dst-address=2001:5a8:6a5:4600::/56   action=lookup table=main  comment="auto-v6-dst-sonic-pd"
add src-address=2607:f598:d488:6100::/56 action=lookup table=mb    comment="auto-v6-src-mb-pd"
add src-address=2001:5a8:6a5:4600::/56   action=lookup table=sonic comment="auto-v6-src-sonic-pd"

# --- v6 default routes per routing table (Stage 2) ---
# Same shape as /ip route above; gateways are the upstream link-locals
# (visible in /ipv6 dhcp-client print detail as dhcp-server-v6=).
# BOOTSTRAP — the literal gateways here are seeds; the wan-reconciler
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
# ICMP accept is scoped to LAN: echo replies and PMTUD come through as
# `related` via the est/rel/untracked rule above, so we don't need to
# accept new ICMP from WAN (which would just enable router-pingable
# enumeration from the internet).
add action=accept chain=input comment="accept established,related,untracked" connection-state=established,related,untracked
add action=drop   chain=input comment="drop invalid" connection-state=invalid
add action=accept chain=input comment="accept ICMP from LAN" protocol=icmp in-interface-list=LAN
add action=accept chain=input comment="accept loopback" in-interface=lo src-address=127.0.0.1 dst-address=127.0.0.1
add action=drop   chain=input comment="drop everything not from LAN" in-interface-list=!LAN

# --- forward chain ---
# MikroTik docs say FastTrack routes via the main routing table only
# and doesn't respect /routing rule. Verified empirically 2026-05-25:
# iot (vlan30, PBR -> table=mb) Netflix streams correctly via MB even
# under FastTrack on both v4 and v6. RouterOS 7.x's actual behavior
# is to use the conntrack's cached output interface (set when the
# initial SYN went through /routing rule), not re-do main-table lookups
# per packet. Safe to keep the broad fasttrack rule; revisit if a future
# RouterOS version tightens the "main table only" semantic.
add action=fasttrack-connection chain=forward comment="fasttrack" connection-state=established,related
add action=accept chain=forward comment="accept established,related,untracked" connection-state=established,related,untracked
add action=drop   chain=forward comment="drop invalid" connection-state=invalid
add action=drop   chain=forward comment="drop WAN-originated, non-DSTNATed" connection-nat-state=!dstnat connection-state=new in-interface-list=WAN

# inter-VLAN policy. Order doesn't matter among these (mutually exclusive matches).
add action=drop chain=forward in-interface=vlan20 out-interface-list=LAN comment="guest -> LAN: blocked"
add action=drop chain=forward in-interface=vlan30 out-interface=vlan88   comment="iot -> mgmt: blocked"
add action=drop chain=forward in-interface=vlan30 out-interface=vlan10 connection-state=new comment="iot -> plumtree: new conns blocked (returns OK)"
add action=drop chain=forward in-interface=vlan30 out-interface=vlan20   comment="iot -> guest: blocked"

# Terminal default-drop for anything in forward chain that's not
# LAN-originated. The "drop WAN-originated, non-DSTNATed" rule above
# already covers the common case; this is defense-in-depth (and
# parity with v6 forward, which ends the same way).
add action=drop chain=forward comment="drop everything not from LAN" in-interface-list=!LAN

# --- NAT (masquerade out the WAN) ---
/ip firewall nat
add action=masquerade chain=srcnat out-interface-list=WAN comment="masquerade WAN egress"

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
# ICMPv6 accept is scoped to LAN. RouterOS handles ND (NS/NA/RS/RA)
# below the firewall layer, so this doesn't break upstream-gateway
# resolution on the WAN side. PMTUD return ("packet too big") arrives
# as `related` and matches the est/rel rule above, so it still flows.
add action=accept chain=input comment="accept established,related,untracked" connection-state=established,related,untracked
add action=drop   chain=input comment="drop invalid" connection-state=invalid
add action=accept chain=input comment="accept ICMPv6 from LAN" protocol=icmpv6 in-interface-list=LAN
add action=accept chain=input comment="accept UDP traceroute from LAN" dst-port=33434-33534 protocol=udp in-interface-list=LAN
# DHCPv6 client replies legitimately arrive only on WAN interfaces from
# the upstream router's link-local. Scoping to WAN prevents a LAN host
# from crafting DHCPv6-shaped traffic aimed at the router's client.
add action=accept chain=input comment="accept DHCPv6 PD" dst-port=546 protocol=udp src-address=fe80::/10 in-interface-list=WAN
# Loopback accept (mirrors v4 input chain). Internal router processes
# that communicate over ::1 need this; without it the drop-!LAN below
# would catch them since `lo` isn't in the LAN interface-list.
add action=accept chain=input comment="accept loopback v6" in-interface=lo src-address=::1 dst-address=::1
add action=drop   chain=input comment="drop everything not from LAN" in-interface-list=!LAN

# FastTrack-vs-PBR: see the v4 fasttrack note above. Same verification
# applies for v6 (iot vlan30, mb-pd-preferred GUA, streams via MB
# correctly under FastTrack).
add action=fasttrack-connection chain=forward comment="fasttrack6" connection-state=established,related
add action=accept chain=forward comment="accept established,related,untracked" connection-state=established,related,untracked
add action=drop   chain=forward comment="drop invalid" connection-state=invalid
add action=drop   chain=forward comment="drop bad src ipv6" src-address-list=bad_ipv6
add action=drop   chain=forward comment="drop bad dst ipv6" dst-address-list=bad_ipv6
add action=drop   chain=forward comment="rfc4890 hop-limit=1" hop-limit=equal:1 protocol=icmpv6
# v4-parity drop for WAN-originated new connections. Without this,
# the broad ICMPv6 accept below would let internet hosts probe LAN
# clients' GUAs. v4 has the same shape on its forward chain above.
add action=drop chain=forward comment="drop WAN-originated new (v6 parity)" connection-state=new in-interface-list=WAN

# Inter-VLAN policy parity with the IPv4 forward-chain drops above.
# Placed BEFORE the broad ICMPv6 accept below so iot->plumtree ICMPv6 echo
# (etc.) is dropped consistently with v4. Same-VLAN ND is link-local and
# never traverses forward, so the ICMPv6 accept below still covers ND.
add action=drop chain=forward in-interface=vlan20 out-interface-list=LAN comment="guest -> LAN: blocked"
add action=drop chain=forward in-interface=vlan30 out-interface=vlan88 comment="iot -> mgmt: blocked"
add action=drop chain=forward in-interface=vlan30 out-interface=vlan10 connection-state=new comment="iot -> plumtree: new conns blocked (returns OK)"
add action=drop chain=forward in-interface=vlan30 out-interface=vlan20 comment="iot -> guest: blocked"

# ICMPv6 forward scoped to LAN as belt-and-suspenders against the
# WAN-new drop above (anything WAN-originated is already gone by here).
add action=accept chain=forward comment="accept ICMPv6 from LAN" protocol=icmpv6 in-interface-list=LAN
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

# --- Netwatch WAN-reachability probes ---
# Per-WAN probe of Cloudflare v6 anycast 2606:4700:4700::1111 from
# the router's own host GUA in the named pool. src-PBR (via the
# /routing rule chain) steers the probe through the matching WAN;
# on a WAN-down event the reply path can't reach us, so the probe
# times out and the down-script fires. See LESSONS.md (Bug A) for
# why the foreign-source v6 form is what makes this detection work,
# vs. the v4-LAN-src design it replaces.
#
# packet-count=3 + packet-interval=500ms gives single-probe flap
# suppression. (RouterOS 7.x exposes an icmp loss-threshold --
# thr-loss-percent and related thr-* properties -- that didn't exist
# on 7.21.4 when this was written; they're left unset here. Tuning
# gating via thr-* is a possible refinement, deliberately not taken.)
# startup-delay=60s holds probes until dhcp-clients have bound on
# apply-day.
#
# BOOTSTRAP — src-address literals are seeds; netwatchSrcReconcile
# heals them on /56 rotation. Host part 6f4:1cff:fe51:bad8 is
# EUI-64 from the pinned bridge MAC 04:F4:1C:51:BA:D8.
/tool netwatch
add comment=sonic-probe type=icmp host=2606:4700:4700::1111 src-address=2001:5a8:6a5:4600:6f4:1cff:fe51:bad8 interval=10s timeout=2s packet-count=3 packet-interval=500ms startup-delay=60s up-script=sonic-up down-script=sonic-down
add comment=mb-probe    type=icmp host=2606:4700:4700::1111 src-address=2607:f598:d488:6100:6f4:1cff:fe51:bad8 interval=10s timeout=2s packet-count=3 packet-interval=500ms startup-delay=60s up-script=mb-up    down-script=mb-down

# --- Wire up dhcp-client script= hooks; explicit apply-day bootstrap ---
# All reconciler-managed entries (/routing rule, /ip route, /ipv6 route,
# /ipv6 nd prefix, /tool netwatch) are now declared, so it's safe to wire
# script=. (Why deferred to here rather than set at the dhcp-client add:
# see the /ip dhcp-client block above.)
#
# /system script run below explicitly bootstraps the reconciler now that
# script= is set -- substitutes for the apply-day-bootstrap we'd otherwise
# get from the first dhcp bind.
/ip dhcp-client
set [find interface=ether2]       script="/system script run wan-reconciler"
set [find interface=sfp-sfpplus1] script="/system script run wan-reconciler"
/ipv6 dhcp-client
set [find interface=ether2]       script="/system script run wan-reconciler"
set [find interface=sfp-sfpplus1] script="/system script run wan-reconciler"
/system script run wan-reconciler

# --- wan-reconciler scheduler tick (belt-and-suspenders) ---
# Placed near the end of the script for two reasons:
#  - "essential first, automation last" file ordering principle.
#  - All reconciler-managed entries (/routing rule, routes, /ipv6 nd
#    prefix, /tool netwatch) are declared above; scheduler firing
#    has everything it needs.
# Event-driven trigger is the dhcp-client script= hook (set just
# above, fires on lease bind/value-change, immediate reaction). This
# 10m tick catches drift from any source the event misses -- manual
# edits, missed events, bugs.
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
    # policy: least-privilege. Default-on-add is the full 10-flag set;
    # the scheduler only runs wan-reconciler (itself read,write,test),
    # and an invoked script runs under caller ∩ script policy, so
    # read,write,test is the minimal set that lets it do its job.
    /system scheduler add name=wan-reconciler-tick on-event="/system script run wan-reconciler" interval=10m policy=read,write,test
} on-error={
    :log warning "config.rsc: /system scheduler add failed (cold-bootstrap device-mode reset?). Event-driven reconciler still active; re-enable scheduler via /system device-mode + button-confirm to restore polling."
}

# --- LEDs + reset-button-press toggle (cosmetic; placed at the end) ---
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
:if ([:len [/system script find name=toggle-leds]] > 0) do={
    /system script remove [find name=toggle-leds]
}
add name=toggle-leds policy=read,write source={
    :local cur [/system leds settings get all-leds-off]
    :if ($cur = "never") do={
        /system leds settings set all-leds-off=immediate
    } else={
        /system leds settings set all-leds-off=never
    }
}
/system routerboard reset-button
set enabled=yes hold-time=0s..2s on-event=toggle-leds

:log info "config.rsc: done"
