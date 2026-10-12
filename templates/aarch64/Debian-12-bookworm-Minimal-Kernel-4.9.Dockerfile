# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# Debian 12 (Bookworm) -- Minimal, built for Droidspaces on LEGACY Android
# kernels (3.10 - 4.19, including 4.9).
#
# This is the "still gets security updates" sibling of the Bullseye image:
# systemd 252 is far below the 258 release that dropped support for kernels
# older than 5.4, so it boots on a 4.9 kernel, while Bookworm itself is
# maintained by the Debian LTS team.
#
# Everything Android/legacy specific is in scripts/legacy-fixes.sh.
#
# Build (cross-arch on an x86_64 host, qemu binfmt must be registered):
#   docker buildx build --platform linux/arm64 --target export \
#     --output type=tar,dest=rootfs.tar -f <this file> .
# or simply: ./build.sh
# ---------------------------------------------------------------------------
ARG DS_BASE=debian:bookworm
FROM ${DS_BASE} AS customizer

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# contrib/non-free for hfsprogs and friends, exactly like the official images
RUN (sed -i 's/main/main contrib non-free/g' /etc/apt/sources.list 2>/dev/null || \
     sed -i 's/Components: main/Components: main contrib non-free/g' /etc/apt/sources.list.d/debian.sources) && \
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
      udev dbus systemd-sysv systemd-resolved \
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
LABEL droidspaces.name="Debian 12 (Bookworm) - Minimal - Kernel 3.10-4.19" \
      droidspaces.distro="Debian" \
      droidspaces.description="Debian 12 rootfs for Droidspaces on legacy Android kernels (3.10-4.19, incl. 4.9). systemd 252, cgroup v1 friendly, Android paranoid-network groups and iptables-legacy preconfigured. Run with Force Cgroup V1 enabled." \
      droidspaces.author="built locally from Droidspaces-rootfs-builder" \
      droidspaces.kernel_compat="3.10-4.19"
COPY --from=customizer / /
