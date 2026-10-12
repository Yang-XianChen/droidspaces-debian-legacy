#!/bin/sh
# ---------------------------------------------------------------------------
# ds-legacy-check -- verify inside a Droidspaces container that this rootfs is
# running the way a legacy (3.10 - 4.19, e.g. 4.9) Android kernel requires.
#
#   droidspaces -n <name> enter      # then:
#   ds-legacy-check
#
# Read-only: it inspects, it never changes anything.
# ---------------------------------------------------------------------------
set -u

ok()   { printf '  \033[32m[ OK ]\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m[WARN]\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

KREL=$(uname -r)
KMAJ=$(echo "$KREL" | sed 's/^\([0-9]*\)\.\([0-9]*\).*/\1.\2/')
ADVICE=""

add_advice() { ADVICE="$ADVICE
  - $1"; }

head_ "1. 内核 / Kernel"
echo "  release : $KREL"
echo "  arch    : $(uname -m)"
case "$KMAJ" in
    3.*|4.*)
        echo "  class   : legacy (< 5.4) -> 需要 systemd < 258；Debian 11/12 满足"
        ;;
    5.*|6.*|7.*)
        echo "  class   : modern (>= 5.4)"
        ;;
    *)  echo "  class   : unknown" ;;
esac

head_ "2. 命名空间 / Namespaces"
if [ -d /proc/self/ns ]; then
    NS=$(ls /proc/self/ns 2>/dev/null | tr '\n' ' ')
    echo "  /proc/self/ns : $NS"
    MISSING=""
    for ns in mnt pid uts ipc net; do
        case " $NS " in *" $ns "*) ;; *) MISSING="$MISSING $ns" ;; esac
    done
    if [ -n "$MISSING" ]; then
        bad "缺少命名空间:$MISSING (宿主内核未开启对应 CONFIG_*_NS)"
    else
        ok "mnt/pid/uts/ipc/net 全部存在"
    fi
    case " $NS " in *" user "*) ok "user namespace 可用（Allow Sandboxing 可用）" ;;
                     *) echo "  user namespace 不可用（Allow Sandboxing 会被禁用）" ;; esac
else
    bad "/proc/self/ns 不存在，/proc 未挂载？"
fi

head_ "3. cgroup 模式 / cgroup mode"
CGMODE="unknown"
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
    CGMODE=v2
    CTRL=$(cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null)
    echo "  模式    : cgroup v2 (unified)"
    echo "  控制器  : ${CTRL:-<empty>}"
    for c in cpu memory pids; do
        case " $CTRL " in
            *" $c "*) ok "controller '$c' 可用" ;;
            *) warn "controller '$c' 不在 v2 根上（旧内核常见）" ;;
        esac
    done
elif [ -d /sys/fs/cgroup/memory ] || [ -d /sys/fs/cgroup/cpu ]; then
    CGMODE=v1
    echo "  模式    : cgroup v1 (legacy)"
    for c in cpu memory pids; do
        if [ -d "/sys/fs/cgroup/$c" ]; then ok "controller '$c' 已挂载"
        else warn "controller '$c' 未挂载/内核未启用"; fi
    done
else
    warn "/sys/fs/cgroup 下既没有 v2 也没有 v1，宿主可能没挂 cgroup"
fi
if [ -r /proc/cgroups ]; then
    echo "  /proc/cgroups:"
    awk 'NR==1{printf "    %-16s %-4s %-4s %s\n",$1,$2,$3,$4} NR>1{printf "    %-16s %-4s %-4s %s\n",$1,$2,$3,$4}' /proc/cgroups
fi

head_ "4. 容器配置 / container.config"
CONF=/run/droidspaces/container.config
if [ -r "$CONF" ]; then
    while IFS= read -r line; do
        case "$line" in
            net_mode=*|force_cgroupv1=*|memory_limit=*|cpu_limit=*|pids_limit=*|enable_ipv6=*|privileged=*)
                echo "  $line" ;;
        esac
    done < "$CONF"
    NETMODE=$(sed -n 's/^net_mode=//p' "$CONF" | head -1)
    FORCEV1=$(sed -n 's/^force_cgroupv1=//p' "$CONF" | head -1)
    case "$KMAJ" in
        3.*|4.*)
            if [ "$CGMODE" = v2 ]; then
                if [ "${FORCEV1:-0}" = "1" ]; then
                    ok "旧内核 + 宿主 cgroup v2：已开启 Force Cgroup V1（正确）"
                else
                    bad "旧内核 + 宿主 cgroup v2，但 force_cgroupv1=0"
                    add_advice "在容器配置里打开 Force Cgroup V1（CLI: --force-cgroupv1），否则 systemd 可能起不来/卡住"
                fi
            else
                ok "宿主已是 cgroup v1，无需 force_cgroupv1"
            fi
            ;;
    esac
    echo "  net_mode: ${NETMODE:-<unset>}"
else
    warn "$CONF 不存在（从容器内看不到宿主运行时目录？）"
fi

head_ "5. Android 网络组 / paranoid networking"
if grep -q '^aid_inet:' /etc/group; then
    ok "组 aid_inet(3003) 存在"
    if id -Gn root 2>/dev/null | tr ' ' '\n' | grep -qx aid_inet; then
        ok "root 属于 aid_inet"
    else
        bad "root 不在 aid_inet 里 -> socket: permission denied"
        add_advice "执行: usermod -a -G aid_inet,aid_net_raw root"
    fi
else
    bad "/etc/group 缺少 aid_inet"
    add_advice "补上: echo 'aid_inet:x:3003:' >> /etc/group && usermod -a -G aid_inet,aid_net_raw root"
fi
for g in aid_net_raw aid_net_admin; do
    grep -q "^$g:" /etc/group && ok "组 $g 存在" || warn "组 $g 缺失"
done
if [ -s /sys/module/paranoid_network/parameters/paranoid ] 2>/dev/null; then
    echo "  paranoid networking 模块参数: $(cat /sys/module/paranoid_network/parameters/paranoid 2>/dev/null)"
fi

head_ "6. 网络 / Networking"
if [ -r /etc/resolv.conf ]; then
    if [ -L /etc/resolv.conf ]; then
        TGT=$(readlink -f /etc/resolv.conf 2>/dev/null || readlink /etc/resolv.conf)
        if [ -e "$TGT" ]; then ok "/etc/resolv.conf -> $TGT"
        else bad "/etc/resolv.conf -> $TGT 是死链接"; add_advice "重启容器让 Droidspaces 重建 resolv.conf"; fi
    else
        ok "/etc/resolv.conf 是普通文件"
    fi
    sed -n 's/^nameserver /  nameserver /p' /etc/resolv.conf | head -5
else
    bad "/etc/resolv.conf 缺失"
fi
if command -v ip >/dev/null 2>&1; then
    ip -brief addr show 2>/dev/null | sed 's/^/  /' || true
    ip route show 2>/dev/null | sed 's/^/  route: /' || true
fi

head_ "7. iptables 后端 / xtables backend"
if command -v iptables >/dev/null 2>&1; then
    REAL=$(readlink -f "$(command -v iptables)" 2>/dev/null)
    case "$REAL" in
        *-legacy*) ok "iptables -> $REAL (legacy，Android 内核需要)" ;;
        *-nft*)    bad "iptables -> $REAL (nft，Android 内核 x_tables-only 下会失败)"
                   add_advice "切回 legacy: update-alternatives --set iptables /usr/sbin/iptables-legacy" ;;
        *)         warn "iptables -> $REAL" ;;
    esac
    iptables -L -n >/dev/null 2>&1 && ok "iptables 可读规则表" || warn "iptables 无法读取规则表（缺 CAP_NET_ADMIN？）"
else
    warn "没有安装 iptables"
fi

head_ "8. 系统调用面 / syscall surface"
if [ -r /proc/kallsyms ]; then
    for sym in clone3 openat2 faccessat2 pidfd_open; do
        if grep -q "$sym" /proc/kallsyms 2>/dev/null; then
            echo "  内核导出 $sym（该调用在本内核存在）"
        else
            echo "  内核未导出 $sym（旧内核预期行为）"
        fi
    done
else
    echo "  /proc/kallsyms 不可读（kptr_restrict），改用版本判断: $KMAJ"
fi
echo "  glibc   : $(ldd --version 2>/dev/null | head -1)"
if [ -x /lib/systemd/systemd ]; then
    echo "  systemd : $(/lib/systemd/systemd --version 2>/dev/null | head -1)"
    echo "  注意    : systemd >= 258 不再支持 < 5.4 内核（本镜像为 247/252）"
fi

head_ "9. 存储 / Storage"
df -h / 2>/dev/null | sed 's/^/  /'
mount 2>/dev/null | awk '/ \/ /{print "  root mount: "$0}' | head -1

head_ "结论 / Verdict"
if [ -z "$ADVICE" ]; then
    ok "没有发现需要处理的问题。"
else
    printf '需要处理:\n%s\n' "$ADVICE"
fi
echo
