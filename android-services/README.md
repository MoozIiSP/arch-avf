# Android Guest Services

AVF Linux guests normally run a small set of Android-provided guest daemons from the Android Virtualization module. They are not required for the kernel to mount the root filesystem, but they provide the host integration expected by Android's Terminal app and by Microdroid-style guests.

## Services

| Binary | Role |
| --- | --- |
| `forwarder_guest` | Handles host-to-guest and guest-to-host port forwarding over AVF vsock channels. |
| `forwarder_guest_launcher` | Starts and supervises `forwarder_guest` for Terminal's forwarding API. |
| `storage_balloon_agent` | Reports and adjusts reclaimable guest storage so Android can manage VM disk pressure. |
| `shutdown_runner` | Receives host shutdown requests and asks systemd to power off cleanly. |

The services live in Android Open Source Project under:

- <https://android.googlesource.com/platform/packages/modules/Virtualization/>
- `virtualizationservice/`
- `libs/`
- `microdroid/`

The community `nixos-avf` project is the most useful working reference for packaging these binaries outside Android's build system:

- <https://github.com/nix-community/nixos-avf>

## Build Strategy

`build.sh` below performs a real source checkout and starts an AOSP Rust build environment when the Android source tree is available. A full Android platform checkout is large, so the script supports two modes:

1. `AOSP_DIR=/path/to/aosp ./build.sh` builds from an existing checkout.
2. `./build.sh` initializes a shallow Android 16 manifest checkout under `build/android-services/aosp` and builds the guest binaries there.

The produced binaries are copied to `build/android-services/out/`. `rootfs/build.sh` automatically packages any binaries present there into `/usr/lib/avf` and enables the matching systemd services. Missing binaries do not block a basic boot, but Terminal integration is incomplete until all four are present.
