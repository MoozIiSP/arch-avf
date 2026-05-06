#!/bin/bash
set -euxo pipefail

if [ -e /sdcard ]; then
  echo "DO NOT RUN THIS SCRIPT DIRECTLY ON ANDROID"
  echo "It is intended to run inside the Android Terminal VM."
  exit 2
fi

IMG_LOC=/mnt/shared/image
if [ -e /mnt/shared/Download/image ]; then
  IMG_LOC=/mnt/shared/Download/image
fi
VM_LOC=/mnt/internal/linux
LOGFILE=/mnt/shared/arch-avf.log
STEP_MARKER="$HOME/.arch-avf-step-2"
SELF="$(readlink -f "$0")"

: >> "$LOGFILE"

if command -v perl >/dev/null; then
  exec \
    1> >(tee >(perl '-MPOSIX' -ne '$|++; print strftime("%m.%d.%Y %H:%M:%S %z: ", localtime()), "stdout: ", $_;' >> "$LOGFILE")) \
    2> >(tee >(perl '-MPOSIX' -ne '$|++; print strftime("%m.%d.%Y %H:%M:%S %z: ", localtime()), "stderr: ", $_;' >> "$LOGFILE") >&2)
else
  exec \
    1> >(tee >(awk '{ system(""); print strftime("%m.%d.%Y %H:%M:%S %z:"), "stdout:", $0; system(""); }' >> "$LOGFILE")) \
    2> >(tee >(awk '{ system(""); print strftime("%m.%d.%Y %H:%M:%S %z:"), "stderr:", $0; system(""); }' >> "$LOGFILE") >&2)
fi

require_file() {
  local file="$1"
  [ -f "$file" ] || { echo "Missing required file: $file" >&2; exit 1; }
}

require_file "$IMG_LOC/root_part"
require_file "$IMG_LOC/efi_part"
require_file "$IMG_LOC/vm_config.json"
require_file "$IMG_LOC/build_id"
require_file "$IMG_LOC/vmlinuz"
require_file "$IMG_LOC/initrd.img"

echo "arch-avf replace running, VM_LOC=$VM_LOC, IMG_LOC=$IMG_LOC"

step_1() {
  echo "arch-avf replace step 1: add temporary install partition"

  local root_size
  root_size="$(stat -c '%s' "$IMG_LOC/root_part")"
  sudo truncate -s "$root_size" "$VM_LOC/arch_root"

  if sudo test -e "$VM_LOC/root_part_backup"; then
    sudo mv -v "$VM_LOC/root_part_backup" "$VM_LOC/root_part_backup_"
  fi

  local before after vm_config vm_replaced
  before=$(printf '],\n            "writable": true')
  after=$(printf ',{"label":"archlinux", "path": "$PAYLOAD_DIR/arch_root", "writable": true, "guid": "718bec5e-2048-444d-a2a7-f7294e0d72d6"}],\n            "writable": true')

  vm_config="$(sudo cat "$VM_LOC/vm_config.json")"
  vm_replaced="${vm_config/"$before"/"$after"}"
  if [ "$vm_replaced" = "$vm_config" ]; then
    before=$(printf '],"writable":true')
    after=$(printf ',{"label":"archlinux","path":"$PAYLOAD_DIR/arch_root","writable":true,"guid":"718bec5e-2048-444d-a2a7-f7294e0d72d6"}],"writable":true')
    vm_replaced="${vm_config/"$before"/"$after"}"
  fi
  if [ "$vm_replaced" = "$vm_config" ]; then
    echo "Failed to patch $VM_LOC/vm_config.json; unsupported Terminal config layout" >&2
    exit 1
  fi

  echo "$vm_replaced" | sudo tee "$VM_LOC/vm_config.json"

  if ! grep -q 'arch-avf-step-2' "$HOME/.bashrc" 2>/dev/null; then
    echo "flock -w 1 /tmp/arch-avf-install.lock bash $SELF # arch-avf-step-2" >> "$HOME/.bashrc"
    echo "tail -f $LOGFILE # arch-avf-step-2-log" >> "$HOME/.bashrc"
  fi

  touch "$STEP_MARKER"
  sudo reboot
}

step_2() {
  echo "arch-avf replace step 2: write Arch partitions"

  local target=/dev/vda3
  if [ ! -e "$target" ]; then
    target=/dev/vda2
  fi
  [ -e "$target" ] || { echo "Could not find temporary install partition" >&2; exit 1; }

  echo "=== debug ==="
  lsblk || true
  sudo cat "$VM_LOC/vm_config.json" || true
  echo "=/= debug =/="

  sudo chmod 666 "$target"
  local size iters i
  size="$(du "$IMG_LOC/root_part" | awk '{print $1}')"
  iters=$(( size / (1024 * 250) ))
  for i in $(seq 0 "$iters"); do
    dd "if=$IMG_LOC/root_part" "of=$target" bs=250M count=1 "seek=$i" "skip=$i"
    sync
  done

  local arch_mnt
  arch_mnt="$(mktemp -d)"
  sudo mount "$target" "$arch_mnt"
  sudo mkdir -p "$arch_mnt/usr/lib/avf"
  local binary source
  for binary in forwarder_guest forwarder_guest_launcher storage_balloon_agent shutdown_runner; do
    for source in "/usr/lib/avf/$binary" "/usr/bin/$binary" "/usr/local/bin/$binary" "/usr/bin/${binary//_/-}" "/usr/local/bin/${binary//_/-}"; do
      if [ -x "$source" ]; then
        sudo install -Dm755 "$source" "$arch_mnt/usr/lib/avf/$binary"
        break
      fi
    done
  done
  sudo sync
  sudo umount "$arch_mnt"
  rmdir "$arch_mnt"

  cp "$IMG_LOC/efi_part" .
  sudo umount /boot/efi || true
  sudo umount /kernel_extras || true
  sudo rm -f "$VM_LOC/efi_part" "$VM_LOC/kernel_extras" "$VM_LOC/vmlinuz" "$VM_LOC/initrd.img"
  sync
  sleep 3
  sudo dd if=efi_part bs=1M oflag=direct "of=$VM_LOC/efi_part"
  sync

  cp "$IMG_LOC/vm_config.json" .
  sudo cp vm_config.json "$VM_LOC/vm_config.json"

  cp "$IMG_LOC/build_id" .
  sudo cp build_id "$VM_LOC/build_id"

  cp "$IMG_LOC/vmlinuz" .
  sudo cp vmlinuz "$VM_LOC/vmlinuz"

  cp "$IMG_LOC/initrd.img" .
  sudo cp initrd.img "$VM_LOC/initrd.img"

  sudo rm -f "$VM_LOC/root_part"
  sudo mv "$VM_LOC/arch_root" "$VM_LOC/root_part"

  rm -rfv "$IMG_LOC"

  if sudo test -e "$VM_LOC/root_part_backup_"; then
    sudo mv -v "$VM_LOC/root_part_backup_" "$VM_LOC/root_part_backup"
  fi

  sudo reboot
}

if [ ! -e "$STEP_MARKER" ]; then
  step_1
else
  step_2
fi
