# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# Debian 10 (Buster) -- Minimal, built for Droidspaces on LEGACY Android
# kernels (3.10 - 4.19, including 4.9).
#
# Base image is the official, already-trimmed Debian 10 docker image (~50 MB);
# this build only adds what a container needs to boot and reach the network
# (systemd-sysv init + udev + dbus) plus the Android compatibility layer in
# scripts/legacy-fixes.sh. Nothing from an installer ISO is used.
#
# Why Buster for a 4.9 kernel:
#   * systemd 241 / glibc 2.28 -- far below the systemd 258 release that dropped
#     the fallbacks for clone3/openat2 and therefore refuses to run on <5.4.
#   * cgroup v1 is the normal mode for this systemd.
#   * iptables 1.8 legacy backend / pre-nft tooling.
#
# IMPORTANT: Buster left LTS on 2024-06-30 and now lives on archive.debian.org,
# so this image is FROZEN (no further security updates). Prefer the Bullseye or
# Bookworm image unless you specifically need systemd 241.
# ---------------------------------------------------------------------------
ARG DS_BASE=debian:buster
FROM ${DS_BASE} AS customizer

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Debian 10 is archived: point apt at archive.debian.org (contrib/non-free
# included) and accept the expired Release files.
RUN printf '%s\n' \
      'deb http://archive.debian.org/debian buster main contrib non-free' \
      'deb http://archive.debian.org/debian-security buster/updates main contrib non-free' \
      'deb http://archive.debian.org/debian buster-updates main contrib non-free' \
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
LABEL droidspaces.name="Debian 10 (Buster) - Minimal - Kernel 3.10-4.19" \
      droidspaces.distro="Debian" \
      droidspaces.description="Debian 10 rootfs for Droidspaces on legacy Android kernels (3.10-4.19, incl. 4.9). systemd 241, cgroup v1 native, Android paranoid-network groups and iptables-legacy preconfigured. Run with Force Cgroup V1 enabled. Frozen archive build (no security updates)." \
      droidspaces.author="built locally from Droidspaces-rootfs-builder" \
      droidspaces.kernel_compat="3.10-4.19"
COPY --from=customizer / /
