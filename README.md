# Droidspaces 老内核容器包（Debian 11 / 12，支持 4.9 老内核）

给 **Android 老内核（3.10 – 4.19，重点 4.9）** 用的 Droidspaces rootfs 容器包，
用 debian 老版本构建，产出 `.tar.xz`，在手机上用 App 的 **从文件安装** 直接装。

- 适用设备举例：小米 8 SE（**grus** / SDM710 / 内核 4.9）、任何 4.4 / 4.9 / 4.14 / 4.19 的 Android 设备
- 前置条件：Bootloader 已解锁、已 root（KernelSU / Magisk / APatch）、内核已打开 namespace + cgroup（见 `Droidspaces-安卓运行调研.md`）
- 产出：`out/Debian-12-bookworm-Minimal-Kernel-4.9-...tar.xz`（推荐）、`out/Debian-11-bullseye-Minimal-Kernel-4.9-...tar.xz`（备用）

---

## 0. 为什么必须用「老 Debian」

| 组件 | 现代发行版（Debian 13 / Arch / Fedora） | 本包（Debian 11 / 12） |
|---|---|---|
| systemd | 258+ **移除了 < 5.4 内核的回退**，直接调 `clone3` / `openat2`，4.9 上没有这些系统调用 → 报 "Unsupported Kernel"、早期崩溃或卡住 | **247 / 252**，远低于 258，老内核全部有回退路径 |
| glibc | 2.41 起对内核有更高要求 | 2.31 / 2.36，要求内核 ≥ 3.2 |
| cgroup | 默认 cgroup v2 unified | systemd 把 cgroup v1 当一等公民，正好是 4.9 提供的模式 |
| iptables | 默认 nft 后端 | 1.8 legacy 后端（Android 内核只有 x_tables） |

> 参考：Droidspaces 官方 [Troubleshooting](https://github.com/ravindu644/Droidspaces-OSS/blob/main/Documentation/Troubleshooting.md#a-modern-distribution-will-not-boot-on-an-old-kernel)
> 与 `Documentation/Kernel-Configuration.md` 的版本表（4.4–4.19 需要 systemd < 258）。

> ⚠️ 注意：systemd < 258 只是「不会因为缺 syscall 回退而硬失败」，**cgroup 模式还要单独处理** —— 见下一节。

---

## 0.5 ★ 4.9 真机实测结论（小米 9 SE / grus，内核 4.9.337）

| 包 | systemd | 4.9 上能不能直接跑 | 说明 |
|---|---|---|---|
| **Debian 10 Buster** | 241 | ✅ **可以** | systemd 241 默认 hybrid cgroup，不开开关也能起 —— **本设备唯一验证可用的** |
| Debian 11 Bullseye | 247 | ❌ **死锁** | 不开 Force Cgroup V1：网络初始化失败 + CPU 顶到 100%；**开了之后仍然死锁**（已实测） |
| Debian 12 Bookworm | 252 | ❌ 預計同 11 | systemd ≥ 247 同一行为，未单独复测 |

**原因（已定位）**：systemd ≥ 247 **默认使用 unified cgroup v2**；而 4.9 的 cgroup v2 是个空壳 ——
`/sys/fs/cgroup/cgroup.controllers` 里没有 `cpu` / `memory` / `pids`。systemd 因此误判运行环境，
服务（尤其 `systemd-networkd`）起不来，反复重启的单元把 CPU 顶到 100%。systemd 241（Debian 10）
默认还是 hybrid/v1，所以完全不受影响。这正是 Droidspaces 官方文档里 `--force-cgroupv1` 的适用场景
（原文：*"For old Android kernels, 4.9 and earlier, whose cgroup v2 is missing the controllers
systemd expects, which makes systemd misread the environment and fail to boot."*）

**怎么处理**：

- **这台设备（grus / 4.9.337）就用 Debian 10**。实测：打开「强制 Cgroup V1」后 Debian 11 **仍然死锁**，
  所以这个开关在这里是必要但不充分 —— 别再在 11/12 上耗时间。
- 代价：Debian 10 的软件源已 EOL 冻结（`archive.debian.org`），没有安全更新，包也更老。
- 想继续往上试的话，唯一还有意义的变量是 **systemd 版本**（241 → 232 / 247 / 252），
  但按目前结果，4.9 这条路线上 Debian 10 就是终点。

进去以后跑 `ds-legacy-check`：第 3 节会列出 cgroup v2 缺哪些控制器，第 4 节根据 systemd 版本直接
告诉你要不要开这个开关、以及不开会出什么现象。

---

## 1. 目录内容

```
droidspaces-debian-legacy/
├── build.sh                      # 构建：docker buildx，产出 out/*.tar.xz
├── verify.sh                     # 校验：归档 / 内容 / 运行时 / 4.9 系统调用面 / 启动
├── README.md                     # 本文件
├── rootfs.json                   # 由 CI 生成：App「管理软件源」订阅用
├── .github/workflows/
│   └── build-rootfs.yml          # ★ GitHub Actions：arm64 原生 runner 构建 + 发 release
├── templates/aarch64/
│   ├── Debian-12-bookworm-Minimal-Kernel-4.9.Dockerfile
│   ├── Debian-11-bullseye-Minimal-Kernel-4.9.Dockerfile   # 老内核首选
│   └── Debian-10-buster-Minimal-Kernel-4.9.Dockerfile     # 更老（已冻结）
├── scripts/
│   ├── legacy-fixes.sh           # ★ 兼容层：所有 Android/老内核修补都在这里
│   ├── ds-legacy-check.sh        # ★ 装进镜像，手机里跑 `ds-legacy-check` 出体检报告
│   ├── seccomp-4.9.json          # 用 seccomp 屏蔽 4.9 之后的系统调用，用于本地验证
│   ├── make-rootfs-json.py       # 由 *.tar.xz 生成 rootfs.json 订阅源
│   ├── localsend-send.py         # 可选的 LocalSend v2 客户端（把包直接推到手机）
│   ├── bashrc.sh                 # 来自官方 builder 的别名脚本
│   └── download-firmware         # 来自官方 builder 的固件下载器
└── out/                          # 本地构建产物 + sha256（不入库）
```

> **基础镜像就是官方精简 docker 镜像**：`FROM debian:bookworm / bullseye / buster`
> （压缩后 52 / 56 / 50 MB），不是 ISO、也不是从源码装的。构建只做了两件事：
> ① 装「能引导 + 能联网」必需的东西（systemd-sysv、udev、dbus、iproute2…）；
> ② 跑 `scripts/legacy-fixes.sh` 打上 Android / 老内核补丁。
> **原始 docker 镜像不能直接当容器包**：里面没有 init（没有 `/sbin/init`，
> Droidspaces 要求 rootfs 里有 init 才能当 PID 1），也没有 aid_inet 组、
> iptables-legacy、journald 4.9 死锁屏蔽、cgroup 记账关闭这些补丁 ——
> 直接导出的镜像在手机上要么起不来，要么起来了没网。

---

## 2. 手机安装

### 方式 A：从 GitHub 仓库直接下载（推荐）

CI 每构建一次就发一个 release，并更新 `rootfs.json`：

```
仓库      https://github.com/Yang-XianChen/droidspaces-debian-legacy
订阅源    https://raw.githubusercontent.com/Yang-XianChen/droidspaces-debian-legacy/main/rootfs.json
Release   https://github.com/Yang-XianChen/droidspaces-debian-legacy/releases/latest
```

手机上二选一：

- **订阅软件源**：Droidspaces App → Containers → `+` → **管理软件源 / Manage Repositories**
  → 添加上面的「订阅源」URL → 回到列表选 Debian 10/11/12 → **Download** → **Install**。
- **手动装**：手机浏览器打开 Release 页，下载 `.tar.xz`，再
  App → Containers → `+` → **Install from file** 选中它。

### 方式 B：本地文件推过去

```sh
# LocalSend（同一个 Wi-Fi，手机上打开 LocalSend，允许接收）
python3 scripts/localsend-send.py send --to 9se out/Debian-11-*.tar.xz
# 或者 adb
adb push out/Debian-11-*.tar.xz /sdcard/Download/
```

### 安装向导怎么选（重要）

| 步骤 | 怎么选 | 为什么 |
|---|---|---|
| 名称 / hostname | 随意，例如 `debian` | — |
| **配置** | **打开「强制 Cgroup V1」**；网络选 **NAT** | 4.9 的 cgroup v2 缺 systemd 需要的控制器，不强制 v1 时 systemd 可能误判环境、卡在启动 |
| 存储 | **保持「使用稀疏镜像」开启** | `/data` 是 f2fs + SELinux，目录型 rootfs 会随机损坏；镜像内 ext4 才是 OverlayFS 接受的 lowerdir |
| 摘要 | 确认 → 安装 | 解压约 1–3 分钟 |

启动后进 **Terminal**，先跑一次体检：

```sh
ds-legacy-check
```

它会逐项报告：命名空间、cgroup 模式、`force_cgroupv1` 是否已开、aid_inet 组、
iptables 后端、4.9 缺失的系统调用、DNS、存储。有任何一项要处理，它会给出具体命令。

### CLI 等价（Termux root shell）

```sh
droidspaces --name=deb --rootfs-img=/path/deb.img --net=nat --force-cgroupv1 start
droidspaces -n deb enter
droidspaces check
```

---

## 3. 这个包为 4.9 改了什么

全部集中在 `scripts/legacy-fixes.sh`（构建时执行），它同时复刻了 App 的
`post_extract_fixes.sh` 做的事 —— 因为脚本会写 `/etc/droidspaces` 标记，App 之后会跳过自己的修补。

### 3.1 老内核专属

| 修补 | 针对的内核/问题 |
|---|---|
| **屏蔽 `systemd-journald-audit.socket`** | 4.9 上 journald audit 会导致 systemd 死锁（官方文档点名） |
| **关闭 systemd 逐 unit 的 CPU/内存/Tasks 记账，`DefaultTasksMax=infinity`** | 4.9 厂商内核常常 `cgroup_disable=memory` 或根本没有 pids 控制器；不关的话每个服务启动都失败/刷日志。宿主侧 `--memory/--cpus/--pids-limit` 不受影响（那是 Droidspaces 在容器自己的 cgroup 上设的） |
| **aid_inet(3003) / aid_net_raw(3004) / aid_net_admin(3005) + root 入组 + `_apt` 主组** | `CONFIG_ANDROID_PARANOID_NETWORK=y`（≤4.14 普遍存在）：不在这些组里连 `ping` 都报 `socket: permission denied` |
| **`iptables/ip6tables/arptables/ebtables → *-legacy`** | Android 内核只有 x_tables，nf_tables 前端会静默失败 |
| **屏蔽 `getty@tty1`** | 手机没有 VT，留着只是让一个 getty 反复重启烧 CPU |
| **关闭 `apt-daily` / `apt-daily-upgrade` 定时器** | 默认每天拉一次包索引，走移动数据很费流量（要用可以删掉 `/etc/systemd/system/apt-daily*.timer` 符号链接再 `systemctl enable`） |
| **Debian 11 专用：DHCP 租约 DNS 发布器** | Debian 11 没有 `systemd-resolved` 包，而 Droidspaces 在 systemd rootfs 的 gateway/macvlan 模式下会把 `/etc/resolv.conf` 指向 `/run/systemd/resolve/resolv.conf`；这个 oneshot 服务把 networkd 租约里的 DNS 写到那儿，避免死链接（NAT 模式本来就不需要，Droidspaces 自己写） |

### 3.2 与官方镜像一致的 Android 适配（同样做在这个包里）

- journald：`ReadKMsg=no` / `Audit=no` / `Storage=volatile`，限制 200M、保留 7 天
- 屏蔽 `systemd-networkd-wait-online.service`
- udev：只 coldplug `usb/block/input/tty/net`；`/sys` 只读时给 udevd 相关 unit 加 `ConditionPathIsReadWrite=`
- 网络模式守卫：`NetworkManager / dhcpcd / systemd-resolved / systemd-networkd` 加
  `ExecCondition`，**host / none 模式不启动**（防止容器里的网络管理器去动手机的网卡）
- `systemd-networkd` 对容器 veth（`eth*`）做 DHCP
- logind：忽略电源键/挂起键（否则按一下电源键容器就关机）
- `dbus / systemd-udevd / systemd-resolved / systemd-networkd` 预置为启用
- 预生成 `machine-id`、`/etc/hosts`、`/etc/hostname`
- 自带 `ds-legacy-check`、`download-firmware`、`bashrc` 别名
- SSH：`PermitRootLogin prohibit-password`（只能用密钥登录 root），用户密码登录保留

### 3.3 没做的事（有意）

- **不带 `docker.io` / `qemu-user-static`**：4.9 起步阶段越小越稳，需要时容器内 `apt install` 即可（`qemu-binfmt-register.service` 已预置，装上 qemu 就能用 amd64 程序）
- **不改内核参数**：`force_cgroupv1` 是 App 侧开关，rootfs 里改不了
- **不做 NixOS / OpenRC 那套修正**：本包是 Debian + systemd

---

## 4. 选哪个版本

| | Debian 12 bookworm | **Debian 11 bullseye**（老内核首选） | Debian 10 buster |
|---|---|---|---|
| systemd | 252 | 247 | 241 |
| glibc | 2.36 | 2.31 | 2.28 |
| **4.9 实测** | ❌ 未复测，预计同 11 | ❌ 开关也救不了（死锁） | ✅ **唯一验证可用**（见 0.5 节） |
| 内核支持 | 3.10 – 4.19（官方也把 12/13 列为老内核方案） | 同左，回退路径更多 | 同左，回退路径最多 |
| 软件源 | `deb.debian.org` + `security` **正常维护** | EOL（2026-08-31）→ `archive.debian.org`，**冻结无更新** | EOL（2024-06-30）→ `archive.debian.org`，**冻结无更新** |
| 体积 | 90 MB | 85 MB | 80 MB |
| 什么时候选 | 想要还能收到安全更新 | 内核 4.x，想尽量远离 systemd 258 那条线 | 想要最少配置、或（4.9 上）不想动 cgroup 开关 |

> 注意：Bullseye / Buster 都已 EOL。实测 `deb.debian.org/debian-security` 上 bullseye 的
> `Packages` 索引还在，但 **`.deb` 全部 404**（构建时报错），所以这两个镜像都改成走
> `archive.debian.org`，装到手机上以后**不会再有安全更新** —— 要长期联网用就选 bookworm。
> 如果是「起不来」的问题，Bullseye（systemd 247）已经比 Bookworm 保守一大截；
> 还想更老就自己加 `templates/aarch64/Debian-9-stretch-...Dockerfile`（systemd 232，
> 脚本里的兼容层已经按 systemd 232 处理 `ExecCondition` 的缺失）。

---

## 5. 手机上常见问题（4.9 专属）

| 症状 | 原因 / 处理 |
|---|---|
| **网络起不来 + CPU 100%、死锁**（Debian 11/12） | systemd ≥247 与 4.9 的 cgroup v2 不兼容；**开「强制 Cgroup V1」也没解决**（实测）。直接换 **Debian 10** |
| 启动就卡住、`systemd` 反复超时 | 同上，优先怀疑 cgroup 模式 |
| 连 `ping` 都 `socket: permission denied` | 内核 paranoid networking；本包已加 aid_inet 组，若你自定义了用户：`usermod -a -G aid_inet,aid_net_raw <user>` |
| IP 通、域名不通 | 运营商封公共 DNS：App 里改容器 **DNS Servers** 为运营商下发的 DNS；或 `droidspaces ... --dns=<ip>` |
| gateway / macvlan 模式下域名不通 | Debian 11 镜像靠内置租约发布器；若仍不行直接指定 `--dns=<网关IP>`；Debian 12 有 systemd-resolved，正常 |
| 容器一起来手机断网 | 用了 **host** 网络模式且容器内有 NetworkManager/systemd-networkd。改 NAT；本包已加模式守卫，但 host 模式下仍建议别装 NetworkManager |
| Stop 卡 15 秒以上 | 4.14 的 `grab_super()` 内核 bug（4.9 上偶发 umount 卡住），内核侧问题；尽量用稀疏镜像并减少容器内挂载 |
| 磁盘越用越满 | 镜像删文件不自动缩：容器内 `fstrim -av` |
| `apt update` 很慢/费流量 | 移动数据下别频繁 update；本包已默认禁用 apt 每日定时器 |

---

## 6. 构建 / 校验

### 方式 A：GitHub Actions（推荐，快得多）

仓库里带了 `.github/workflows/build-rootfs.yml`：push 到 `main`（改到 `templates/`、
`scripts/`、`build.sh`、workflow 时）或手动 **Run workflow** 就会触发。三个 Debian
版本并行跑在 **GitHub 原生 arm64 runner（`ubuntu-24.04-arm`）** 上 —— 没有 QEMU
模拟、网络也是满速，单个包 2 分钟左右（本机 x86 + QEMU 要 10–20 分钟）。

流程：矩阵构建 → 上传 artifact → 汇总发一个 release（`v<日期>-<run号>`）→
用 `scripts/make-rootfs-json.py` 重新生成 `rootfs.json` 并提交回 main。

```sh
gh workflow run build-rootfs.yml            # 手动触发
gh run watch                                # 看进度
gh release list                             # 看产物
```

> fork 到自己账号后：Settings → Actions → General → Workflow permissions 选
> **Read and write permissions**（workflow 里已经声明 `contents: write`，
> 但 fork 出来的仓库默认可能是只读）。

### 方式 B：本机构建（x86 交叉 / arm64 原生都行）

```sh
./build.sh --list                                          # 看有哪些模板
./build.sh                                                 # 全部（aarch64）
./build.sh -i Debian-11-bullseye-Minimal-Kernel-4.9        # 只构建一个
./build.sh --no-load -i Debian-10-buster-Minimal-Kernel-4.9
./build.sh -a armhf                                        # 32 位设备（需自己加 templates/armhf/）
DS_BASE_IMAGE=docker.m.daocloud.io/library/debian:bookworm ./build.sh   # 换基础镜像/镜像站
```

脚本会：需要时注册 qemu binfmt（x86 宿主跑 arm64）→ 建 buildx builder →
`--target export --output type=tar` 导出纯 rootfs → `xz -9` 压缩 → 生成 `.sha256` →
（默认）`--load` 一个同名 docker 镜像供 `verify.sh` 直接运行。

### 校验

```sh
./verify.sh out/Debian-11-bullseye-Minimal-Kernel-4.9-*.tar.xz             # 静态检查
./verify.sh out/...tar.xz --legacy-syscalls                                 # +「4.9 系统调用面」冒烟测试
./verify.sh out/...tar.xz --legacy-syscalls --boot                          # + 尝试把 systemd 启到 multi-user
```

`--legacy-syscalls` 用 `scripts/seccomp-4.9.json` 把 `clone3 / openat2 / faccessat2 /
pidfd_* / io_uring_* / close_range …` 这些 **4.9 不存在的系统调用**强制返回 `ENOSYS`，
再跑 `bash / dpkg / git / ssh / systemctl --version / ds-legacy-check`，验证 glibc 与
基础用户态的回退路径确实存在。（宿主是 6.12 内核，这是仿真，不是真 4.9；
`statx`/`fsmount` 那几个没法屏蔽，因为容器运行时 runc 自己要用。）

### 生成订阅源

```sh
python3 scripts/make-rootfs-json.py --dir dist \
  --base-url https://github.com/<owner>/<repo>/releases/download/<tag> -o rootfs.json
```

App 只接受 `https://` 的订阅地址；只想装一个包就直接「从文件安装」。

---

## 7. 构建与验证结果

### 7.1 CI 产物（GitHub Actions，release `v20261012-1`）

三个包全部在 **原生 arm64 runner** 上构建成功，整条流水线（3 个并行构建 + 发 release +
提交 `rootfs.json`）约 **2 分钟**，比本机 x86 + QEMU 快一个数量级。

| 包 | systemd | glibc | tar.xz | sha256 |
|---|---|---|---|---|
| Debian 10 (Buster) - Minimal | 241 | 2.28 | 83,163,056 B (80 MB) | `637a2aa9ba28d82f…` |
| Debian 11 (Bullseye) - Minimal | 247 | 2.31 | 88,996,032 B (85 MB) | `365a09a76098ed3e…` |
| Debian 12 (Bookworm) - Minimal | 252 | 2.36 | 94,399,492 B (90 MB) | `0d3b4d12e6833b3c…` |

完整 sha256、下载地址见 `rootfs.json`（也是 App 的订阅源）：

```
https://raw.githubusercontent.com/Yang-XianChen/droidspaces-debian-legacy/main/rootfs.json
```

### 7.2 逐项校验（`verify.sh`）

| 检查项 | 结果 |
|---|---|
| xz 流完整性 + sha256 | ✅ 三个包全部匹配 |
| App 安装校验（顶层 `bin/ sbin/ etc/ usr/`） | ✅ 三个包全部通过 |
| `/etc/droidspaces` 标记、aid_inet(3003)/aid_net_raw(3004)、`_apt`、iptables→legacy、journald-audit 屏蔽、netmode drop-in、`ds-legacy-check` | ✅ 全部存在 |
| Debian 10 → `ExecStartPre` 回落（systemd 241 没有 `ExecCondition`） | ✅ 生成的 drop-in 已自动切换写法 |
| Debian 11/12 → `ExecCondition` | ✅ |
| `verify.sh` 静态检查 | ✅ PASS=25 FAIL=0（三个包都是） |

### 7.3 「4.9 系统调用面」冒烟测试

用 `scripts/seccomp-4.9.json` 把 `clone3 / openat2 / faccessat2 / pidfd_* / io_uring_* /
close_range / rseq …` 全部强制 `ENOSYS` 后，在 Debian 12 包里跑：

```
uname   : aarch64
debian  : 12.15
systemd : systemd 252 (252.39-1~deb12u2)
glibc   : ldd (Debian GLIBC 2.36-9+deb12u14) 2.36
root groups: root tty video input aid_inet aid_net_raw
aid_inet : aid_inet:x:3003:root
iptables : /usr/sbin/xtables-legacy-multi
dpkg audit:            (无输出 = 无损坏包)
bash    : GNU bash, version 5.2.15(1)-release
git     : git version 2.39.5
ssh     : OpenSSH_9.2p1 Debian-2+deb12u10
perl    : ok
ds-legacy-check: ran (exit 0)
```

即 glibc / dpkg / apt / bash / git / ssh / perl / systemd 的用户态部分在「没有
4.9 之后那些系统调用」的环境里都能正常回退。**注意这是仿真**：`statx`、`fsmount`、
`fsconfig`、`move_mount`、`open_tree` 没法屏蔽（容器运行时 runc 自己要用它们），
真机验证还是得在手机上启动容器。

### 7.4 手机上要做的两件事

1. 配置里打开 **强制 Cgroup V1**（4.9 的 cgroup v2 控制器不全，systemd 会误判环境）。
2. 存储保持 **使用稀疏镜像**（f2fs + SELinux 下目录型 rootfs 会坏）。

进去以后跑 `ds-legacy-check` 复核，详见第 2、5 节。

---

## 8. 参考

- Droidspaces 源码与文档：<https://github.com/ravindu644/Droidspaces-OSS>
- 官方 rootfs 构建仓库（本项目的模板格式来自它）：<https://github.com/Droidspaces/Droidspaces-rootfs-builder>
- 本机调研笔记：`Droidspaces-安卓运行调研.md`
- 内核要求：`Documentation/Kernel-Configuration.md`；老内核问题：`Documentation/Troubleshooting.md`
