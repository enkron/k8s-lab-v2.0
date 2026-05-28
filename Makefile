# k8s-lab v2.0 — Talos Linux + Debian hybrid
#
# Kubernetes nodes (control-plane-1, worker-1, worker-2) run Talos Linux.
# Upstream router runs Debian 12 with FRR for BGP edge routing.
# All VMs use QEMU aarch64 with HVF acceleration on Apple Silicon.

# Actions
.PHONY: help up down clean nuke status images vms seed cloud-init vde-up
.PHONY: talos-gen talos-configs talos-seed
.PHONY: bootstrap kubeconfig cilium-install frr-rr cilium-bgp
.PHONY: talos-dashboard talos-health
.PHONY: ssh-upstream console-%

# --- Configuration ---

QEMU := qemu-system-aarch64
# EDK2 AAVMF: UEFI firmware for aarch64 (ARM has no BIOS fallback).
# Uses pflash (not -bios): separate code (read-only) and per-VM variable store.
# -bios is a shorthand that doesn't properly persist UEFI variables on ARM and
# caused hangs with Talos v1.12+.
FIRMWARE_CODE := $(shell nix build nixpkgs\#qemu --print-out-paths --no-link)/share/qemu/edk2-aarch64-code.fd

TALOS_VERSION := v1.13.2
# Pin Kubernetes to 1.35.x: Talos v1.13.2 defaults to K8s 1.36.0, but the
# current stable Cilium (1.19.x) is only e2e-tested up to K8s 1.35.
KUBERNETES_VERSION := 1.35.5
# Default schematic (no extensions) from Talos Image Factory.
# The nocloud variant reads machine config from a CIDATA ISO at boot.
TALOS_SCHEMATIC := 376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba
TALOS_IMAGE_URL := https://factory.talos.dev/image/$(TALOS_SCHEMATIC)/$(TALOS_VERSION)/nocloud-arm64.raw.zst

TALOS_NODES := control-plane-1 worker-1 worker-2
DEBIAN_NODES := upstream-router
NODES := $(TALOS_NODES) $(DEBIAN_NODES)

CLUSTER_NAME := k8s-lab
# Workers reach the API server over the internal multicast network (fd00:100::/64),
# not through SLIRP management IPs (which are isolated per-VM NAT).
CLUSTER_ENDPOINT := https://[fd00:100::10]:6443
TALOSCONFIG := talos/generated/talosconfig

# VDE (Virtual Distributed Ethernet) switch provides the internal L2 segment.
# QEMU's built-in multicast socket (-netdev socket,mcast=) is broken on macOS:
# the kernel ignores IP_MULTICAST_LOOP=0 semantics and drops all local delivery.
# VDE creates a proper userspace virtual switch — no root, no entitlements.
VDE_SWITCH := $(shell nix build nixpkgs\#vde2 --print-out-paths --no-link)/bin/vde_switch
VDE_SOCK := /tmp/vde-k8s-lab.ctl
MGMT_NET := 192.168.100.0/24
MGMT_CP_IP := 192.168.100.10
MGMT_W1_IP := 192.168.100.11
MGMT_W2_IP := 192.168.100.12
MGMT_UPSTREAM_IP := 192.168.100.13

# --- Help ---

help:
	@echo "k8s-lab v2.0 — Talos Linux + Debian hybrid"
	@echo ""
	@echo "Infrastructure:"
	@echo "  make images              Download base VM images (Debian + Talos)"
	@echo "  make vms                 Create per-node CoW disk images"
	@echo "  make seed                Generate all seed ISOs (Talos + cloud-init)"
	@echo "  make up                  Start all VMs"
	@echo "  make down                Stop all VMs"
	@echo "  make status              Show VM status"
	@echo "  make clean               Remove disks, generated configs, and ISOs"
	@echo "  make nuke                Remove everything including base images"
	@echo ""
	@echo "Talos config:"
	@echo "  make talos-gen           Generate base Talos machine configs"
	@echo "  make talos-configs       Patch per-node Talos configs"
	@echo "  make talos-seed          Generate CIDATA ISOs for Talos nodes"
	@echo ""
	@echo "Cluster lifecycle:"
	@echo "  make bootstrap           Bootstrap etcd + control plane (once)"
	@echo "  make kubeconfig          Retrieve kubeconfig from Talos"
	@echo "  make cilium-install      Install Cilium CNI via Helm"
	@echo "  make frr-rr              Deploy FRR Route Reflector pod on control-plane-1"
	@echo "  make cilium-bgp          Apply Cilium iBGP peering CRDs for workers"
	@echo ""
	@echo "Access & debugging:"
	@echo "  make ssh-upstream        SSH to upstream router (Debian)"
	@echo "  make console-<node>      Serial console via QEMU socket"
	@echo "  make talos-dashboard     Interactive Talos TUI dashboard"
	@echo "  make talos-health        Check cluster health"

# --- Base images ---

# Debian 12 cloud image for the upstream router.
images/debian-12-generic-arm64.qcow2:
	@mkdir -p images
	@echo "Downloading Debian 12 cloud image (aarch64)..."
	curl -L -o $@ \
		https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-arm64.qcow2

# Talos nocloud image for Kubernetes nodes.
# Downloaded as zstd-compressed raw from Image Factory, converted to qcow2.
images/talos-arm64-nocloud.qcow2:
	@mkdir -p images
	@echo "Downloading Talos $(TALOS_VERSION) nocloud image (aarch64)..."
	curl -L -o images/nocloud-arm64.raw.zst $(TALOS_IMAGE_URL)
	zstd -d images/nocloud-arm64.raw.zst --output-dir-flat images/
	qemu-img convert -f raw -O qcow2 images/nocloud-arm64.raw $@
	rm -f images/nocloud-arm64.raw images/nocloud-arm64.raw.zst

images: images/debian-12-generic-arm64.qcow2 images/talos-arm64-nocloud.qcow2

# --- VM disks (CoW backing) ---

vms: $(foreach node,$(NODES),disks/$(node).qcow2)

# Talos nodes back to the Talos base image.
# Each VM also gets a 64MB UEFI variable store (pflash1) for persistent
# UEFI settings. The code image (pflash0) is shared read-only.
disks/control-plane-1.qcow2: images/talos-arm64-nocloud.qcow2
	@mkdir -p disks
	qemu-img create -f qcow2 -b ../images/talos-arm64-nocloud.qcow2 -F qcow2 $@
	qemu-img resize $@ 20G
	truncate -s 64M disks/control-plane-1-vars.fd

disks/worker-1.qcow2: images/talos-arm64-nocloud.qcow2
	@mkdir -p disks
	qemu-img create -f qcow2 -b ../images/talos-arm64-nocloud.qcow2 -F qcow2 $@
	qemu-img resize $@ 20G
	truncate -s 64M disks/worker-1-vars.fd

disks/worker-2.qcow2: images/talos-arm64-nocloud.qcow2
	@mkdir -p disks
	qemu-img create -f qcow2 -b ../images/talos-arm64-nocloud.qcow2 -F qcow2 $@
	qemu-img resize $@ 20G
	truncate -s 64M disks/worker-2-vars.fd

# Upstream router backs to the Debian base image.
disks/upstream-router.qcow2: images/debian-12-generic-arm64.qcow2
	@mkdir -p disks
	qemu-img create -f qcow2 -b ../images/debian-12-generic-arm64.qcow2 -F qcow2 $@
	qemu-img resize $@ 20G
	truncate -s 64M disks/upstream-router-vars.fd

# --- Talos machine config generation ---

# Generate base controlplane.yaml, worker.yaml, and talosconfig from patches.
talos-gen: talos/generated/controlplane.yaml

talos/generated/controlplane.yaml:
	@mkdir -p talos/generated
	talosctl gen config $(CLUSTER_NAME) $(CLUSTER_ENDPOINT) \
		--kubernetes-version $(KUBERNETES_VERSION) \
		--output-dir talos/generated \
		--config-patch @talos/patches/common.yaml \
		--config-patch-control-plane @talos/patches/controlplane.yaml \
		--config-patch-worker @talos/patches/worker.yaml
	@# Patch talosconfig endpoints for QEMU NAT: the host reaches the Talos API
	@# through port-forwarded 127.0.0.1:50000 (maps to control-plane-1:50000).
	@# After bootstrap, talosctl proxies requests to workers through the control plane.
	@# Uses 127.0.0.1 (not localhost) to avoid IPv6 resolution issues.
	talosctl config endpoint 127.0.0.1:50000 --talosconfig $(TALOSCONFIG)
	talosctl config node $(MGMT_CP_IP) --talosconfig $(TALOSCONFIG)

# Merge per-node patches (hostname, MACs, IPs) into the base configs.
talos-configs: talos/generated/control-plane-1.yaml talos/generated/worker-1.yaml talos/generated/worker-2.yaml

talos/generated/control-plane-1.yaml: talos/generated/controlplane.yaml talos/patches/control-plane-1.yaml
	talosctl machineconfig patch $< --patch @talos/patches/control-plane-1.yaml --output $@

talos/generated/worker-1.yaml: talos/generated/worker.yaml talos/patches/worker-1.yaml
	talosctl machineconfig patch $< --patch @talos/patches/worker-1.yaml --output $@

talos/generated/worker-2.yaml: talos/generated/worker.yaml talos/patches/worker-2.yaml
	talosctl machineconfig patch $< --patch @talos/patches/worker-2.yaml --output $@

# --- Seed ISOs ---

# Talos nodes: machine config delivered as user-data on a CIDATA ISO.
# Talos machined (not cloud-init) reads this at first boot.
talos-seed: $(foreach node,$(TALOS_NODES),talos/generated/$(node)-seed.iso)

talos/generated/%-seed.iso: talos/generated/%.yaml
	@echo "Generating Talos seed ISO for $*..."
	@mkdir -p /tmp/talos-cidata-$*
	@cp $< /tmp/talos-cidata-$*/user-data
	@echo '{"instance-id": "$*", "local-hostname": "$*"}' > /tmp/talos-cidata-$*/meta-data
	mkisofs -output $@ -volid cidata -joliet -rock /tmp/talos-cidata-$*/
	@rm -rf /tmp/talos-cidata-$*

# Upstream router: standard cloud-init seed ISO (Debian).
cloud-init: cloud-init/upstream-router/seed.iso

cloud-init/upstream-router/seed.iso: cloud-init/upstream-router/user-data cloud-init/upstream-router/meta-data cloud-init/upstream-router/network-config
	@echo "Generating cloud-init ISO for upstream-router..."
	mkisofs -output $@ -volid cidata -joliet -rock \
		cloud-init/upstream-router/user-data cloud-init/upstream-router/meta-data cloud-init/upstream-router/network-config

# Umbrella target for all seed ISOs.
seed: talos-seed cloud-init

# --- Start VMs ---
#
# Two NICs per VM:
#   mgmt (user-mode NAT): host SSH/API/talosctl access via port forwarding.
#   internal (VDE switch): shared L2 segment for inter-VM traffic (BGP, pods).
# Stable MAC addresses let Talos/cloud-init bind NICs deterministically.

# Start VDE virtual switch before any VM. Provides the internal L2 segment.
vde-up:
	@if [ ! -S $(VDE_SOCK)/ctl ]; then \
		echo "Starting VDE switch..."; \
		$(VDE_SWITCH) -sock $(VDE_SOCK) -daemon -mod 700; \
	else \
		echo "VDE switch already running"; \
	fi

up: vde-up up-upstream up-control-plane-1 up-worker-1 up-worker-2

up-control-plane-1: disks/control-plane-1.qcow2 talos/generated/control-plane-1-seed.iso
	@echo "Starting control-plane-1 (Talos)..."
	$(QEMU) \
		-name control-plane-1 \
		-machine virt,gic-version=max,accel=hvf \
		-cpu max -smp 2 -m 4G \
		-drive file=$(FIRMWARE_CODE),format=raw,if=pflash,readonly=on \
		-drive file=disks/control-plane-1-vars.fd,format=raw,if=pflash \
		-drive file=disks/control-plane-1.qcow2,if=virtio,format=qcow2 \
		-drive file=talos/generated/control-plane-1-seed.iso,if=virtio,format=raw \
		-device virtio-rng-pci \
		-smbios type=11,value=io.systemd.stub.kernel-cmdline-extra=console=ttyS0 \
		-netdev user,id=mgmt,net=$(MGMT_NET),hostfwd=tcp::50000-$(MGMT_CP_IP):50000,hostfwd=tcp::6443-$(MGMT_CP_IP):6443 \
		-device virtio-net-pci,netdev=mgmt,mac=52:54:00:00:01:01 \
		-netdev vde,id=internal,sock=$(VDE_SOCK) \
		-device virtio-net-pci,netdev=internal,mac=52:54:00:00:02:01 \
		-pidfile /tmp/qemu-control-plane-1.pid \
		-daemonize -display none \
		-chardev socket,id=console,path=/tmp/qemu-control-plane-1.sock,server=on,wait=off \
		-serial chardev:console

up-worker-1: disks/worker-1.qcow2 talos/generated/worker-1-seed.iso
	@echo "Starting worker-1 (Talos)..."
	$(QEMU) \
		-name worker-1 \
		-machine virt,gic-version=max,accel=hvf \
		-cpu max -smp 2 -m 4G \
		-drive file=$(FIRMWARE_CODE),format=raw,if=pflash,readonly=on \
		-drive file=disks/worker-1-vars.fd,format=raw,if=pflash \
		-drive file=disks/worker-1.qcow2,if=virtio,format=qcow2 \
		-drive file=talos/generated/worker-1-seed.iso,if=virtio,format=raw \
		-device virtio-rng-pci \
		-smbios type=11,value=io.systemd.stub.kernel-cmdline-extra=console=ttyS0 \
		-netdev user,id=mgmt,net=$(MGMT_NET),hostfwd=tcp::50001-$(MGMT_W1_IP):50000 \
		-device virtio-net-pci,netdev=mgmt,mac=52:54:00:00:01:02 \
		-netdev vde,id=internal,sock=$(VDE_SOCK) \
		-device virtio-net-pci,netdev=internal,mac=52:54:00:00:02:02 \
		-pidfile /tmp/qemu-worker-1.pid \
		-daemonize -display none \
		-chardev socket,id=console,path=/tmp/qemu-worker-1.sock,server=on,wait=off \
		-serial chardev:console

up-worker-2: disks/worker-2.qcow2 talos/generated/worker-2-seed.iso
	@echo "Starting worker-2 (Talos)..."
	$(QEMU) \
		-name worker-2 \
		-machine virt,gic-version=max,accel=hvf \
		-cpu max -smp 2 -m 4G \
		-drive file=$(FIRMWARE_CODE),format=raw,if=pflash,readonly=on \
		-drive file=disks/worker-2-vars.fd,format=raw,if=pflash \
		-drive file=disks/worker-2.qcow2,if=virtio,format=qcow2 \
		-drive file=talos/generated/worker-2-seed.iso,if=virtio,format=raw \
		-device virtio-rng-pci \
		-smbios type=11,value=io.systemd.stub.kernel-cmdline-extra=console=ttyS0 \
		-netdev user,id=mgmt,net=$(MGMT_NET),hostfwd=tcp::50002-$(MGMT_W2_IP):50000 \
		-device virtio-net-pci,netdev=mgmt,mac=52:54:00:00:01:03 \
		-netdev vde,id=internal,sock=$(VDE_SOCK) \
		-device virtio-net-pci,netdev=internal,mac=52:54:00:00:02:03 \
		-pidfile /tmp/qemu-worker-2.pid \
		-daemonize -display none \
		-chardev socket,id=console,path=/tmp/qemu-worker-2.sock,server=on,wait=off \
		-serial chardev:console

up-upstream: disks/upstream-router.qcow2 cloud-init/upstream-router/seed.iso
	@echo "Starting upstream-router (Debian)..."
	$(QEMU) \
		-name upstream-router \
		-machine virt,gic-version=max,accel=hvf \
		-cpu max -smp 1 -m 512M \
		-drive file=$(FIRMWARE_CODE),format=raw,if=pflash,readonly=on \
		-drive file=disks/upstream-router-vars.fd,format=raw,if=pflash \
		-drive file=disks/upstream-router.qcow2,if=virtio,format=qcow2 \
		-drive file=cloud-init/upstream-router/seed.iso,if=virtio,format=raw \
		-device virtio-rng-pci \
		-netdev user,id=mgmt,net=$(MGMT_NET),hostfwd=tcp::2200-$(MGMT_UPSTREAM_IP):22 \
		-device virtio-net-pci,netdev=mgmt,mac=52:54:00:00:01:00 \
		-netdev vde,id=internal,sock=$(VDE_SOCK) \
		-device virtio-net-pci,netdev=internal,mac=52:54:00:00:02:00 \
		-pidfile /tmp/qemu-upstream-router.pid \
		-daemonize -display none \
		-serial unix:/tmp/qemu-upstream-router.sock,server,nowait

# --- Stop VMs ---

down:
	@for node in $(NODES); do \
		if [ -f /tmp/qemu-$$node.pid ]; then \
			echo "Stopping $$node..."; \
			kill $$(cat /tmp/qemu-$$node.pid) 2>/dev/null || true; \
			rm -f /tmp/qemu-$$node.pid /tmp/qemu-$$node.sock; \
		fi \
	done
	@if [ -S $(VDE_SOCK)/ctl ]; then \
		echo "Stopping VDE switch..."; \
		kill $$(lsof -t $(VDE_SOCK)/ctl 2>/dev/null) 2>/dev/null || true; \
		rm -rf $(VDE_SOCK); \
	fi

# --- VM status ---

status:
	@for node in $(NODES); do \
		if [ -f /tmp/qemu-$$node.pid ] && kill -0 $$(cat /tmp/qemu-$$node.pid) 2>/dev/null; then \
			echo "$$node: running (PID $$(cat /tmp/qemu-$$node.pid))"; \
		else \
			echo "$$node: stopped"; \
		fi \
	done

# --- Cluster lifecycle ---

# Initialize etcd and the Kubernetes control plane. Run once on first setup.
# Endpoint (127.0.0.1:50000) and default node are set in talosconfig.
bootstrap:
	TALOSCONFIG=$(TALOSCONFIG) talosctl bootstrap

# Fetch kubeconfig into a temp file, rewrite the API server endpoint to the
# host-accessible port forward, then merge into the default kubeconfig.
# Safe for multi-cluster setups: only the k8s-lab context is added/updated.
kubeconfig:
	TALOSCONFIG=$(TALOSCONFIG) talosctl kubeconfig talos/generated/kubeconfig --force
	kubectl config set-cluster k8s-lab --server=https://127.0.0.1:6443 \
		--kubeconfig talos/generated/kubeconfig
	KUBECONFIG=talos/generated/kubeconfig:$$HOME/.kube/config \
		kubectl config view --flatten > $$HOME/.kube/config.tmp
	mv $$HOME/.kube/config.tmp $$HOME/.kube/config
	kubectl config use-context admin@k8s-lab
	@echo "Merged k8s-lab context into ~/.kube/config"

# Install Cilium CNI with eBPF datapath, kube-proxy replacement, and BGP.
cilium-install:
	helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
	helm repo update
	helm install cilium cilium/cilium \
		--version 1.19.4 \
		--namespace kube-system \
		-f manifests/cilium-values.yaml

# Deploy FRR as a privileged pod on control-plane-1 for BGP route reflection.
# Uses hostNetwork — no CNI dependency. Peers with upstream-router (eBGP) and
# workers (iBGP).
frr-rr:
	kubectl apply -f manifests/frr-route-reflector.yaml

# Configure Cilium BGP on worker nodes: iBGP peering with the FRR Route
# Reflector on control-plane-1.
cilium-bgp:
	kubectl apply -f manifests/cilium-bgp.yaml

# --- Access & debugging ---

# SSH to upstream router (only Debian VM; Talos nodes have no SSH).
ssh-upstream:
	ssh -p 2200 k8s@localhost

# Serial console via QEMU Unix socket. Works for all VMs including Talos
# (shows boot messages, maintenance mode prompts).
console-%:
	socat -,raw,echo=0 unix-connect:/tmp/qemu-$*.sock

# Interactive Talos dashboard across all Kubernetes nodes.
# After bootstrap, the control plane proxies requests to workers.
talos-dashboard:
	TALOSCONFIG=$(TALOSCONFIG) talosctl dashboard \
		-n $(MGMT_CP_IP),fd00:100::11,fd00:100::12

# Verify cluster health: etcd, kubelet, and node readiness.
# Worker IPs use the internal network (fd00:100::/64) since SLIRP IPs are
# per-VM isolated NAT — the control plane can only reach workers via VDE.
talos-health:
	TALOSCONFIG=$(TALOSCONFIG) talosctl health \
		--control-plane-nodes fd00:100::10 \
		--worker-nodes fd00:100::11,fd00:100::12

# --- Cleanup ---

clean:
	rm -rf disks/ cloud-init/upstream-router/seed.iso talos/generated/

nuke: clean
	rm -rf images/
