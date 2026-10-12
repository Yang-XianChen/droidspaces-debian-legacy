#!/bin/sh
# ---------------------------------------------------------------------------
# Droidspaces Android / legacy-kernel compatibility layer (build-time)
#
# Runs inside the rootfs while it is being built. It mirrors
# Android/app/src/main/assets/post_extract_fixes.sh from Droidspaces-OSS -- the
# pass the app runs on a freshly extracted tarball -- and adds the tweaks a
# 4.9-era Android kernel needs on top.
#
# IMPORTANT: this script writes /etc/droidspaces. Because that marker exists,
# the app SKIPS its own post-extract pass for this rootfs, so everything the
# app would have done for a Debian/systemd image has to be done here.
# ---------------------------------------------------------------------------
set -eu

log() { echo "[legacy-fixes] $*"; }

GUEST_SYSTEMD_PATH=/lib/systemd/system
if [ -d /usr/lib/systemd/system ]; then
    GUEST_SYSTEMD_PATH=/usr/lib/systemd/system
fi

# ---------------------------------------------------------------------------
# 1. Android paranoid networking (present in Android kernels up to 4.14)
#
# With CONFIG_ANDROID_PARANOID_NETWORK=y the kernel only lets processes in
# aid_inet (3003) / aid_net_raw (3004) / aid_net_admin (3005) open sockets.
# Without these groups the container has no network at all, whatever
# Droidspaces sets up on the host side.
# ---------------------------------------------------------------------------
log "Android network groups (aid_inet / aid_net_raw / aid_net_admin)"
grep -q '^aid_inet:'      /etc/group || echo 'aid_inet:x:3003:'      >> /etc/group
grep -q '^aid_net_raw:'   /etc/group || echo 'aid_net_raw:x:3004:'   >> /etc/group
grep -q '^aid_net_admin:' /etc/group || echo 'aid_net_admin:x:3005:' >> /etc/group

# Hardware-access groups (present on a normal Debian install, created here if
# this rootfs ever lacks them)
for g in input video tty; do
    getent group "$g" >/dev/null 2>&1 || groupadd -r "$g" 2>/dev/null || true
done

usermod -a -G aid_inet,aid_net_raw,input,video,tty root 2>/dev/null || true

# apt drops privileges to _apt; it must be able to open a socket too.
grep -q '^_apt:' /etc/passwd && usermod -g aid_inet _apt 2>/dev/null || true

# Users created later with adduser get network + hardware access automatically.
if [ -f /etc/adduser.conf ]; then
    sed -i '/^EXTRA_GROUPS=/d; /^ADD_EXTRA_GROUPS=/d' /etc/adduser.conf
    echo 'ADD_EXTRA_GROUPS=1' >> /etc/adduser.conf
    echo 'EXTRA_GROUPS="aid_inet aid_net_raw input video tty"' >> /etc/adduser.conf
fi

# ---------------------------------------------------------------------------
# 2. xtables: Android kernels ship x_tables, not nf_tables
#    Every iptables frontend must be the legacy one or it silently fails.
# ---------------------------------------------------------------------------
log "Switching xtables frontends to the legacy backend"
for tool in iptables ip6tables arptables ebtables; do
    if [ -f "/var/lib/dpkg/alternatives/$tool" ] && [ -x "/usr/sbin/$tool-legacy" ]; then
        update-alternatives --set "$tool" "/usr/sbin/$tool-legacy" 2>/dev/null || true
        continue
    fi
    for dir in usr/sbin usr/bin sbin; do
        if [ -x "/$dir/$tool-legacy" ]; then
            ln -sf "/$dir/$tool-legacy" "/$dir/$tool"
            break
        fi
    done
done

# ---------------------------------------------------------------------------
# 3. systemd
# ---------------------------------------------------------------------------
if [ -x /usr/bin/systemctl ] || [ -x /bin/systemctl ]; then
    SYSTEMD_VERSION=$(/lib/systemd/systemd --version 2>/dev/null | head -1 | awk '{print $2}' | tr -dc '0-9')
    [ -n "$SYSTEMD_VERSION" ] || SYSTEMD_VERSION=0
    log "systemd detected at $GUEST_SYSTEMD_PATH (v$SYSTEMD_VERSION), applying fixes"
    mkdir -p /etc/systemd/system

    # 3a. Services that deadlock, spin or are pointless on legacy Android kernels
    #     - journald-audit.socket: known systemd deadlock on 4.9 (Droidspaces docs)
    #     - networkd-wait-online: waits forever, Droidspaces brings eth0 up itself
    #     - getty@tty1: a phone has no virtual terminals; a respawning getty
    #       just burns CPU. The Droidspaces console/PTY is used instead.
    #     - apt daily timers: pull package lists over metered mobile data
    for unit in \
        systemd-networkd-wait-online.service \
        systemd-journald-audit.socket \
        getty@tty1.service \
        apt-daily.timer \
        apt-daily-upgrade.timer
    do
        ln -sf /dev/null "/etc/systemd/system/$unit"
    done

    # 3b. journald: skip audit and /dev/kmsg (both are broken in containers)
    if [ -f /etc/systemd/journald.conf ]; then
        cat >> /etc/systemd/journald.conf << 'EOT'

[Journal]
ReadKMsg=no
Audit=no
Storage=volatile
EOT
    fi
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/ds-logging.conf << 'EOT'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=200M
MaxRetentionSec=7day
MaxLevelStore=info
EOT

    # 3c. Never set a tasks limit systemd cannot enforce: the pids controller is
    #     frequently absent on 4.9 vendor kernels. Same for the per-unit CPU and
    #     memory accounting systemd switches on by default -- on a kernel booted
    #     with cgroup_disable=memory (very common on Android) every single unit
    #     start would otherwise fail. The Droidspaces limits set from the host
    #     (--memory/--cpus/--pids-limit) are applied to the container's own
    #     cgroup and are not affected by this.
    #     Delete this file if you want systemd's accounting back.
    #     (DefaultTasksMax exists since v227, the accounting switches are older,
    #     so this file is valid on every systemd this project targets.)
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/10-droidspaces-legacy.conf << 'EOT'
# Droidspaces: legacy (4.9 and older) Android kernels often ship an incomplete
# cgroup v1 hierarchy, so per-unit accounting either fails on every start or is
# reported wrongly. Only keys understood by systemd 232 .. 252 are used here.
[Manager]
DefaultCPUAccounting=no
DefaultMemoryAccounting=no
DefaultTasksAccounting=no
DefaultTasksMax=infinity
EOT

    # 3d. Enable the services a container actually needs
    mkdir -p /etc/systemd/system/multi-user.target.wants
    for service in dbus.service systemd-udevd.service systemd-resolved.service \
                   systemd-networkd.service NetworkManager.service; do
        if [ -f "$GUEST_SYSTEMD_PATH/$service" ]; then
            ln -sf "$GUEST_SYSTEMD_PATH/$service" \
                  "/etc/systemd/system/multi-user.target.wants/$service"
        fi
    done

    # systemd-resolved needs a writable /run/systemd/resolve at boot; Debian's
    # unit creates it, but a container that starts resolved before /run is
    # populated fails. RuntimeDirectoryRefresh is not needed on 247/252, the
    # unit's own RuntimeDirectory= covers it.

    # 3e. The phone's power key must not shut the container down
    mkdir -p /etc/systemd/logind.conf.d
    cat > /etc/systemd/logind.conf.d/99-power-key.conf << 'EOT'
[Login]
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandlePowerKeyLongPress=ignore
HandlePowerKeyLongPressHibernate=ignore
EOT

    # 3f. udev in a container: coldplugging the phone's real hardware is useless
    #     and slow, and /sys may be mounted read-only.
    mkdir -p /etc/systemd/system/systemd-udev-trigger.service.d
    cat > /etc/systemd/system/systemd-udev-trigger.service.d/override.conf << 'EOT'
[Service]
ExecStart=
ExecStart=-/usr/bin/udevadm trigger --subsystem-match=usb --subsystem-match=block --subsystem-match=input --subsystem-match=tty --subsystem-match=net
EOT

    for unit in systemd-udevd.service systemd-udev-trigger.service systemd-udev-settle.service \
                systemd-udevd-kernel.socket systemd-udevd-control.socket; do
        mkdir -p "/etc/systemd/system/${unit}.d"
        printf '[Unit]\nConditionPathIsReadWrite=\n' > "/etc/systemd/system/${unit}.d/99-readonly-fix.conf"
    done

    # 3g. Network services must stay away from the phone's own interfaces when
    #     the container shares the host network stack (host mode) and are
    #     pointless with no interface at all (none mode).
    #     ExecCondition= needs systemd >= 243 (Debian 10 and newer). Debian 9
    #     ships systemd 232, which silently ignores the unknown key, so there we
    #     use ExecStartPre= instead: a failing ExecStartPre aborts the unit,
    #     which is the same outcome at the cost of a "failed" unit state.
    NETMODE_TEST="grep -q '^net_mode=' /run/droidspaces/container.config && ! grep -qE '^net_mode=(host|none)\$' /run/droidspaces/container.config"
    if [ "${SYSTEMD_VERSION:-0}" -ge 243 ] 2>/dev/null; then
        NETMODE_KEY="ExecCondition=
ExecCondition=/bin/sh -c \"$NETMODE_TEST\""
    else
        NETMODE_KEY="ExecStartPre=/bin/sh -c \"$NETMODE_TEST || { echo 'droidspaces: host/none network mode, service not started'; exit 1; }\""
    fi
    for unit in NetworkManager.service dhcpcd.service systemd-resolved.service systemd-networkd.service; do
        if [ -f "$GUEST_SYSTEMD_PATH/$unit" ] || [ -e "/etc/systemd/system/multi-user.target.wants/$unit" ]; then
            mkdir -p "/etc/systemd/system/${unit}.d"
            printf '[Service]\n%s\n' "$NETMODE_KEY" > "/etc/systemd/system/${unit}.d/99-netmode-limit.conf"
        fi
    done

    # 3h. DHCP on the veth Droidspaces hands the container (NAT / gateway /
    #     macvlan). In NAT mode Droidspaces also writes /etc/resolv.conf.
    mkdir -p /etc/systemd/network
    cat > /etc/systemd/network/10-eth-dhcp.network << 'EOT'
[Match]
Name=eth*

[Network]
DHCP=yes
IPv6AcceptRA=yes

[DHCPv4]
UseDNS=yes
UseDomains=yes
RouteMetric=100
EOT

    # 3h-bis. Debian 11 ships no systemd-resolved package, yet Droidspaces
    #         points /etc/resolv.conf at /run/systemd/resolve/resolv.conf for a
    #         systemd rootfs in gateway/macvlan mode (in NAT mode it writes its
    #         own list, so this does not matter there). Publish the DHCP lease
    #         DNS at that path ourselves so gateway/macvlan also resolve names.
    if [ ! -x /lib/systemd/systemd-resolved ] && [ ! -x /usr/lib/systemd/systemd-resolved ]; then
        log "No systemd-resolved: installing the DHCP-lease DNS publisher"
        cat > /usr/local/bin/ds-publish-lease-dns << 'EOT'
#!/bin/sh
# Publish the DNS servers from the systemd-networkd DHCP lease where
# Droidspaces expects them on a systemd rootfs (/run/systemd/resolve/resolv.conf).
# Writes nothing and fails when no lease DNS is known yet.
set -u
CONF=/run/droidspaces/container.config
mode=$(sed -n 's/^net_mode=//p' "$CONF" 2>/dev/null | head -1)
case "$mode" in
    gateway|macvlan) ;;
    *) exit 1 ;;
esac
out=/run/systemd/resolve/resolv.conf
tmp="$out.tmp"
mkdir -p /run/systemd/resolve
: > "$tmp"
found=0
for lease in /run/systemd/netif/leases/*; do
    [ -f "$lease" ] || continue
    sed -n 's/^DNS=//p' "$lease" | tr ' ' '\n' | while IFS= read -r ip; do
        case "$ip" in ''|*[!0-9a-fA-F:.]*) continue ;; esac
        echo "nameserver $ip"
    done >> "$tmp"
done
if [ -s "$tmp" ]; then
    mv "$tmp" "$out"
    found=1
else
    rm -f "$tmp"
fi
[ "$found" = "1" ]
EOT
        chmod 0755 /usr/local/bin/ds-publish-lease-dns

        cat > /etc/systemd/system/droidspaces-lease-dns.service << 'EOT'
[Unit]
Description=Publish the Droidspaces DHCP lease DNS (systemd-resolved is unavailable)
After=systemd-networkd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'i=0; while [ $i -lt 30 ]; do /usr/local/bin/ds-publish-lease-dns && exit 0; i=$((i+1)); sleep 2; done; printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /run/systemd/resolve/resolv.conf'

[Install]
WantedBy=multi-user.target
EOT
        chmod 0644 /etc/systemd/system/droidspaces-lease-dns.service
        ln -sf /etc/systemd/system/droidspaces-lease-dns.service \
               /etc/systemd/system/multi-user.target.wants/droidspaces-lease-dns.service
    fi

    # 3i. binfmt_misc for qemu-user-static, if it is installed later
    mkdir -p /usr/local/bin
    cat > /usr/local/bin/qemu-binfmt-register.sh << 'EOT'
#!/bin/sh
set -eu
BINFMT_MISC="/proc/sys/fs/binfmt_misc"
log() { echo "qemu-binfmt: $*"; }
if ! grep -q binfmt_misc /proc/filesystems 2>/dev/null; then
    log "binfmt_misc not supported by kernel, skipping"
    exit 0
fi
if ! grep -q "$BINFMT_MISC" /proc/mounts; then
    if ! mount -t binfmt_misc binfmt_misc "$BINFMT_MISC"; then
        log "failed to mount binfmt_misc, skipping"
        exit 0
    fi
fi
exit 0
EOT
    chmod 0755 /usr/local/bin/qemu-binfmt-register.sh

    cat > /etc/systemd/system/qemu-binfmt-register.service << 'EOT'
[Unit]
Description=Register QEMU binfmt_misc handlers
DefaultDependencies=no
After=local-fs.target
Before=sysinit.target proc-sys-fs-binfmt_misc.automount

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/qemu-binfmt-register.sh

[Install]
WantedBy=multi-user.target
EOT
    chmod 0644 /etc/systemd/system/qemu-binfmt-register.service
    ln -sf /etc/systemd/system/qemu-binfmt-register.service \
           /etc/systemd/system/multi-user.target.wants/qemu-binfmt-register.service
else
    log "systemd not found, skipping systemd fixes"
fi

# ---------------------------------------------------------------------------
# 4. Misc container hygiene
# ---------------------------------------------------------------------------
log "Container hygiene (machine-id, timezone)"

# A pre-generated machine-id avoids a first-boot stall; the app overwrites it
# with its own on installation, and Droidspaces does not care either way.
# (Safe to write: unlike the three files below, /etc/machine-id is not
# bind-mounted by the build.)
if [ ! -s /etc/machine-id ]; then
    tr -d '-' < /proc/sys/kernel/random/uuid > /etc/machine-id
    echo >> /etc/machine-id
    chmod 0444 /etc/machine-id
fi

# /etc/hosts, /etc/hostname and /etc/resolv.conf are intentionally NOT touched
# here: the container build bind-mounts all three read-only, and Droidspaces
# rewrites them at every container start anyway (fix_networking_rootfs() writes
# the hostname, /etc/hosts and the /etc/resolv.conf symlink after pivot_root).

if [ -e /usr/share/zoneinfo/UTC ]; then
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime
    echo UTC > /etc/timezone
fi

# ---------------------------------------------------------------------------
# 5. Tell the app the rootfs is already fixed (it will then skip its own pass)
# ---------------------------------------------------------------------------
log "Marking rootfs as fixed"
{
    echo "Droidspaces legacy-kernel rootfs fixes applied on $(date -u +%FT%TZ)"
    echo "Debian legacy build for Android kernels 3.10 - 4.19 (4.9 verified)"
} > /etc/droidspaces

log "Done"
