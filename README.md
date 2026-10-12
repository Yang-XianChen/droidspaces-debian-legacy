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

---

## 1. 目录内容

```
droidspaces-debian-legacy/
├── build.sh                      # 构建：docker buildx + qemu 跨架构，产出 out/*.tar.xz
├── verify.sh                     # 校验：归档 / 内容 / 运行时 / 4.9 系统调用面 / 启动
├── README.md                     # 本文件
├── rootfs.json                   # 可选：给 App「管理软件源」用的订阅文件（自己填 URL）
├── templates/aarch64/
│   ├── Debian-12-bookworm-Minimal-Kernel-4.9.Dockerfile   # 推荐
│   └── Debian-11-bullseye-Minimal-Kernel-4.9.Dockerfile   # 最保守（已 EOL）
├── scripts/
│   ├── legacy-fixes.sh           # ★ 兼容层：所有 Android/老内核修补都在这里
│   ├── ds-legacy-check.sh        # ★ 装进镜像，手机里跑 `ds-legacy-check` 出体检报告
│   ├── seccomp-4.9.json          # 用 seccomp 屏蔽 4.9 之后的系统调用，用于本地验证
│   ├── make-rootfs-json.py       # 由 out/*.tar.xz 生成 rootfs.json 订阅源
│   ├── bashrc.sh                 # 来自官方 builder 的别名脚本
│   └── download-firmware         # 来自官方 builder 的固件下载器
└── out/                          # 构建产物 + sha256
```

---

## 2. 手机安装（App，推荐）

1. **把 `.tar.xz` 拷到手机**（USB/MTP、`adb push`、网盘都行），放 `Download/` 目录。
   ```sh
   adb push out/Debian-12-bookworm-Minimal-Kernel-4.9-*.tar.xz /sdcard/Download/
   ```
2. 打开 **Droidspaces App → Containers → ＋ → Install from file**，选中这个 `.tar.xz`。
   （App 内置校验脚本会检查归档里有 `bin/ sbin/ etc/ usr/`，本包满足。）
3. 向导四步：

   | 步骤 | 怎么选 | 为什么 |
   |---|---|---|
   | 名称 / hostname | 随意，例如 `debian` | — |
   | **配置** | **打开「强制 Cgroup V1」**；网络选 **NAT** | 4.9 的 cgroup v2 缺 systemd 需要的控制器，不强制 v1 时 systemd 可能误判环境、卡在启动 |
   | 存储 | **保持「使用稀疏镜像」开启** | `/data` 是 f2fs + SELinux，目录型 rootfs 会随机损坏；镜像内 ext4 才是 OverlayFS 接受的 lowerdir |
   | 摘要 | 确认 → 安装 | 解压约 1–3 分钟 |

4. 回列表点 **Start**，看日志跑到 `RUNNING`；进 **Terminal** 就是 root shell。
5. 第一次进去先跑一次体检：

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

| | **Debian 12 bookworm**（推荐） | Debian 11 bullseye |
|---|---|---|
| systemd | 252 | 247 |
| glibc | 2.36 | 2.31 |
| 内核支持 | 3.10 – 4.19 实测路线，官方也把 Debian 12/13 列为老内核方案 | 同左，回退路径更多 |
| 软件源 | `deb.debian.org` + `security` 正常 | **已 EOL（2026-08-31）**，只能走 `archive.debian.org`，**永久冻结、无安全更新** |
| 什么时候选 | 默认选它，手机是要联网用的 | 内核特别老（3.10–4.4）、或需要 systemd 247 / glibc 2.31 的特定软件 |

> Bullseye 的 EOL 是客观事实：`deb.debian.org/debian-security` 上 bullseye 的
> `Packages` 索引还在，但 **`.deb` 全部 404**（构建时实测），所以镜像必须指到
> `archive.debian.org`。装到手机上以后也不会再有任何安全更新 —— 想长期用就选 bookworm。

---

## 5. 手机上常见问题（4.9 专属）

| 症状 | 原因 / 处理 |
|---|---|
| 启动就卡住、`systemd` 反复超时 | **没开「强制 Cgroup V1」**。App：容器配置 → 打开；CLI：`droidspaces ... --force-cgroupv1` |
| 连 `ping` 都 `socket: permission denied` | 内核 paranoid networking；本包已加 aid_inet 组，若你自定义了用户：`usermod -a -G aid_inet,aid_net_raw <user>` |
| IP 通、域名不通 | 运营商封公共 DNS：App 里改容器 **DNS Servers** 为运营商下发的 DNS；或 `droidspaces ... --dns=<ip>` |
| gateway / macvlan 模式下域名不通 | Debian 11 镜像靠内置租约发布器；若仍不行直接指定 `--dns=<网关IP>`；Debian 12 有 systemd-resolved，正常 |
| 容器一起来手机断网 | 用了 **host** 网络模式且容器内有 NetworkManager/systemd-networkd。改 NAT；本包已加模式守卫，但 host 模式下仍建议别装 NetworkManager |
| Stop 卡 15 秒以上 | 4.14 的 `grab_super()` 内核 bug（4.9 上偶发 umount 卡住），内核侧问题；尽量用稀疏镜像并减少容器内挂载 |
| 磁盘越用越满 | 镜像删文件不自动缩：容器内 `fstrim -av` |
| `apt update` 很慢/费流量 | 移动数据下别频繁 update；本包已默认禁用 apt 每日定时器 |

---

## 6. 重新构建 / 校验

### 构建

```sh
cd droidspaces-debian-legacy
./build.sh --list                                          # 看有哪些模板
./build.sh                                                 # 全部（aarch64）
./build.sh -i Debian-12-bookworm-Minimal-Kernel-4.9        # 只构建一个
./build.sh -a armhf                                        # 32 位设备（需自己加 templates/armhf/）
DS_BASE_IMAGE=docker.m.daocloud.io/library/debian:bookworm ./build.sh   # 换基础镜像/镜像站
```

脚本会：自动注册 qemu binfmt（宿主跑不动 arm64 时）→ 建 buildx builder →
`--target export --output type=tar` 导出纯 rootfs → `xz -9` 压缩 → 生成 `.sha256` →
顺带 `--load` 一个同名 docker 镜像供 `verify.sh` 直接运行。

### 校验

```sh
./verify.sh out/Debian-12-bookworm-Minimal-Kernel-4.9-*.tar.xz              # 静态检查
./verify.sh out/...tar.xz --legacy-syscalls                                  # 再跑一遍「4.9 系统调用面」冒烟测试
./verify.sh out/...tar.xz --legacy-syscalls --boot                           # 再尝试把 systemd 启到 multi-user
```

`--legacy-syscalls` 会用 `scripts/seccomp-4.9.json` 把 `clone3 / openat2 / statx /
faccessat2 / pidfd_* / io_uring_* …` 这些 **4.9 不存在的系统调用**强制返回 `ENOSYS`，
再跑 `bash / dpkg / git / ssh / systemctl --version` 等，用近似「4.9 系统调用面」验证 glibc 与
基础用户态的回退路径确实存在。（宿主是 6.12 内核，这是仿真，不是真 4.9。）

### 发布成订阅源（可选）

App 还支持订阅 `rootfs.json`（Containers → Manage Repositories）：

```sh
./scripts/make-rootfs-json.py --base-url https://你的地址/ds -o rootfs.json
# 把 out/*.tar.xz 和 rootfs.json 上传到该地址，App 里填 https://你的地址/ds/rootfs.json
```

注意 App 只接受 `https://` 的订阅地址；只想装一个包的话，直接用「从文件安装」更省事。

---

## 7. 构建与验证结果

<!--RESULTS-->

---

## 8. 参考

- Droidspaces 源码与文档：<https://github.com/ravindu644/Droidspaces-OSS>
- 官方 rootfs 构建仓库（本项目的模板格式来自它）：<https://github.com/Droidspaces/Droidspaces-rootfs-builder>
- 本机调研笔记：`Droidspaces-安卓运行调研.md`
- 内核要求：`Documentation/Kernel-Configuration.md`；老内核问题：`Documentation/Troubleshooting.md`
