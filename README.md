# arch-avf

Arch Linux ARM payload builder for Android's AVF Terminal app on Android 16 and newer.

Android Virtualization Framework (AVF) is Android's protected virtualization stack. The Terminal app uses AVF to boot a Linux VM from an application-owned payload directory instead of from a traditional bootable disk. Google's Terminal image is Debian-based; `nixos-avf` proves the same interface can boot another distribution. This repository applies that model to Arch Linux ARM.

## Android Terminal Image Format

The supported artifact in this repository is the production `replace`
package. It rewrites an already-installed stock Debian Terminal payload in
place, while preserving the Terminal-managed `cidata.iso` that Debian ships.

Historically, Android 16 Terminal debug builds can import a single archive from:

```text
/sdcard/linux/images.tar.gz
```

The replace archive produced by this repo contains:

```text
vm_config.json
build_id
root_part
vmlinuz
initrd.img
kernel.source
replace.sh
```

`vm_config.json` intentionally follows the Android 16 Debian Terminal layout for
the supported `replace` flow. The active boot path is direct kernel + initrd +
`root_part`, plus the existing Terminal-managed `cidata.iso` already present on
the device after the stock Debian install.

`build_id` must use the exact `target-id-date` shape accepted by the Android 16 Terminal APK:

```text
<target>-<integer-build-id>-<EEE MMM dd HH:mm:ss UTC yyyy>
```

Example:

```text
archlinux/aarch64/2026.05.12-6.12.77-4k-gbd720db56e2e-1778203200-Tue May 12 12:00:00 UTC 2026
```

The checked-in config uses:

- 4096 MiB RAM with automatic memory ballooning
- CPU topology matching the Android host
- virtio block, network, console, balloon, input, sound, and shared-path support
- serial console on `ttyS0`
- Android Terminal-compatible VM name `debian`
- root login over SSH with password `root`
- default user `droid` with password `droid` and passwordless sudo

## Requirements

Build host:

- Linux with loop-mount support
- Docker
- `sudo`
- `clang`, `lld`, `llvm`, `git`, `sfdisk`, `mkfs.ext4`, `tar`, `python3`, `sha256sum`
- Android Platform Tools for deployment with `adb`

The rootfs build runs inside Docker. The default kernel build follows Google's Android common kernel branch and can run either inside Docker or directly on the host; GitHub Actions uses the host backend on `ubuntu-24.04-arm`. The image assembly step uses host loop mounts, so it must run on Linux.

## Build

```bash
make all
```

Useful targets:

```bash
make kernel            # Cross-compile aarch64 Linux kernel and modules
make kernel-packages   # Build Arch pacman packages for the kernel and firmware
make avf-config-package # Build the Arch pacman package for AVF guest config
make rootfs            # Build Arch Linux ARM rootfs and initrd.img
make image             # Create root_part, payload dir, and the replace package
make payload           # Refresh build/payload only, without packaging tarballs
make android-services  # Build Android guest service binaries from AOSP
make deploy            # Push existing payload files to /sdcard/Download/image
make clean             # Remove build outputs
```

Build outputs:

```text
build/rootfs/rootfs.tar.gz
build/initrd.img
build/kernel/vmlinuz
build/kernel/modules/
build/packages/*.pkg.tar.zst
build/avf-packages/*.pkg.tar.zst
build/image/root_part
build/payload/
build/arch-avf-replace.tar.gz
build/arch-avf-replace.tar.gz.sha256
```

Tunable environment variables:

```bash
KERNEL_VERSION=6.12.77 KERNEL_GIT_REF=android16-6.12.77_r00 make kernel-packages
ROOT_SIZE_MB=8192 make image
ROOT_PASSWORD=secret DROID_PASSWORD=secret make rootfs
PUSH_ROOT_PART=0 make deploy
PACKAGE_REPLACE=0 PACKAGE_IMPORT=0 bash image/assemble.sh
DEPLOY_MODE=import-image TARGET_DIR=/sdcard/linux make deploy
```

The default kernel source is Android common:

```text
KERNEL_GIT_REPO=https://android.googlesource.com/kernel/common
KERNEL_GIT_REF=android16-6.12.77_r00
KERNEL_BASE_CONFIG=android_avf
```

`config/debian_kernel_config` is an Android/GKI-style arm64 config aligned from Google's Debian Terminal image.

The `kernel` GitHub Actions workflow tracks Google's Android common kernel tags
matching `android16-6.12.*_r*`. It runs daily and can also be started manually;
when a newer Google tag appears, it uploads kernel/firmware pacman packages to
an existing kernel release and uploads the production `replace` package to an
existing image release. The two release tags are separate, and the workflow
does not create releases. Configure repository variables `KERNEL_RELEASE_TAG`
and `IMAGE_RELEASE_TAG`, or pass those tags when manually dispatching the
workflows.

The image workflow runs monthly and downloads the kernel package artifacts from
the existing kernel release instead of rebuilding the kernel. The rootfs build
uses the Arch Linux ARM latest aarch64 rootfs tarball only as the base userspace:
it removes the stock `linux-aarch64`/`linux-firmware` packages and installs the
AVF kernel pacman packages plus the local `arch-avf-config` pacman package with
`pacman -U`. The config package owns the AVF guest services,
debug hooks, ttyd wiring, first-boot setup, and the Android Terminal-compatible
`droid` user at UID 1000, so kernel updates can be shipped independently from
full image rebuilds.

## Deploy

### Debuggable Android builds

Enable the Android Terminal app on an Android 16+ debuggable/userdebug device, connect the device with USB debugging enabled, then run:

```bash
make deploy
```

If you also provide a matching `build/cidata.iso`, the debug import image can be pushed with:

```bash
DEPLOY_MODE=import-image TARGET_DIR=/sdcard/linux make deploy
```

The debug import image is pushed to:

```text
/sdcard/linux/images.tar.gz
```

Restart the Terminal app. It should offer to auto-install the image.

Production/user builds do not support installing custom images from `/sdcard/linux/images.tar.gz`, and this repository's releases no longer publish that debug-only archive by default.

### Production Android builds

On normal production Android builds, use the replace payload:

1. Install Google's Debian image from the Terminal app once.
2. Run `make payload && make deploy` to push `build/payload/` files directly to `Download/image/`.
   If only kernel/initrd/config changed and the existing phone `root_part` is already current, use `PUSH_ROOT_PART=0 make deploy`.
3. Open Terminal and run:

```bash
bash /mnt/shared/Download/image/replace.sh
```

Terminal will reboot after stage 1. Reopen Terminal; the script should start automatically and perform the longer stage 2 replacement. Reopen Terminal once more after it exits.

After boot, forward SSH and log in:

```bash
adb forward tcp:2222 tcp:22
ssh root@localhost -p 2222
```

Default credentials are `root` / `root`. Change `ROOT_PASSWORD` before building for any device that is not purely local test hardware.

The default normal user is `droid` / `droid`; change `DROID_PASSWORD` before building if you plan to keep the image around.

On the first Arch boot after replace, `arch-avf-firstboot.service` ranks Arch
Linux ARM mirrors with `rate-mirrors archarm`, refreshes pacman databases, and
re-enables pacman's sandbox options that were disabled only for the build
chroot.

## Repository Layout

```text
config/
  vm_config.json       AVF VM configuration
  kernel_fragment      Kernel options required by AVF and the guest
rootfs/
  Dockerfile           Rootfs build container
  build.sh             Arch Linux ARM rootfs and initramfs builder
  packages.txt         Rootfs package list
kernel/
  Dockerfile           Cross-compile container
  build.sh             Linux arm64 kernel builder
android-services/
  README.md            Guest daemon notes
  build.sh             AOSP build entrypoint for guest services
image/
  create-disk.sh       Filesystem image builder
  assemble.sh          Payload assembler
  deploy.sh            adb deploy helper
scripts/
  android-clean-vm.sh  Root-only cleanup helper for Terminal app VM state
  android-push-image.sh Push build/images.tar.gz to /sdcard/linux/
```

## Android Guest Services

AVF guests can integrate more deeply with Android by running guest daemons from the Android Virtualization module:

- `forwarder_guest`
- `forwarder_guest_launcher`
- `storage_balloon_agent`
- `shutdown_runner`

See `android-services/README.md` and `android-services/build.sh`. `rootfs/build.sh` automatically installs any built guest service binaries from `build/android-services/out/` into `/usr/lib/avf` and enables the matching systemd services. A basic Arch boot works without these binaries; Android Terminal integration is incomplete until all four are present.

The rootfs also mounts Terminal shared paths as virtiofs:

- `internal` at `/mnt/internal`
- `android` at `/mnt/shared`

`ttyd` is enabled on port 7681 with TLS and avahi advertisement so the Terminal app can discover the guest web console path used by the Debian/NixOS images.

## References

- `nixos-avf`: <https://github.com/nix-community/nixos-avf>
- Android Virtualization module source: <https://android.googlesource.com/platform/packages/modules/Virtualization/>
- Android Cuttlefish and virtualization source: <https://android.googlesource.com/device/google/cuttlefish/>
- Arch Linux ARM: <https://archlinuxarm.org/>

## License

MIT
