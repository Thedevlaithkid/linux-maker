# linux-maker

An automated builder to compile a minimal, bootable Linux system from scratch using the Linux Kernel and BusyBox.

## Features

- **Automated Kernel Compilation**: Downloads and builds the latest stable Linux kernel (`bzImage`).
- **BusyBox Rootfs**: Compiles a static BusyBox binary and scaffolds a minimal `/init` ramdisk.
- **QEMU Emulation**: Instantly boot and test your custom Linux distribution with a single command.
- **Customizable**: Tweak kernel configurations, BusyBox applets, and init scripts easily.

## Requirements

Install the necessary build dependencies (Debian/Ubuntu):

```bash
sudo apt update
sudo apt install -y build-essential bc bison flex libelf-dev libssl-dev qemu-system-x86 xorriso cpio curl
```

## Quick Start

### 1. Build the Complete System

```bash
make all
# or
./build.sh all
```

The output artifacts will be placed in the `out/` directory:
- `out/bzImage` — Compiled Linux kernel
- `out/initramfs.cpio.gz` — Minimal initramfs with BusyBox

### 2. Run in QEMU

Test the built system directly in your terminal:

```bash
make run
```

To exit QEMU at any time, press `Ctrl+A` then `X`.

### 3. Clean Build Artifacts

```bash
make clean
```

## Repository Information

Created for [@Thedevlaithkid](https://github.com/Thedevlaithkid).
