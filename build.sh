#!/usr/bin/env bash
# ==============================================================================
# linux-maker: Automated script to build a minimal, bootable Linux system
# ==============================================================================

set -euo pipefail

# Configuration defaults
DISTRO_NAME="${DISTRO_NAME:-linux-maker}"
WORK_DIR="${WORK_DIR:-$(pwd)/work}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/out}"
KERNEL_VERSION="${KERNEL_VERSION:-6.6.21}"
BUSYBOX_VERSION="${BUSYBOX_VERSION:-1.36.1}"
ARCH="$(uname -m)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[linux-maker]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[linux-maker]${NC} $*"
}

log_error() {
    echo -e "${RED}[linux-maker: ERROR]${NC} $*" >&2
}

check_dependencies() {
    log "Checking host dependencies..."
    local deps=(make gcc bc bison flex qemu-system-x86_64 curl tar cpio xorriso)
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        log "Install them with your package manager (e.g. sudo apt install build-essential bc bison flex libelf-dev libssl-dev qemu-system-x86 xorriso isolinux)"
        exit 1
    fi
    log_success "All build dependencies detected."
}

setup_workspace() {
    log "Initializing workspace..."
    mkdir -p "$WORK_DIR/src" "$WORK_DIR/rootfs" "$OUTPUT_DIR"
}

fetch_sources() {
    log "Downloading source tarballs..."
    cd "$WORK_DIR/src"

    # Linux Kernel
    if [ ! -f "linux-${KERNEL_VERSION}.tar.xz" ]; then
        log "Fetching Linux Kernel ${KERNEL_VERSION}..."
        curl -LO "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz"
    fi

    # BusyBox
    if [ ! -f "busybox-${BUSYBOX_VERSION}.tar.bz2" ]; then
        log "Fetching BusyBox ${BUSYBOX_VERSION}..."
        curl -LO "https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2"
    fi
}

build_busybox() {
    log "Building BusyBox..."
    cd "$WORK_DIR/src"
    if [ ! -d "busybox-${BUSYBOX_VERSION}" ]; then
        tar -xjf "busybox-${BUSYBOX_VERSION}.tar.bz2"
    fi

    cd "busybox-${BUSYBOX_VERSION}"
    make defconfig
    # Enable static compilation
    sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
    make -j"$(nproc)"
    make CONFIG_PREFIX="$WORK_DIR/rootfs" install
    log_success "BusyBox built and installed to rootfs."
}

setup_rootfs() {
    log "Configuring root filesystem..."
    local rootfs="$WORK_DIR/rootfs"

    cd "$rootfs"
    mkdir -p dev proc sys etc root mnt tmp etc/init.d

    # Create /init script
    cat << 'EOF' > "$rootfs/init"
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

echo ""
echo "=========================================="
echo " Welcome to Linux-Maker Minimal Distro!  "
echo "=========================================="
echo ""

exec /bin/sh
EOF

    chmod +x "$rootfs/init"
    log_success "Rootfs initialized with custom /init."
}

pack_initramfs() {
    log "Packing initramfs..."
    cd "$WORK_DIR/rootfs"
    find . -print0 | cpio --null -ov --format=newc | gzip -9 > "$OUTPUT_DIR/initramfs.cpio.gz"
    log_success "Generated $OUTPUT_DIR/initramfs.cpio.gz"
}

build_kernel() {
    log "Building Linux Kernel..."
    cd "$WORK_DIR/src"
    if [ ! -d "linux-${KERNEL_VERSION}" ]; then
        tar -xf "linux-${KERNEL_VERSION}.tar.xz"
    fi

    cd "linux-${KERNEL_VERSION}"
    make defconfig
    # Compile bzImage
    make -j"$(nproc)" bzImage
    cp arch/x86/boot/bzImage "$OUTPUT_DIR/bzImage"
    log_success "Generated $OUTPUT_DIR/bzImage"
}

run_qemu() {
    log "Launching custom Linux system in QEMU..."
    if [ ! -f "$OUTPUT_DIR/bzImage" ] || [ ! -f "$OUTPUT_DIR/initramfs.cpio.gz" ]; then
        log_error "Build artifacts missing. Run './build.sh all' first."
        exit 1
    fi

    qemu-system-x86_64 \
        -kernel "$OUTPUT_DIR/bzImage" \
        -initrd "$OUTPUT_DIR/initramfs.cpio.gz" \
        -append "console=ttyS0 quiet" \
        -nographic
}

clean() {
    log "Cleaning build outputs..."
    rm -rf "$WORK_DIR" "$OUTPUT_DIR"
    log_success "Clean complete."
}

usage() {
    cat << EOF
Usage: $0 [command]

Commands:
  all         Build both BusyBox initramfs and Linux kernel
  rootfs      Build BusyBox and assemble rootfs + initramfs
  kernel      Compile the Linux kernel (bzImage)
  run         Launch the built Linux image in QEMU (nographic)
  clean       Remove work and out directories
  help        Show this help message

Environment Variables:
  KERNEL_VERSION   Linux kernel version (default: $KERNEL_VERSION)
  BUSYBOX_VERSION  BusyBox version (default: $BUSYBOX_VERSION)
  OUTPUT_DIR       Target directory for artifacts (default: ./out)
EOF
}

case "${1:-all}" in
    all)
        check_dependencies
        setup_workspace
        fetch_sources
        build_busybox
        setup_rootfs
        pack_initramfs
        build_kernel
        log_success "Build complete! Files located in $OUTPUT_DIR"
        ;;
    rootfs)
        check_dependencies
        setup_workspace
        fetch_sources
        build_busybox
        setup_rootfs
        pack_initramfs
        ;;
    kernel)
        check_dependencies
        setup_workspace
        fetch_sources
        build_kernel
        ;;
    run)
        run_qemu
        ;;
    clean)
        clean
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        log_error "Unknown command: $1"
        usage
        exit 1
        ;;
esac
