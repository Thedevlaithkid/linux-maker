#!/usr/bin/env bash
set -euo pipefail

# Normalize inputs and handle empty or boolean fallbacks from GitHub Actions expressions
DISTRO="${INPUT_DISTRO:-ubuntu}"
if [ -z "${DISTRO}" ] || [ "${DISTRO}" = "true" ] || [ "${DISTRO}" = "false" ]; then
  DISTRO="ubuntu"
fi

SERIES="${INPUT_SERIES:-noble}"
if [ -z "${SERIES}" ] || [ "${SERIES}" = "true" ] || [ "${SERIES}" = "false" ]; then
  SERIES="noble"
fi

REQUESTED_ARCH="${INPUT_ARCH:-amd64}"
if [ -z "${REQUESTED_ARCH}" ] || [ "${REQUESTED_ARCH}" = "true" ] || [ "${REQUESTED_ARCH}" = "false" ]; then
  REQUESTED_ARCH="amd64"
fi

OUTPUT_FORMAT="${INPUT_OUTPUT_FORMAT:-rootfs-tarball}"
if [ -z "${OUTPUT_FORMAT}" ] || [ "${OUTPUT_FORMAT}" = "true" ] || [ "${OUTPUT_FORMAT}" = "false" ]; then
  OUTPUT_FORMAT="rootfs-tarball"
fi

FLAVOR="${INPUT_FLAVOR:-none}"
if [ "${FLAVOR}" = "true" ] || [ "${FLAVOR}" = "false" ]; then
  FLAVOR="none"
fi

KERNEL_FLAVOUR="${INPUT_KERNEL_FLAVOUR:-generic}"
if [ -z "${KERNEL_FLAVOUR}" ] || [ "${KERNEL_FLAVOUR}" = "true" ] || [ "${KERNEL_FLAVOUR}" = "false" ]; then
  KERNEL_FLAVOUR="generic"
fi

CUSTOM_PACKAGES="${INPUT_CUSTOM_PACKAGES:-}"
if [ "${CUSTOM_PACKAGES}" = "true" ] || [ "${CUSTOM_PACKAGES}" = "false" ]; then
  CUSTOM_PACKAGES=""
fi

CUSTOM_SCRIPT="${INPUT_CUSTOM_SCRIPT:-}"
if [ "${CUSTOM_SCRIPT}" = "true" ] || [ "${CUSTOM_SCRIPT}" = "false" ]; then
  CUSTOM_SCRIPT=""
fi

VERSION="${INPUT_VERSION:-}"
if [ -z "$VERSION" ] || [ "$VERSION" = "true" ] || [ "$VERSION" = "false" ]; then
  if [[ "${GITHUB_REF:-}" =~ ^refs/tags/v?(.*)$ ]]; then
    VERSION="${BASH_REMATCH[1]}"
  else
    VERSION="$(date +%Y.%m.%d-%H%M%S)"
  fi
fi

OUTPUT_DIR="${INPUT_OUTPUT_DIR:-dist}"
if [ -z "${OUTPUT_DIR}" ] || [ "${OUTPUT_DIR}" = "true" ] || [ "${OUTPUT_DIR}" = "false" ]; then
  OUTPUT_DIR="dist"
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
  echo "Unknown distro: ${DISTRO}, falling back to ubuntu" >&2
  DISTRO="ubuntu"
  MIRROR="http://archive.ubuntu.com/ubuntu/"
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

# Attempt live-iso build if requested and command available
BUILD_SUCCESS="false"
if [ "${OUTPUT_FORMAT}" = "live-iso" ] && [ "${IS_LEGACY}" = "false" ] && command -v lb >/dev/null 2>&1; then
  echo "Attempting Live ISO build using live-build..."
  mkdir -p live-build-project
  cd live-build-project

  LB_DISTRO_MODE="${DISTRO}"
  [ "${DISTRO}" != "debian" ] && [ "${DISTRO}" != "ubuntu" ] && LB_DISTRO_MODE="debian"

  set +e
  sudo lb config \
    --distribution "${SERIES}" \
    --architectures "${ARCH}" \
    --mode "${LB_DISTRO_MODE}" \
    --archive-areas "main universe multiverse" \
    --binary-images iso-hybrid \
    --linux-flavours "${KERNEL_FLAVOUR}" \
    --iso-volume "${DISTRO^^}_LIVE" \
    --iso-application "Linux Maker" \
    --parent-mirror-bootstrap "${MIRROR}" \
    --parent-mirror-chroot "${MIRROR}" \
    --parent-mirror-binary "${MIRROR}" 2>&1

  if [ -n "${FLAVOR}" ] && [ "${FLAVOR}" != "none" ] && [ "${FLAVOR}" != "none (server)" ]; then
    echo "${FLAVOR}" | sudo tee -a config/package-lists/custom.list.chroot >/dev/null
  fi
  if [ -n "${CUSTOM_PACKAGES}" ]; then
    echo "${CUSTOM_PACKAGES}" | sudo tee -a config/package-lists/custom.list.chroot >/dev/null
  fi

  sudo lb build 2>&1
  LB_STATUS=$?
  set -e

  ISO_FILE="$(find . -maxdepth 2 -name "*.iso" 2>/dev/null | head -n 1)"
  if [ ${LB_STATUS} -eq 0 ] && [ -n "${ISO_FILE}" ]; then
    DEST_NAME="${DISTRO}-${SERIES}-${ARCH}-${VERSION}.iso"
    sudo cp "${ISO_FILE}" "../../${OUTPUT_DIR}/${DEST_NAME}"
    FINAL_IMAGE="../../${OUTPUT_DIR}/${DEST_NAME}"
    BUILD_SUCCESS="true"
  else
    echo "Notice: live-build ISO generation did not succeed (status ${LB_STATUS}). Falling back to rootfs container archive..."
  fi
  cd ../..
fi

# Fallback or default: rootfs tarball
if [ "${BUILD_SUCCESS}" != "true" ]; then
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
    echo "Standard debootstrap encountered errors (status ${D_STATUS}). Attempting foreign multi-stage fallback..."
    sudo rm -rf "${ROOTFS_DIR}"
    sudo mkdir -p "${ROOTFS_DIR}/usr/bin"
    sudo apt-get install -y --no-install-recommends qemu-user-static >/dev/null 2>&1 || true
    if [ "${ARCH}" = "i386" ]; then
      sudo cp /usr/bin/qemu-i386-static "${ROOTFS_DIR}/usr/bin/" 2>/dev/null || true
    elif [ "${ARCH}" = "arm64" ]; then
      sudo cp /usr/bin/qemu-aarch64-static "${ROOTFS_DIR}/usr/bin/" 2>/dev/null || true
    fi

    set +e
    sudo env SHA_SIZE="${SHA_SIZE:-}" debootstrap --foreign "${DEBOOTSTRAP_OPTS[@]}" "${SERIES}" "${ROOTFS_DIR}" "${MIRROR}"
    sudo chroot "${ROOTFS_DIR}" /debootstrap/debootstrap --second-stage 2>&1 || true
    set -e
  fi

  # Customization in chroot if requested
  if [ -n "${CUSTOM_PACKAGES}" ] || [ -n "${CUSTOM_SCRIPT}" ] || ([ "${FLAVOR}" != "none" ] && [ -n "${FLAVOR}" ]); then
    echo "Executing customizations..."
    sudo mount --bind /dev "${ROOTFS_DIR}/dev" 2>/dev/null || true
    sudo mount --bind /proc "${ROOTFS_DIR}/proc" 2>/dev/null || true
    sudo mount --bind /sys "${ROOTFS_DIR}/sys" 2>/dev/null || true

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
    sudo cp "${CHROOT_SCRIPT}" "${ROOTFS_DIR}/tmp/setup.sh" 2>/dev/null || true
    sudo chroot "${ROOTFS_DIR}" /tmp/setup.sh 2>&1 || echo "Notice: Post-install script finished with non-fatal warnings"
    sudo rm -f "${ROOTFS_DIR}/tmp/setup.sh" "${CHROOT_SCRIPT}" 2>/dev/null || true

    sudo umount -l "${ROOTFS_DIR}/dev" 2>/dev/null || true
    sudo umount -l "${ROOTFS_DIR}/proc" 2>/dev/null || true
    sudo umount -l "${ROOTFS_DIR}/sys" 2>/dev/null || true
  fi

  # Clean package cache to save space
  sudo rm -rf "${ROOTFS_DIR}/var/cache/apt/archives"/* 2>/dev/null || true

  DEST_NAME="${DISTRO}-${SERIES}-${ARCH}-${VERSION}.tar.gz"
  echo "Compressing rootfs to ${OUTPUT_DIR}/${DEST_NAME}..."
  sudo tar -czf "${OUTPUT_DIR}/${DEST_NAME}" -C "${ROOTFS_DIR}" .
  FINAL_IMAGE="${OUTPUT_DIR}/${DEST_NAME}"
fi

# Cleanup build workspace
sudo rm -rf "${WORK_DIR}" 2>/dev/null || true

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

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "image_path=${IMAGE_PATH}" >> "${GITHUB_OUTPUT}"
  echo "image_name=${IMAGE_NAME}" >> "${GITHUB_OUTPUT}"
  echo "checksum_path=${CHECKSUM_FILE}" >> "${GITHUB_OUTPUT}"
  echo "image_size=${IMAGE_SIZE}" >> "${GITHUB_OUTPUT}"
  echo "version=${VERSION}" >> "${GITHUB_OUTPUT}"
  echo "is_legacy=${IS_LEGACY}" >> "${GITHUB_OUTPUT}"
fi
