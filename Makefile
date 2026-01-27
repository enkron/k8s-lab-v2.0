.PHONY: help images vms up down clean status ssh-% console-%

# Variables
QEMU := qemu-system-aarch64
FIRMWARE := $(shell nix build nixpkgs#OVMF.fd --print-out-paths --no-link)/FV/QEMU_EFI.fd
NODES := cp-1 worker-1 worker-2 upstream-router
MCAST_ADDR := 230.0.0.1:1234

# Default target
help:
	@echo "Kubernetes Lab v2.0 - Available targets:"
	@echo "  make images        - Download/prepare base VM images"
	@echo "  make cloud-init    - Generate cloud-init ISOs"
	@echo "  make vms           - Create VM disk images from base"
	@echo "  make up            - Start all VMs"
	@echo "  make up-cp-1       - Start control plane node"
	@echo "  make up-worker-1   - Start worker-1"
	@echo "  make up-worker-2   - Start worker-2"
	@echo "  make up-upstream   - Start upstream router"
	@echo "  make down          - Stop all VMs"
	@echo "  make status        - Show VM status"
	@echo "  make ssh-<node>    - SSH to node (e.g., make ssh-cp-1)"
	@echo "  make console-<node>- Serial console to node"
	@echo "  make clean         - Remove generated files"
	@echo "  make nuke          - Remove everything including images"

# Download base cloud image
images:
	@echo "Downloading Debian 12 cloud image (aarch64)..."
	curl -L -o images/debian-12-generic-arm64.qcow2 \
		https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-arm64.qcow2

# Generate cloud-init ISOs
cloud-init: $(foreach node,$(NODES),cloud-init/$(node)/seed.iso)

cloud-init/%/seed.iso: cloud-init/%/user-data cloud-init/%/meta-data
	@echo "Generating cloud-init ISO for $*..."
	mkisofs -output $@ -volid cidata -joliet -rock \
		cloud-init/$*/user-data cloud-init/$*/meta-data

# Create VM disks from base image
vms: $(foreach node,$(NODES),disks/$(node).qcow2)

disks/%.qcow2: images/debian-12-generic-arm64.qcow2
	@mkdir -p disks
	qemu-img create -f qcow2 -b ../images/debian-12-generic-arm64.qcow2 \
		-F qcow2 $@
	qemu-img resize $@ 20G

# Start all VMs
up: up-upstream up-cp-1 up-worker-1 up-worker-2

# Start individual VMs (run in background)
up-cp-1: disks/cp-1.qcow2 cloud-init/cp-1/seed.iso
	@echo "Starting cp-1..."
	$(QEMU) \
		-name cp-1 \
		-machine virt,accel=hvf,highmem=on \
		-cpu host -smp 2 -m 4G \
		-bios $(FIRMWARE) \
		-drive file=disks/cp-1.qcow2,if=virtio,format=qcow2 \
		-drive file=cloud-init/cp-1/seed.iso,if=virtio,format=raw \
		-netdev user,id=mgmt,hostfwd=tcp::2201-:22,hostfwd=tcp::6443-:6443 \
		-device virtio-net-pci,netdev=mgmt,mac=52:54:00:00:01:01 \
		-netdev socket,id=internal,mcast=$(MCAST_ADDR) \
		-device virtio-net-pci,netdev=internal,mac=52:54:00:00:02:01 \
		-pidfile /tmp/qemu-cp-1.pid \
		-daemonize -display none \
		-serial unix:/tmp/qemu-cp-1.sock,server,nowait

up-worker-1: disks/worker-1.qcow2 cloud-init/worker-1/seed.iso
	@echo "Starting worker-1..."
	$(QEMU) \
		-name worker-1 \
		-machine virt,accel=hvf,highmem=on \
		-cpu host -smp 2 -m 4G \
		-bios $(FIRMWARE) \
		-drive file=disks/worker-1.qcow2,if=virtio,format=qcow2 \
		-drive file=cloud-init/worker-1/seed.iso,if=virtio,format=raw \
		-netdev user,id=mgmt,hostfwd=tcp::2202-:22 \
		-device virtio-net-pci,netdev=mgmt,mac=52:54:00:00:01:02 \
		-netdev socket,id=internal,mcast=$(MCAST_ADDR) \
		-device virtio-net-pci,netdev=internal,mac=52:54:00:00:02:02 \
		-pidfile /tmp/qemu-worker-1.pid \
		-daemonize -display none \
		-serial unix:/tmp/qemu-worker-1.sock,server,nowait

up-worker-2: disks/worker-2.qcow2 cloud-init/worker-2/seed.iso
	@echo "Starting worker-2..."
	$(QEMU) \
		-name worker-2 \
		-machine virt,accel=hvf,highmem=on \
		-cpu host -smp 2 -m 4G \
		-bios $(FIRMWARE) \
		-drive file=disks/worker-2.qcow2,if=virtio,format=qcow2 \
		-drive file=cloud-init/worker-2/seed.iso,if=virtio,format=raw \
		-netdev user,id=mgmt,hostfwd=tcp::2203-:22 \
		-device virtio-net-pci,netdev=mgmt,mac=52:54:00:00:01:03 \
		-netdev socket,id=internal,mcast=$(MCAST_ADDR) \
		-device virtio-net-pci,netdev=internal,mac=52:54:00:00:02:03 \
		-pidfile /tmp/qemu-worker-2.pid \
		-daemonize -display none \
		-serial unix:/tmp/qemu-worker-2.sock,server,nowait

up-upstream: disks/upstream-router.qcow2 cloud-init/upstream-router/seed.iso
	@echo "Starting upstream-router..."
	$(QEMU) \
		-name upstream-router \
		-machine virt,accel=hvf,highmem=on \
		-cpu host -smp 1 -m 512M \
		-bios $(FIRMWARE) \
		-drive file=disks/upstream-router.qcow2,if=virtio,format=qcow2 \
		-drive file=cloud-init/upstream-router/seed.iso,if=virtio,format=raw \
		-netdev user,id=mgmt,hostfwd=tcp::2200-:22 \
		-device virtio-net-pci,netdev=mgmt,mac=52:54:00:00:01:00 \
		-netdev socket,id=internal,mcast=$(MCAST_ADDR) \
		-device virtio-net-pci,netdev=internal,mac=52:54:00:00:02:00 \
		-pidfile /tmp/qemu-upstream-router.pid \
		-daemonize -display none \
		-serial unix:/tmp/qemu-upstream-router.sock,server,nowait

# Stop all VMs
down:
	@for node in $(NODES); do \
		if [ -f /tmp/qemu-$$node.pid ]; then \
			echo "Stopping $$node..."; \
			kill $$(cat /tmp/qemu-$$node.pid) 2>/dev/null || true; \
			rm -f /tmp/qemu-$$node.pid /tmp/qemu-$$node.sock; \
		fi \
	done

# VM status
status:
	@for node in $(NODES); do \
		if [ -f /tmp/qemu-$$node.pid ] && kill -0 $$(cat /tmp/qemu-$$node.pid) 2>/dev/null; then \
			echo "$$node: running (PID $$(cat /tmp/qemu-$$node.pid))"; \
		else \
			echo "$$node: stopped"; \
		fi \
	done

# SSH access
ssh-cp-1:
	ssh -p 2201 k8s@localhost

ssh-worker-1:
	ssh -p 2202 k8s@localhost

ssh-worker-2:
	ssh -p 2203 k8s@localhost

ssh-upstream:
	ssh -p 2200 k8s@localhost

# Serial console access
console-%:
	socat -,raw,echo=0 unix-connect:/tmp/qemu-$*.sock

# Cleanup
clean:
	rm -rf disks/ cloud-init/*/seed.iso

nuke: clean
	rm -rf images/
