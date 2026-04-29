SHELL := /usr/bin/env bash

PROJECT_DIR := $(CURDIR)
BUILD_DIR := $(PROJECT_DIR)/build
PAYLOAD_DIR := $(BUILD_DIR)/payload

.PHONY: all rootfs kernel android-services image deploy clean distclean check

all: kernel rootfs image check

rootfs:
	@bash "$(PROJECT_DIR)/rootfs/build.sh"

kernel:
	@bash "$(PROJECT_DIR)/kernel/build.sh"

android-services:
	@bash "$(PROJECT_DIR)/android-services/build.sh"

image: kernel rootfs
	@bash "$(PROJECT_DIR)/image/create-disk.sh"
	@bash "$(PROJECT_DIR)/image/assemble.sh"

deploy: image
	@bash "$(PROJECT_DIR)/image/deploy.sh"

check:
	@test -f "$(PAYLOAD_DIR)/vm_config.json"
	@test -f "$(PAYLOAD_DIR)/vmlinuz"
	@test -f "$(PAYLOAD_DIR)/initrd.img"
	@test -f "$(PAYLOAD_DIR)/root_part"
	@test -f "$(PAYLOAD_DIR)/efi_part"
	@test -f "$(BUILD_DIR)/images.tar.gz"
	@python3 -m json.tool "$(PAYLOAD_DIR)/vm_config.json" >/dev/null
	@echo "Android import image is complete: $(BUILD_DIR)/images.tar.gz"

clean:
	@rm -rf "$(BUILD_DIR)"
	@echo "Removed $(BUILD_DIR)"

distclean: clean
	@docker image rm arch-avf-rootfs arch-avf-kernel 2>/dev/null || true
