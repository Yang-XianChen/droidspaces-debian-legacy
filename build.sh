#!/bin/bash
# ---------------------------------------------------------------------------
# Build Droidspaces rootfs packages for legacy (3.10 - 4.19, incl. 4.9) kernels.
#
#   ./build.sh                        # every template for aarch64
#   ./build.sh -i Debian-11-bullseye-Minimal-Kernel-4.9
#   ./build.sh -a armhf               # 32-bit devices (needs templates/armhf/)
#   ./build.sh --list
#
# Cross architecture builds need qemu binfmt on the host; the script installs
# it (tonistiigi/binfmt) when the host cannot run the target platform natively.
#
# Output: out/<Name>-Droidspaces-rootfs-<arch>-<date>-<version>.tar.xz (+ .sha256)
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

ARCH="aarch64"
NAME=""
VERSION="${DS_VERSION:-v$(date +%Y%m%d)-legacy}"
BUILDER="${DS_BUILDER:-droidspaces-legacy}"
OUTDIR="$PWD/out"
LOAD_IMAGE="${DS_LOAD_IMAGE:-1}"
BASE_OVERRIDE="${DS_BASE_IMAGE:-}"

usage() {
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -a) ARCH="$2"; shift 2 ;;
        -i) NAME="${2%.Dockerfile}"; shift 2 ;;
        -v) VERSION="$2"; shift 2 ;;
        --no-load) LOAD_IMAGE=0; shift ;;
        --base) BASE_OVERRIDE="$2"; shift 2 ;;
        --list) ls templates/*/*.Dockerfile 2>/dev/null | sed 's|templates/||; s|\.Dockerfile$||'; exit 0 ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

case "$ARCH" in
    aarch64) PLATFORM="linux/arm64" ;;
    armhf)   PLATFORM="linux/arm/v7" ;;
    x86_64)  PLATFORM="linux/amd64" ;;
    x86)     PLATFORM="linux/386" ;;
    *) echo "Unknown arch: $ARCH" >&2; exit 1 ;;
esac

# Buildx keeps its state under $DOCKER_CONFIG; fall back to a project-local
# directory when the user's ~/.docker is not writable.
if ! { mkdir -p "${DOCKER_CONFIG:-$HOME/.docker}" && \
       touch "${DOCKER_CONFIG:-$HOME/.docker}/.write-test" && \
       rm -f "${DOCKER_CONFIG:-$HOME/.docker}/.write-test"; } 2>/dev/null; then
    export DOCKER_CONFIG="$PWD/.docker"
    mkdir -p "$DOCKER_CONFIG"
fi

# Collect the templates to build
TEMPLATES=()
if [ -n "$NAME" ]; then
    FILE="templates/$ARCH/$NAME.Dockerfile"
    [ -f "$FILE" ] || { echo "Error: $FILE not found" >&2; exit 1; }
    TEMPLATES+=("$FILE")
else
    while IFS= read -r f; do TEMPLATES+=("$f"); done < <(ls templates/"$ARCH"/*.Dockerfile 2>/dev/null || true)
    [ "${#TEMPLATES[@]}" -gt 0 ] || { echo "No templates under templates/$ARCH/" >&2; exit 1; }
fi

# qemu binfmt, only when needed
if ! docker run --rm --platform "$PLATFORM" "${BASE_OVERRIDE:-debian:bookworm}" true >/dev/null 2>&1; then
    echo ">> Host cannot run $PLATFORM natively; installing binfmt/qemu..."
    docker run --privileged --rm tonistiigi/binfmt --install all
fi

if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
    echo ">> Creating buildx builder '$BUILDER'"
    docker buildx create --name "$BUILDER" --driver docker-container --bootstrap >/dev/null
fi
docker buildx use "$BUILDER" >/dev/null 2>&1 || true

mkdir -p "$OUTDIR"
FAILED=()

for DOCKERFILE in "${TEMPLATES[@]}"; do
    T_NAME="$(basename "$DOCKERFILE" .Dockerfile)"
    echo
    echo "=================================================================="
    echo " Template : $DOCKERFILE"
    echo " Platform : $PLATFORM"
    echo " Version  : $VERSION"
    echo "=================================================================="

    TMP_TAR="$OUTDIR/.tmp-$ARCH-$T_NAME.tar"
    FINAL="$OUTDIR/${T_NAME}-Droidspaces-rootfs-${ARCH}-$(date +%Y%m%d)-${VERSION}.tar.xz"

    BUILD_ARGS=()
    [ -n "$BASE_OVERRIDE" ] && BUILD_ARGS+=(--build-arg "DS_BASE=$BASE_OVERRIDE")

    rm -f "$TMP_TAR"
    if ! docker buildx build \
            --builder "$BUILDER" \
            --platform "$PLATFORM" \
            --target export \
            --output "type=tar,dest=$TMP_TAR" \
            "${BUILD_ARGS[@]}" \
            -f "$DOCKERFILE" . ; then
        echo "!! build failed: $T_NAME" >&2
        FAILED+=("$T_NAME")
        continue
    fi

    echo ">> Compressing with xz -T0 -9"
    xz -T0 -9 -f "$TMP_TAR"
    mv "${TMP_TAR}.xz" "$FINAL"

    ( cd "$OUTDIR" && sha256sum "$(basename "$FINAL")" > "$(basename "$FINAL").sha256" )

    echo ">> $FINAL"
    ls -lh "$FINAL"

    if [ "$LOAD_IMAGE" = "1" ]; then
        # Same build, cached: also load it as an image so verify.sh can run the
        # rootfs directly instead of chrooting into an extracted tree.
        # Docker tag components must be lowercase.
        TAG="droidspaces-legacy/$(printf '%s' "$T_NAME" | tr '[:upper:]' '[:lower:]'):$VERSION"
        if docker buildx build \
                --builder "$BUILDER" \
                --platform "$PLATFORM" \
                --target export \
                --load \
                -t "$TAG" \
                "${BUILD_ARGS[@]}" \
                -f "$DOCKERFILE" . >/dev/null; then
            echo ">> loaded image $TAG"
        else
            echo ">> warning: --load failed; verify.sh --runtime will be skipped" >&2
        fi
    fi
done

echo
if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "FAILED: ${FAILED[*]}" >&2
    exit 1
fi
echo "All builds finished. Artifacts in $OUTDIR:"
ls -lh "$OUTDIR"/*.tar.xz
