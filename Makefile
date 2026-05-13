SHELL := /usr/bin/env bash

PROJECT_DIR := $(CURDIR)
BUILD_DIR := $(PROJECT_DIR)/build
PAYLOAD_DIR := $(BUILD_DIR)/payload

.PHONY: all rootfs avf-config-package kernel kernel-packages android-services image payload replace deploy clean distclean check check-payload

.NOTPARALLEL:

all: image check

rootfs:
	@bash "$(PROJECT_DIR)/rootfs/build.sh"

avf-config-package:
	@bash "$(PROJECT_DIR)/rootfs/package-arch.sh"

kernel:
	@bash "$(PROJECT_DIR)/kernel/build.sh"

kernel-packages: kernel
	@bash "$(PROJECT_DIR)/kernel/package-arch.sh"

android-services:
	@bash "$(PROJECT_DIR)/android-services/build.sh"

image: kernel-packages rootfs
	@bash "$(PROJECT_DIR)/image/create-disk.sh"
	@bash "$(PROJECT_DIR)/image/assemble.sh"

payload:
	@PACKAGE_IMPORT=0 PACKAGE_REPLACE=0 bash "$(PROJECT_DIR)/image/assemble.sh"

replace: image

deploy:
	@bash "$(PROJECT_DIR)/image/deploy.sh"

check-payload:
	@test -f "$(PAYLOAD_DIR)/vm_config.json"
	@test -f "$(PAYLOAD_DIR)/build_id"
	@test -s "$(PAYLOAD_DIR)/vmlinuz"
	@test -s "$(PAYLOAD_DIR)/initrd.img"
	@test -s "$(PAYLOAD_DIR)/root_part"
	@python3 -m json.tool "$(PAYLOAD_DIR)/vm_config.json" >/dev/null
	@python3 -c 'import datetime as dt,pathlib,re,sys; build_id=pathlib.Path(sys.argv[1]).read_text().strip(); m=re.fullmatch(r"^(.*?)-(\d+)-(.*)$$", build_id); assert m, f"Invalid Terminal target-id-date build_id: {build_id!r}"; dt.datetime.strptime(m.group(3), "%a %b %d %H:%M:%S %Z %Y"); print(f"Android Terminal build_id: {build_id}")' "$(PAYLOAD_DIR)/build_id"
	@python3 -c 'import pathlib,sys; kernel=pathlib.Path(sys.argv[1]).read_bytes(); assert len(kernel) >= 64, "Kernel image is unexpectedly short"; assert kernel[:2] != b"\x1f\x8b", "vmlinuz is gzip-compressed; crosvm expects raw arm64 Image"; assert kernel[56:60] == b"ARM\x64", f"Unexpected arm64 Image magic: {kernel[56:60]!r}"; print(f"Android Terminal kernel header OK: {sys.argv[1]}")' "$(PAYLOAD_DIR)/vmlinuz"

check: check-payload
	@test -s "$(BUILD_DIR)/arch-avf-replace.tar.gz"
	@if [ -s "$(BUILD_DIR)/images.tar.gz" ]; then echo "Android import image is complete: $(BUILD_DIR)/images.tar.gz"; else echo "Android import image skipped: cidata.iso not present; replace package is the supported artifact"; fi
	@echo "Production replace image is complete: $(BUILD_DIR)/arch-avf-replace.tar.gz"

clean:
	@rm -rf "$(BUILD_DIR)"
	@echo "Removed $(BUILD_DIR)"

distclean: clean
	@podman image rm arch-avf-rootfs arch-avf-kernel 2>/dev/null || true
