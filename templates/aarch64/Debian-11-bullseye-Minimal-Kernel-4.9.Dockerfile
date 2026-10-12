# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# Debian 11 (Bullseye) -- Minimal, built for Droidspaces on LEGACY Android
# kernels (3.10 - 4.19, including 4.9).
#
# Why Bullseye for a 4.9 kernel:
#   * systemd 247 / glibc 2.31 predate every kernel dependency that breaks
#     modern distros on <5.4: systemd 258+ dropped its fallbacks for clone3 /
#     openat2 and simply refuses to run.
#   * systemd 247 treats cgroup v1 as a first-class mode, which is what 4.9
#     Android kernels actually provide.
#   * iptables 1.8 legacy backend, which is all an x_tables-only Android
#     kernel can drive.
#
# Everything Android/legacy specific is in scripts/legacy-fixes.sh.
#
# Note: Debian 11 has no systemd-resolved package. For gateway/macvlan network
# modes the build installs a small DHCP-lease DNS publisher instead; NAT mode
# (the default) is unaffected because Droidspaces writes resolv.conf itself.
#
# IMPORTANT: Bullseye left Debian LTS on 2026-08-31. Its packages are no longer
# on deb.debian.org/debian-security (the pool 404s, only a stale index is
# served), so this image builds from archive.debian.org and is FROZEN: it will
# never receive another security update. Use the Bookworm image unless you
# specifically need systemd 247 / glibc 2.31 (e.g. a 3.10-4.4 kernel).
#
# Build (cross-arch on an x86_64 host, qemu binfmt must be registered):
#   docker buildx build --platform linux/arm64 --target export \
#     --output type=tar,dest=rootfs.tar -f <this file> .
# or simply: ./build.sh
# ---------------------------------------------------------------------------
ARG DS_BASE=debian:bullseye
FROM ${DS_BASE} AS customizer

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Bullseye is archived: point apt at archive.debian.org (contrib/non-free
# included, like the official images) and stop apt from rejecting the expired
# Release files.
RUN printf '%s\n' \
      'deb http://archive.debian.org/debian bullseye main contrib non-free' \
      'deb http://archive.debian.org/debian-security bullseye-security main contrib non-free' \
      'deb http://archive.debian.org/debian bullseye-updates main contrib non-free' \
      > /etc/apt/sources.list && \
    printf 'Acquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99archive && \
    apt-get update && \
    apt-get upgrade -y

COPY scripts/bashrc.sh            /etc/profile.d/ds-aliases.sh
COPY scripts/download-firmware    /usr/local/bin/download-firmware
COPY scripts/ds-legacy-check.sh   /usr/local/bin/ds-legacy-check
COPY scripts/legacy-fixes.sh      /tmp/legacy-fixes.sh
RUN chmod 0755 /etc/profile.d/ds-aliases.sh /usr/local/bin/download-firmware \
               /usr/local/bin/ds-legacy-check /tmp/legacy-fixes.sh

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      bash coreutils file findutils grep sed gawk \
      curl wget ca-certificates locales bash-completion \
      udev dbus systemd-sysv \
      git nano vim tmux rsync sudo openssh-server \
      net-tools iptables iputils-ping iproute2 dnsutils \
      procps kmod psmisc lsof htop less \
      dialog apt-utils tar gzip bzip2 xz-utils unzip zip \
      tzdata logrotate && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen && \
    locale-gen && \
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 && \
    mkdir -p /run/sshd && \
    sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config && \
    sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Android + legacy-kernel compatibility (also writes the /etc/droidspaces marker
# that makes the app skip its own post-extract pass)
RUN /tmp/legacy-fixes.sh && rm -f /tmp/legacy-fixes.sh

RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ---------------------------------------------------------------------------
# Export stage: a plain rootfs tree, no layers, no container runtime files
# ---------------------------------------------------------------------------
FROM scratch AS export
LABEL droidspaces.name="Debian 11 (Bullseye) - Minimal - Kernel 3.10-4.19" \
      droidspaces.distro="Debian" \
      droidspaces.description="Debian 11 rootfs for Droidspaces on legacy Android kernels (3.10-4.19, incl. 4.9). systemd 247, cgroup v1 friendly, Android paranoid-network groups and iptables-legacy preconfigured. Run with Force Cgroup V1 enabled." \
      droidspaces.author="built locally from Droidspaces-rootfs-builder" \
      droidspaces.kernel_compat="3.10-4.19"
COPY --from=customizer / /
