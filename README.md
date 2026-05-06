# arch-avf

Arch Linux ARM payload builder for Android's AVF Terminal app on Android 16 and newer.

Android Virtualization Framework (AVF) is Android's protected virtualization stack. The Terminal app uses AVF to boot a Linux VM from an application-owned payload directory instead of from a traditional bootable disk. Google's Terminal image is Debian-based; `nixos-avf` proves the same interface can boot another distribution. This repository applies that model to Arch Linux ARM.

## Android Terminal Image Format

Android 16 Terminal imports a single archive from:

```text
/sdcard/linux/images.tar.gz
```

The archive produced by this repo contains:

```text
vm_config.json
build_id
root_part
efi_part
vmlinuz
initrd.img
```

`vm_config.json` describes the VM and points AVF at the payload files through `$PAYLOAD_DIR`. `root_part` is a writable ext4 filesystem image mounted as `/dev/vda1`. `efi_part` is a vfat EFI system partition. The image includes both an EFI-stub kernel at `EFI/BOOT/BOOTAA64.EFI` and a direct AVF `kernel` entry for compatibility while the Terminal import path evolves.

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
- `sfdisk`, `mkfs.ext4`, `mkfs.vfat`, `tune2fs`, `tar`, `python3`, `sha256sum`
- Android Platform Tools for deployment with `adb`

The rootfs and kernel builds run inside Docker. The image assembly step uses host loop mounts, so it must run on Linux. GitHub Actions uses `ubuntu-24.04-arm`.

## Build

```bash
make all
```

Useful targets:

```bash
make kernel            # Cross-compile aarch64 Linux kernel and modules
make rootfs            # Build Arch Linux ARM rootfs and initrd.img
make image             # Create root_part, efi_part, payload dir, and images.tar.gz
make android-services  # Build Android guest service binaries from AOSP
make deploy            # Push payload to a connected Android device
make clean             # Remove build outputs
```

Build outputs:

```text
build/rootfs/rootfs.tar.gz
build/initrd.img
build/kernel/vmlinuz
build/kernel/BOOTAA64.EFI
build/kernel/modules/
build/image/root_part
build/image/efi_part
build/payload/
build/images.tar.gz
build/images.tar.gz.sha256
build/arch-avf-replace.tar.gz
build/arch-avf-replace.tar.gz.sha256
```

Tunable environment variables:

```bash
KERNEL_VERSION=6.12.85 make kernel
ROOT_SIZE_MB=8192 EFI_SIZE_MB=256 make image
ROOT_PASSWORD=secret DROID_PASSWORD=secret make rootfs
TARGET_DIR=/sdcard/linux make deploy
```

`APPLY_AVF_PATCHES=auto` is the default. Android's `android-16.0.0_r3`
kernel patch set is applied for Linux 6.1.x builds and skipped for the
default Linux 6.12 LTS build, which uses upstream virtio support.

## Deploy

### Debuggable Android builds

Enable the Android Terminal app on an Android 16+ debuggable/userdebug device, connect the device with USB debugging enabled, then run:

```bash
make deploy
```

The image is pushed to:

```text
/sdcard/linux/images.tar.gz
```

Restart the Terminal app. It should offer to auto-install the image.

Production/user builds do not support installing custom images from `/sdcard/linux/images.tar.gz`.

### Production Android builds

On normal production Android builds, use the replace package:

1. Install Google's Debian image from the Terminal app once.
2. Download `archlinux-avf-aarch64-replace.tar.gz` from the GitHub release.
3. Extract it on the phone so the files are under `Download/image/`.
4. Open Terminal and run:

```bash
bash /mnt/shared/image/replace.sh
```

Terminal will reboot after stage 1. Reopen Terminal; the script should start automatically and perform the longer stage 2 replacement. Reopen Terminal once more after it exits.

After boot, forward SSH and log in:

```bash
adb forward tcp:2222 tcp:22
ssh root@localhost -p 2222
```

Default credentials are `root` / `root`. Change `ROOT_PASSWORD` before building for any device that is not purely local test hardware.

The default normal user is `droid` / `droid`; change `DROID_PASSWORD` before building if you plan to keep the image around.

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
