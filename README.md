# arch-avf

Arch Linux ARM payload builder for Android's AVF Terminal app on Android 16 and newer.

The release artifact is a production `replace` package. It rewrites an
already-installed stock Debian Terminal payload in place, while preserving the
Terminal-managed `cidata.iso`.

## What It Builds

The payload follows the Android Terminal direct-boot layout:

```text
vm_config.json
build_id
root_part
vmlinuz
initrd.img
kernel.source
replace.sh
```

The VM keeps the Android Terminal-compatible name `debian`, uses the AVF kernel
and initrd from this repo, and uses an Arch Linux ARM aarch64 root filesystem as
the userspace base.

Default credentials:

```text
root  / root
droid / droid
```

The normal user is `droid` with UID/GID `1000:1000` and passwordless sudo.
Override `ROOT_PASSWORD` and `DROID_PASSWORD` before building if the image will
be used beyond local testing.

## Build Flow

Kernel and image builds are intentionally separate:

1. The `kernel` workflow tracks Google's Android common kernel tags matching
   `android16-6.12.*_r*`.
2. It builds Arch pacman packages:
   `arch-avf-linux-android-*.pkg.tar.zst` and
   `arch-avf-linux-android-firmware-*.pkg.tar.zst`.
   The kernel package is defined by `kernel/PKGBUILD` and follows the Arch Linux
   ARM `linux-aarch64` package layout: `/boot/Image`, `/boot/Image.gz`, module
   files under `/usr/lib/modules`, and an mkinitcpio preset.
3. Those kernel packages are uploaded to an existing kernel release.
4. The `build` workflow downloads the released kernel packages, starts from the
   latest Arch Linux ARM aarch64 rootfs, removes the stock Arch kernel packages,
   installs the AVF kernel packages, then installs the local `arch-avf-config`
   package.
5. The final replace archive is uploaded to an existing image release.

Kernel and image releases are separate. The workflows reuse existing releases
and do not create new ones. Configure these repository variables, or pass the
same values when manually dispatching workflows:

```text
KERNEL_RELEASE_TAG
IMAGE_RELEASE_TAG
```

The image workflow runs monthly, matching Arch Linux ARM rootfs refresh cadence.
The kernel workflow runs daily and also accepts `repository_dispatch` event
`linux-release`.

## Local Build

Requirements:

- Linux with loop-mount support
- Docker
- `sudo`
- `clang`, `lld`, `llvm`, `git`, `sfdisk`, `mkfs.ext4`, `tar`, `python3`,
  `sha256sum`
- Android Platform Tools for deployment with `adb`

Useful targets:

```bash
make kernel-packages      # Build AVF kernel and firmware pacman packages
make avf-config-package   # Build local AVF config pacman package
make rootfs               # Build Arch Linux ARM rootfs and initrd.img
make image                # Build root_part and replace package
make all                  # Build kernel, rootfs, and image
make deploy               # Push payload files to /sdcard/Download/image
make clean                # Remove build outputs
```

Common overrides:

```bash
KERNEL_VERSION=6.12.77 KERNEL_GIT_REF=android16-6.12.77_r00 make kernel-packages
ROOT_PASSWORD=secret DROID_PASSWORD=secret make rootfs
ROOT_SIZE_MB=8192 make image
PUSH_ROOT_PART=0 make deploy
```

Main outputs:

```text
build/packages/*.pkg.tar.zst
build/avf-packages/*.pkg.tar.zst
build/kernel/vmlinuz
build/initrd.img
build/image/root_part
build/arch-avf-replace.tar.gz
```

## Install On Android Terminal

On production Android builds:

1. Install Google's Debian Terminal image once from the Terminal app.
2. Extract `archlinux-avf-aarch64-replace.tar.gz` to
   `/mnt/shared/Download/image`.
3. Run this inside Terminal:

```bash
bash /mnt/shared/Download/image/replace.sh
```

Terminal reboots after stage 1. Reopen Terminal and let stage 2 finish, then
reopen Terminal again.

After boot, SSH can be forwarded with:

```bash
adb forward tcp:2222 tcp:22
ssh root@localhost -p 2222
```

On first Arch boot, `arch-avf-firstboot.service` ranks Arch Linux ARM mirrors,
refreshes pacman databases, and restores pacman sandboxing that was disabled
only for the build chroot.

## AVF Integration

`arch-avf-config` owns the AVF guest configuration installed into the Arch rootfs:

- ttyd web console wiring used by Android Terminal
- virtiofs mounts for `internal` and `android`
- debug and first-boot services
- optional Android guest daemons from `android-services/`
- `droid` user/group setup at UID/GID `1000`

Optional guest daemons can be built from the Android Virtualization module:

```bash
make android-services
```

If present under `build/android-services/out/`, `rootfs/build.sh` installs and
enables `forwarder_guest`, `forwarder_guest_launcher`, `storage_balloon_agent`,
and `shutdown_runner`.

## Layout

```text
config/             VM and kernel config fragments
kernel/             Android common kernel build and Arch packaging
rootfs/             Arch Linux ARM rootfs and AVF config packaging
image/              disk image, payload, and deploy scripts
android-services/   optional Android guest daemon build helpers
scripts/            Android cleanup and push helpers
```

## References

- `nixos-avf`: <https://github.com/nix-community/nixos-avf>
- Android Virtualization module: <https://android.googlesource.com/platform/packages/modules/Virtualization/>
- Arch Linux ARM: <https://archlinuxarm.org/>

## License

MIT
