#!/bin/bash
# ---------------------------------------------------------------------------
# Verify a Droidspaces rootfs tarball produced by ./build.sh
#
#   ./verify.sh out/<file>.tar.xz                     # static checks
#   ./verify.sh out/<file>.tar.xz --runtime           # + run inside the rootfs
#   ./verify.sh out/<file>.tar.xz --legacy-syscalls   # + 4.9 syscall surface
#   ./verify.sh out/<file>.tar.xz --boot              # + try booting systemd
#   ./verify.sh out/<file>.tar.xz --runtime --legacy-syscalls --boot
#
# --runtime/--legacy-syscalls/--boot need the image loaded by build.sh
# (droidspaces-legacy/<Name>:<version>); pass --image to point at another tag.
# ---------------------------------------------------------------------------
set -u
cd "$(dirname "$0")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
LISTFILE="$WORK/entries.txt"
ROOT="$WORK/root"

TARBALL=""
IMAGE=""
DO_RUNTIME=0
DO_SYSCALLS=0
DO_BOOT=0
PLATFORM="${DS_PLATFORM:-linux/arm64}"

while [ $# -gt 0 ]; do
    case "$1" in
        --runtime) DO_RUNTIME=1; shift ;;
        --legacy-syscalls) DO_RUNTIME=1; DO_SYSCALLS=1; shift ;;
        --boot) DO_BOOT=1; shift ;;
        --image) IMAGE="$2"; shift 2 ;;
        --platform) PLATFORM="$2"; shift 2 ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) TARBALL="$1"; shift ;;
    esac
done

[ -n "$TARBALL" ] || { echo "Usage: $0 <tarball> [--runtime] [--legacy-syscalls] [--boot] [--image TAG]" >&2; exit 1; }
[ -f "$TARBALL" ] || { echo "No such file: $TARBALL" >&2; exit 1; }

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32m[ OK ]\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33m[WARN]\033[0m %s\n' "$1"; WARN=$((WARN+1)); }
head_() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

# Find the docker image build.sh loaded for this tarball (droidspaces-legacy/<name>:<ver>)
resolve_image() {
    [ -n "$IMAGE" ] && return 0
    BASE=$(basename "$TARBALL")
    GUESS=$(echo "$BASE" | sed 's/-Droidspaces-rootfs-.*//' | tr '[:upper:]' '[:lower:]')
    IMAGE=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -i "^droidspaces-legacy/$GUESS:" | head -1)
}

head_ "1. 归档完整性 / archive integrity"
if xz -t "$TARBALL" 2>/dev/null; then ok "xz 流完整"; else bad "xz 流损坏"; exit 1; fi
SIZE=$(stat -c '%s' "$TARBALL")
echo "  size    : $SIZE bytes ($(numfmt --to=iec "$SIZE" 2>/dev/null || echo "$SIZE"))"
if [ -f "$TARBALL.sha256" ]; then
    ( cd "$(dirname "$TARBALL")" && sha256sum -c "$(basename "$TARBALL").sha256" >/dev/null 2>&1 ) \
        && ok "sha256 匹配 ($(cut -c1-16 "$TARBALL.sha256"))" || bad "sha256 不匹配"
else
    warn "没有 .sha256 文件"
fi

head_ "2. 归档内容 / archive layout"
case "$TARBALL" in
    *.tar.xz) TAROPT="-J" ;;
    *.tar.gz|*.tgz) TAROPT="-z" ;;
    *) TAROPT="" ;;
esac
LIST=$(tar $TAROPT -tf "$TARBALL")
# normalise: tar entries may or may not carry a "./" or "/" prefix
printf '%s\n' "$LIST" | sed 's|^\./||; s|^/||; s|/*$||' > "$LISTFILE"
COUNT=$(wc -l < "$LISTFILE")
echo "  entries : $COUNT"

# The app's own validator (validate_rootfs.sh) requires these four top-level
# entries, otherwise it refuses to install the tarball.
for d in bin sbin etc usr; do
    if grep -qxF "$d" "$LISTFILE"; then ok "顶层 $d"
    else bad "顶层 $d 缺失（App 会拒绝安装）"; fi
done

for p in etc/debian_version etc/passwd etc/group usr/bin/sh etc/droidspaces \
         etc/systemd/network/10-eth-dhcp.network \
         etc/systemd/system.conf.d/10-droidspaces-legacy.conf \
         etc/systemd/system/systemd-journald-audit.socket \
         etc/systemd/system/systemd-networkd.service.d/99-netmode-limit.conf \
         usr/local/bin/ds-legacy-check; do
    if grep -qxF "$p" "$LISTFILE"; then ok "$p"
    else bad "缺少 $p"; fi
done

if grep -qE '(^|/)(usr/)?lib/systemd/systemd$' "$LISTFILE"; then
    ok "systemd 二进制存在"
else
    bad "找不到 systemd 二进制"
fi
have_runtime=0
for d in proc sys var/lib/docker; do
    if [ -d "$ROOT/$d" ] && [ -n "$(find "$ROOT/$d" -mindepth 1 -print -quit 2>/dev/null)" ]; then
        warn "$d 里有内容（可能是意外打包的运行时文件）"
        have_runtime=1
    fi
done
[ "$have_runtime" = "0" ] && ok "没有打包运行时的 proc/sys/var-lib-docker 内容（空目录无害）"

head_ "3. 解包检查 / extracted tree"
mkdir -p "$ROOT"
tar --no-same-owner $TAROPT -xf "$TARBALL" -C "$ROOT"

RV=$(cat "$ROOT/etc/debian_version" 2>/dev/null)
[ -n "$RV" ] && ok "Debian $RV" || bad "读不到 /etc/debian_version"

SYSV=$(awk '/^Package: systemd$/{p=1} p&&/^Version:/{print $2; exit}' "$ROOT/var/lib/dpkg/status" 2>/dev/null)
echo "  systemd : ${SYSV:-unknown}"
case "$SYSV" in
    247*|248*|249*|250*|251*|252*|25[3-7]*) ok "systemd < 258（4.x 内核可用）" ;;
    "") warn "无法从 dpkg status 读取 systemd 版本" ;;
    *) bad "systemd $SYSV 可能不支持 < 5.4 内核（258+ 移除了回退路径）" ;;
esac
LIBV=$(awk '/^Package: libc6$/{p=1} p&&/^Version:/{print $2; exit}' "$ROOT/var/lib/dpkg/status" 2>/dev/null)
echo "  glibc   : ${LIBV:-unknown}"

grep -q '^aid_inet:.*:3003:' "$ROOT/etc/group" && ok "aid_inet:3003 存在" || bad "aid_inet 缺失"
grep -q '^aid_net_raw:.*:3004:' "$ROOT/etc/group" && ok "aid_net_raw:3004 存在" || bad "aid_net_raw 缺失"
grep -q '^_apt:' "$ROOT/etc/passwd" && ok "_apt 用户存在（apt 可用 aid_inet 联网）" || warn "_apt 用户不存在"

if [ -f "$ROOT/var/lib/dpkg/alternatives/iptables" ]; then
    grep -q 'iptables-legacy' "$ROOT/var/lib/dpkg/alternatives/iptables" && \
        ok "iptables 已指向 legacy 后端" || warn "iptables alternatives 未指向 legacy"
fi

echo "  /etc/droidspaces: $(head -1 "$ROOT/etc/droidspaces" 2>/dev/null)"
[ -f "$ROOT/etc/droidspaces" ] && ok "已标记 post-extract fixes（App 会跳过自己的修补）" || warn "缺少 /etc/droidspaces 标记"

echo "  legacy 调优:"
sed -n 's/^/    /p' "$ROOT/etc/systemd/system.conf.d/10-droidspaces-legacy.conf" 2>/dev/null | head -12

head_ "4. 就绪 / summary"
printf '  PASS=%d  WARN=%d  FAIL=%d\n' "$PASS" "$WARN" "$FAIL"

if [ "$DO_RUNTIME" = "1" ]; then
    head_ "5. 运行时冒烟测试 / runtime smoke test"
    resolve_image
    if [ -z "$IMAGE" ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        warn "找不到已加载的镜像（build.sh 默认会 --load 一个），跳过运行时检查"
    else
        echo "  image   : $IMAGE ($PLATFORM)"
        SECOPT=()
        if [ "$DO_SYSCALLS" = "1" ]; then
            SECOPT=(--security-opt "seccomp=$PWD/scripts/seccomp-4.9.json")
            echo "  seccomp : 屏蔽 4.9 之后的系统调用（clone3/openat2/statx/...）"
        fi
        CMD='
set -e
echo "uname   : $(uname -m)"
echo "debian  : $(cat /etc/debian_version)"
echo "systemd : $(/lib/systemd/systemd --version 2>/dev/null | head -1)"
echo "glibc   : $(ldd --version 2>/dev/null | head -1)"
echo "systemctl --version: $(systemctl --version 2>/dev/null | head -1)"
echo "root groups: $(id -Gn root)"
echo "aid_inet : $(getent group aid_inet)"
echo "iptables : $(readlink -f "$(command -v iptables)")"
echo "dpkg audit: $(dpkg --audit 2>&1 | head -1)"
echo "bash    : $(bash --version | head -1)"
echo "git     : $(git --version)"
echo "ssh     : $(ssh -V 2>&1)"
echo "perl    : $(perl -e "print \"ok\"" 2>/dev/null || echo missing)"
echo "marker  : $(head -1 /etc/droidspaces)"
ls -l /lib/systemd/system/systemd-journald-audit.socket 2>/dev/null || ls -l /etc/systemd/system/systemd-journald-audit.socket
/usr/local/bin/ds-legacy-check >/tmp/check.out 2>&1 && echo "ds-legacy-check: ran (exit 0)" || echo "ds-legacy-check: exit $?"
'
        if docker run --rm --platform "$PLATFORM" "${SECOPT[@]}" "$IMAGE" /bin/bash -c "$CMD"; then
            ok "冒烟测试全部命令成功"
        else
            bad "冒烟测试有命令失败"
        fi
    fi
fi

if [ "$DO_BOOT" = "1" ]; then
    head_ "6. systemd 启动尝试 / attempt a systemd boot"
    resolve_image
    if [ -z "$IMAGE" ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        warn "需要已加载的镜像（先跑 ./build.sh），跳过"
    else
        NAME="dsboot-$$"
        docker rm -f "$NAME" >/dev/null 2>&1 || true
        echo "  starting $IMAGE as PID 1 (this proves userspace + init work, kernel is the host's)..."
        docker run -d --name "$NAME" --platform "$PLATFORM" \
            --cap-add=ALL --security-opt seccomp="$PWD/scripts/seccomp-4.9.json" \
            --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
            --tmpfs /run --tmpfs /tmp "$IMAGE" \
            /lib/systemd/systemd --system --log-target=console --log-level=info >/dev/null 2>&1
        for i in $(seq 1 20); do
            sleep 3
            STATE=$(docker exec "$NAME" systemctl is-system-running 2>/dev/null || true)
            [ -n "$STATE" ] && [ "$STATE" != "starting" ] && break
        done
        STATE=$(docker exec "$NAME" systemctl is-system-running 2>/dev/null || echo unknown)
        echo "  is-system-running: $STATE"
        docker exec "$NAME" systemctl --failed --no-pager 2>/dev/null | head -15 | sed 's/^/  /'
        case "$STATE" in
            running|degraded) ok "systemd 启动到了 multi-user（$STATE）" ;;
            *) warn "systemd 状态: $STATE（容器内启动 systemd 本身有限制，仅供参考）" ;;
        esac
        docker logs "$NAME" 2>&1 | tail -15 | sed 's/^/  | /'
        docker rm -f "$NAME" >/dev/null 2>&1 || true
    fi
fi

exit $(( FAIL > 0 ? 1 : 0 ))
