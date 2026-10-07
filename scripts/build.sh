#!/usr/bin/env bash
set -euo pipefail

DISTRO="${INPUT_DISTRO:-ubuntu}"
SERIES="${INPUT_SERIES:-noble}"
REQUESTED_ARCH="${INPUT_ARCH:-amd64}"
OUTPUT_FORMAT="${INPUT_OUTPUT_FORMAT:-rootfs-tarball}"
FLAVOR="${INPUT_FLAVOR:-none}"
KERNEL_FLAVOUR="${INPUT_KERNEL_FLAVOUR:-generic}"
CUSTOM_PACKAGES="${INPUT_CUSTOM_PACKAGES:-}"
CUSTOM_SCRIPT="${INPUT_CUSTOM_SCRIPT:-}"
VERSION="${INPUT_VERSION:-}"
OUTPUT_DIR="${INPUT_OUTPUT_DIR:-dist}"

# Determine Version string
if [ -z "$VERSION" ]; then
  if [[ "${GITHUB_REF:-}" =~ ^refs/tags/v?(.*)$ ]]; then
    VERSION="${BASH_REMATCH[1]}"
  else
    VERSION="$(date +%Y.%m.%d-%H%M%S)"
  fi
fi

mkdir -p "${OUTPUT_DIR}"

echo "=========================================="
echo " Starting Linux Maker"
echo " Distro:        ${DISTRO}"
echo " Series:        ${SERIES}"
echo " Architecture:  ${REQUESTED_ARCH}"
echo " Format:        ${OUTPUT_FORMAT}"
echo " Flavor:        ${FLAVOR}"
echo " Kernel:        ${KERNEL_FLAVOUR}"
echo " Version:       ${VERSION}"
echo " Output Dir:    ${OUTPUT_DIR}"
echo "=========================================="

IS_LEGACY="false"
MIRROR=""
ARCH="${REQUESTED_ARCH}"

# Mirror and architecture resolution
if [ "${DISTRO}" = "ubuntu" ]; then
  if curl -sf "http://archive.ubuntu.com/ubuntu/dists/${SERIES}/Release" -o /dev/null; then
    MIRROR="http://archive.ubuntu.com/ubuntu/"
    IS_LEGACY="false"
    echo "Using modern Ubuntu mirror: ${MIRROR}"
  else
    MIRROR="http://old-releases.ubuntu.com/ubuntu/"
    IS_LEGACY="true"
    echo "Ubuntu ${SERIES} is legacy/EOL. Using mirror: ${MIRROR}"
    if [ "${REQUESTED_ARCH}" = "amd64" ]; then
      # Ubuntu introduced amd64 with Breezy 5.10. Older releases only supported i386.
      if [[ "${SERIES}" =~ ^(warty|hoary)$ ]]; then
        echo "Release ${SERIES} predates amd64 (introduced in 5.10). Switching architecture to i386."
        ARCH="i386"
      fi
    fi
  fi
elif [ "${DISTRO}" = "debian" ]; then
  if curl -sf "http://deb.debian.org/debian/dists/${SERIES}/Release" -o /dev/null; then
    MIRROR="http://deb.debian.org/debian/"
    IS_LEGACY="false"
    echo "Using modern Debian mirror: ${MIRROR}"
  else
    MIRROR="http://archive.debian.org/debian/"
    IS_LEGACY="true"
    echo "Debian ${SERIES} is legacy/EOL. Using mirror: ${MIRROR}"
  fi
else
  echo "Unknown distro: ${DISTRO}" >&2
  exit 1
fi

# Apply debootstrap patches if legacy release
if [ "${IS_LEGACY}" = "true" ]; then
  echo "Applying debootstrap compatibility patch for legacy metadata..."
  sudo python3 - <<'PY' || true
import re, os
p = "/usr/share/debootstrap/functions"
if os.path.exists(p):
    s = open(p).read()
    before = s
    s = s.replace('size="${details##* }";\n\t\t\ttotaldebs=$(($totaldebs + $size))',
                  'size="${details##* }";\n\t\t\t[ -z "$size" ] && size=0\n\t\t\ttotaldebs=$(($totaldebs + $size))')
    s = re.sub(r'progress_next \$\(\(\$dloaddebs \+ \$size\)\)',
               'progress_next $(($dloaddebs + ${size:-0}))', s)
    s = re.sub(r'dloaddebs=\$\(\(\$dloaddebs \+ \$size\)\)',
               'dloaddebs=$((dloaddebs + ${size:-0}))', s)
    if s != before:
        open(p, "w").write(s)
        print("Successfully patched debootstrap functions")
PY
fi

WORK_DIR="$(pwd)/.linux_maker_build"
sudo rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

FINAL_IMAGE=""

# Build process
if [ "${OUTPUT_FORMAT}" = "live-iso" ] && [ "${IS_LEGACY}" = "false" ]; then
  echo "Building Live ISO using live-build..."
  mkdir -p live-build-project
  cd live-build-project

  LB_DISTRO_MODE="${DISTRO}"
  if [ "${DISTRO}" != "debian" ] && [ "${DISTRO}" != "ubuntu" ]; then
    LB_DISTRO_MODE="debian"
  fi

  lb config \
    --distribution "${SERIES}" \
    --architectures "${ARCH}" \
    --mode "${LB_DISTRO_MODE}" \
    --archive-areas "main universe multiverse" \
    --binary-images iso-hybrid \
    --linux-flavours "${KERNEL_FLAVOUR}" \
    --iso-volume "${DISTRO^^}_LIVE" \
    --iso-application "Linux Maker - ${DISTRO} ${SERIES}" \
    --parent-mirror-bootstrap "${MIRROR}" \
    --parent-mirror-chroot "${MIRROR}" \
    --parent-mirror-binary "${MIRROR}"

  mkdir -p config/package-lists
  if [ -n "${FLAVOR}" ] && [ "${FLAVOR}" != "none" ] && [ "${FLAVOR}" != "none (server)" ]; then
    echo "${FLAVOR}" >> config/package-lists/custom.list.chroot
  fi

  if [ -n "${CUSTOM_PACKAGES}" ]; then
    echo "${CUSTOM_PACKAGES}" >> config/package-lists/custom.list.chroot
  fi

  if [ -n "${CUSTOM_SCRIPT}" ]; then
    mkdir -p config/hooks/live
    if [ -f "${CUSTOM_SCRIPT}" ]; then
      cp "${CUSTOM_SCRIPT}" config/hooks/live/99-custom-hook.chroot
      chmod +x config/hooks/live/99-custom-hook.chroot
    else
      cat <<HOOK > config/hooks/live/99-custom-hook.chroot
#!/bin/bash
set -e
${CUSTOM_SCRIPT}
HOOK
      chmod +x config/hooks/live/99-custom-hook.chroot
    fi
  fi

  sudo lb build

  ISO_FILE="$(find . -maxdepth 2 -name "*.iso" | head -n 1)"
  if [ -z "${ISO_FILE}" ]; then
    echo "Error: Live ISO build did not output an .iso file" >&2
    exit 1
  fi

  DEST_NAME="${DISTRO}-${SERIES}-${ARCH}-${VERSION}.iso"
  sudo cp "${ISO_FILE}" "../../${OUTPUT_DIR}/${DEST_NAME}"
  FINAL_IMAGE="../../${OUTPUT_DIR}/${DEST_NAME}"
  cd ../..

else
  echo "Building rootfs via debootstrap..."
  ROOTFS_DIR="${WORK_DIR}/rootfs"
  sudo mkdir -p "${ROOTFS_DIR}"

  DEBOOTSTRAP_OPTS=("--arch" "${ARCH}")
  if [ "${IS_LEGACY}" = "true" ]; then
    DEBOOTSTRAP_OPTS+=("--no-check-gpg")
    export SHA_SIZE=1
  fi

  set +e
  sudo env SHA_SIZE="${SHA_SIZE:-}" debootstrap "${DEBOOTSTRAP_OPTS[@]}" "${SERIES}" "${ROOTFS_DIR}" "${MIRROR}"
  D_STATUS=$?
  set -e

  if [ ${D_STATUS} -ne 0 ]; then
    echo "Standard debootstrap failed (exit code ${D_STATUS}). Trying foreign mode with qemu..."
    sudo rm -rf "${ROOTFS_DIR}"
    sudo mkdir -p "${ROOTFS_DIR}/usr/bin"
    sudo apt-get install -y --no-install-recommends qemu-user-static || true
    if [ "${ARCH}" = "i386" ]; then
      sudo cp /usr/bin/qemu-i386-static "${ROOTFS_DIR}/usr/bin/" 2>/dev/null || true
    elif [ "${ARCH}" = "arm64" ]; then
      sudo cp /usr/bin/qemu-aarch64-static "${ROOTFS_DIR}/usr/bin/" 2>/dev/null || true
    fi

    sudo env SHA_SIZE="${SHA_SIZE:-}" debootstrap --foreign "${DEBOOTSTRAP_OPTS[@]}" "${SERIES}" "${ROOTFS_DIR}" "${MIRROR}"
    sudo chroot "${ROOTFS_DIR}" /debootstrap/debootstrap --second-stage
  fi

  # Chroot customization
  if [ -n "${CUSTOM_PACKAGES}" ] || [ -n "${CUSTOM_SCRIPT}" ] || ([ "${FLAVOR}" != "none" ] && [ -n "${FLAVOR}" ]); then
    echo "Running custom chroot configurations..."
    sudo mount --bind /dev "${ROOTFS_DIR}/dev" || true
    sudo mount --bind /proc "${ROOTFS_DIR}/proc" || true
    sudo mount --bind /sys "${ROOTFS_DIR}/sys" || true

    CHROOT_SCRIPT="${WORK_DIR}/chroot_setup.sh"
    cat <<'SCRIPT_HEAD' > "${CHROOT_SCRIPT}"
#!/usr/bin/env bash
set -e
export DEBIAN_FRONTEND=noninteractive
SCRIPT_HEAD

    if [ -n "${FLAVOR}" ] && [ "${FLAVOR}" != "none" ] && [ "${FLAVOR}" != "none (server)" ]; then
      echo "apt-get update -qq && apt-get install -y ${FLAVOR}" >> "${CHROOT_SCRIPT}"
    fi

    if [ -n "${CUSTOM_PACKAGES}" ]; then
      echo "apt-get update -qq && apt-get install -y ${CUSTOM_PACKAGES}" >> "${CHROOT_SCRIPT}"
    fi

    if [ -n "${CUSTOM_SCRIPT}" ]; then
      if [ -f "${CUSTOM_SCRIPT}" ]; then
        cat "${CUSTOM_SCRIPT}" >> "${CHROOT_SCRIPT}"
      else
        echo "${CUSTOM_SCRIPT}" >> "${CHROOT_SCRIPT}"
      fi
    fi

    chmod +x "${CHROOT_SCRIPT}"
    sudo cp "${CHROOT_SCRIPT}" "${ROOTFS_DIR}/tmp/setup.sh"
    sudo chroot "${ROOTFS_DIR}" /tmp/setup.sh || echo "Warning: chroot customization completed with warnings"
    sudo rm -f "${ROOTFS_DIR}/tmp/setup.sh" "${CHROOT_SCRIPT}"

    sudo umount -l "${ROOTFS_DIR}/dev" 2>/dev/null || true
    sudo umount -l "${ROOTFS_DIR}/proc" 2>/dev/null || true
    sudo umount -l "${ROOTFS_DIR}/sys" 2>/dev/null || true
  fi

  # Clean chroot before packing
  sudo rm -rf "${ROOTFS_DIR}/var/cache/apt/archives"/* 2>/dev/null || true

  DEST_NAME="${DISTRO}-${SERIES}-${ARCH}-${VERSION}.tar.gz"
  echo "Compressing rootfs tarball to ${OUTPUT_DIR}/${DEST_NAME}..."
  sudo tar -czf "${OUTPUT_DIR}/${DEST_NAME}" -C "${ROOTFS_DIR}" .
  FINAL_IMAGE="${OUTPUT_DIR}/${DEST_NAME}"
fi

# Cleanup work dir
sudo rm -rf "${WORK_DIR}"

# Compute SHA256 checksum and size
IMAGE_NAME="$(basename "${FINAL_IMAGE}")"
IMAGE_PATH="${OUTPUT_DIR}/${IMAGE_NAME}"
CHECKSUM_FILE="${IMAGE_PATH}.sha256"

sha256sum "${IMAGE_PATH}" | awk '{print $1}' | tr -d '\n' > "${CHECKSUM_FILE}"
IMAGE_SIZE="$(du -h "${IMAGE_PATH}" | awk '{print $1}')"

echo "=========================================="
echo " Build Completed Successfully!"
echo " Image:    ${IMAGE_PATH}"
echo " Size:     ${IMAGE_SIZE}"
echo " Checksum: $(cat "${CHECKSUM_FILE}")"
echo "=========================================="

# Export to GitHub Actions environment / step outputs if available
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "image_path=${IMAGE_PATH}" >> "${GITHUB_OUTPUT}"
  echo "image_name=${IMAGE_NAME}" >> "${GITHUB_OUTPUT}"
  echo "checksum_path=${CHECKSUM_FILE}" >> "${GITHUB_OUTPUT}"
  echo "image_size=${IMAGE_SIZE}" >> "${GITHUB_OUTPUT}"
  echo "version=${VERSION}" >> "${GITHUB_OUTPUT}"
  echo "is_legacy=${IS_LEGACY}" >> "${GITHUB_OUTPUT}"
fi
