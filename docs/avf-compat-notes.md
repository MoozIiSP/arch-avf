# AVF Compatibility Workarounds

These are temporary boot-alignment changes for Android Terminal AVF.

## Disabled for now

- `bcc-libbpf-tools` / `libbpf.so*`
  - Reason: Arch `systemd 260.1-2` is built with `+BPF_FRAMEWORK` and loads `libbpf.so.1` via `dlopen()`.
  - Failure seen in AVF console: `Loaded 'libbpf.so.1' via dlopen()` followed by `Caught <ILL>` and PID1 freeze.
  - Google Debian has `libbpf`, but its PID1 systemd does not appear to use the systemd BPF framework path.

- `zram-generator`
  - Reason: after removing `libbpf.so*`, boot advanced farther, then `/usr/lib/systemd/system-generators/zram-generator` terminated with `signal ILL`.
  - zram is not required for the Terminal VM boot path.

## Rollback

When the real CPU/userspace compatibility issue is fixed:

1. Add `bcc-libbpf-tools` back to `rootfs/packages.txt`.
2. Add `zram-generator` back to `rootfs/packages.txt`.
3. Restore `rootfs/overlay/etc/systemd/zram-generator.conf` if zram should be enabled.
4. Remove the AVF compatibility cleanup block in `rootfs/build.sh`.

## Kernel Build Backend

`kernel/build.sh` can build either in a container or directly on the host:

```sh
KERNEL_BUILD_BACKEND=host make kernel
```

GitHub Actions uses the host backend so it can build Android common kernel
refs without depending on an `orig/` directory. The production kernel source is
Android common, currently `android16-6.12.77_r00`. Legacy fallback source paths
were removed so repository builds stay on the Android common branch line.
