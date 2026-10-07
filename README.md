# Linux Maker 🐧

A reusable GitHub Action and automated workflow engine to build custom Linux distributions, live bootable ISOs, and rootfs images directly inside GitHub Actions.

Built for [@Thedevlaithkid](https://github.com/Thedevlaithkid).

---

## 🚀 Features

- **Dual Output Formats**: Generate bootable hybrid Live ISOs (`live-build` + `xorriso`) or rootfs container tarballs (`debootstrap`).
- **Modern & Legacy Release Support**: Automatically handles modern Ubuntu/Debian mirrors as well as legacy/EOL releases (`old-releases.ubuntu.com`, `archive.debian.org`), including debootstrap patch fixes for legacy metadata.
- **Architectures**: Supports `amd64`, `i386`, and `arm64` (with `qemu-user-static` foreign bootstrap support).
- **Desktop Flavors**: Easily bundle desktop environments (`ubuntu-desktop`, `xubuntu-desktop`, `kubuntu-desktop`, `lubuntu-desktop`, `xfce4`) or minimal/server baselines.
- **Custom Customization Hooks**: Inject custom package lists and execute custom post-bootstrap setup scripts directly into the chroot before imaging.
- **Automated Checksums & Artifacts**: Generates SHA256 checksum files alongside image outputs.

---

## 📦 Usage as a GitHub Action

You can use `Thedevlaithkid/linux-maker` as a workflow step in any repository:

```yaml
name: Build Custom OS
on: [push, workflow_dispatch]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build Ubuntu 24.04 (Noble) Live ISO
        id: maker
        uses: Thedevlaithkid/linux-maker@v1
        with:
          distro: 'ubuntu'
          series: 'noble'
          arch: 'amd64'
          output_format: 'live-iso'
          flavor: 'xubuntu-desktop'
          custom_packages: 'htop curl git vim'
          output_dir: 'dist'

      - name: Upload ISO Artifact
        uses: actions/upload-artifact@v4
        with:
          name: ubuntu-live-iso
          path: ${{ steps.maker.outputs.image_path }}
```

---

## ⚙️ Action Inputs

| Input | Description | Default |
|---|---|---|
| `distro` | Linux distribution family (`ubuntu` or `debian`) | `'ubuntu'` |
| `series` | Distribution release codename (e.g. `noble`, `jammy`, `focal`, `bookworm`, `warty`) | `'noble'` |
| `arch` | Target architecture (`amd64`, `i386`, `arm64`) | `'amd64'` |
| `output_format` | Image type to build (`live-iso` or `rootfs-tarball`) | `'rootfs-tarball'` |
| `flavor` | Desktop flavor or package bundle (`ubuntu-desktop`, `xubuntu-desktop`, `none`) | `'none'` |
| `kernel_flavour` | Kernel package flavour (`generic`, `virtual`) | `'generic'` |
| `custom_packages` | Space-separated list of extra packages to install into rootfs | `''` |
| `custom_script` | Inline bash commands or file path to execute inside chroot | `''` |
| `version` | Custom version tag for the output artifact | Auto-generated timestamp or git tag |
| `output_dir` | Directory to output the built image and checksum | `'dist'` |

---

## 📤 Action Outputs

| Output | Description |
|---|---|
| `image_path` | Relative path to the generated image file |
| `image_name` | File name of the generated artifact |
| `checksum_path` | Path to the `.sha256` checksum file |
| `image_size` | Human-readable size of the final image |
| `version` | The resolved version string applied to the image |
| `is_legacy` | `true` if an archived/EOL repository mirror was utilized |

---

## 🛠️ How to Publish to GitHub (`@Thedevlaithkid/linux-maker`)

Run the following commands on your machine or terminal with the GitHub CLI authenticated:

```bash
# 1. Navigate to the repository
cd linux-maker

# 2. Create the remote repository on GitHub under @Thedevlaithkid
gh repo create Thedevlaithkid/linux-maker --public --source=. --remote=origin --push

# 3. Tag the first release so people can reference @v1
git tag -a v1 -m "Release v1"
git push origin v1
```

Or using standard Git:

```bash
# 1. Create an empty repository named 'linux-maker' at https://github.com/new
# 2. Add remote and push:
git remote add origin https://github.com/Thedevlaithkid/linux-maker.git
git branch -M main
git push -u origin main
git tag -a v1 -m "Release v1"
git push origin v1
```
