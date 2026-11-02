[prism/]
mode: 0771
user: AID_ROOT
group: AID_SYSTEM
caps: 0

[optics/]
mode: 0771
user: AID_ROOT
group: AID_SYSTEM
caps: 0

[metadata/]
mode: 0771
user: AID_ROOT
group: AID_SYSTEM
caps: 0

[efs/]
mode: 0771
user: AID_SYSTEM
group: AID_RADIO
caps: 0

[carrier/]
mode: 0771
user: AID_SYSTEM
group: AID_RADIO
caps: 0

[dqmdbg/]
mode: 0770
user: AID_SYSTEM
group: AID_SYSTEM
caps: 0

[omr/]
mode: 0771
user: AID_SYSTEM
group: AID_SYSTEM
caps: 0

[spu/]
mode: 0770
user: AID_SYSTEM
group: AID_SYSTEM
caps: 0

[keydata/]
mode: 0771
user: AID_SYSTEM
group: AID_SYSTEM
caps: 0

[keyrefuge/]
mode: 0771
user: AID_SYSTEM
group: AID_SYSTEM
caps: 0

[system/product/vendor_overlay/*/bin/*]
mode: 0755
user: AID_ROOT
group: AID_SHELL
caps: 0

[product/vendor_overlay/*/bin/*]
mode: 0755
user: AID_ROOT
group: AID_SHELL
caps: 0
[AID_VENDOR_QRTR]
value: 2906

[AID_VENDOR_SPAY]
value: 5279

[AID_VENDOR_QTI_DIAG]
value: 2901

# v122: built-in root. AOSP su relies on the su domain being permissive to
# setgid/setuid, but on this ROM the domain transition never fires (the
# process stays in the shell domain and lacks CAP_SETGID, so su dies with
# "setgid failed: Operation not permitted"). Making the binary setuid-root
# sidesteps that: the kernel elevates uid/gid before su.cpp runs, so the
# setgid/setuid calls succeed regardless of domain.
#
# 4750 keeps it executable by owner and group only. su.cpp's uid gate is
# already removed (v122), so any process that can execute this binary gets
# root.
[xbin/su]
mode: 04750
user: AID_ROOT
group: AID_ROOT
caps: 0
