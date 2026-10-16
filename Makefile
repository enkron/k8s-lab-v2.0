# k8s-lab v2.0 - Talos Linux + Debian hybrid
#
# Kubernetes nodes (control-plane-1, worker-1, worker-2) run Talos Linux.
# Upstream router runs Debian 13 with FRR for BGP edge routing (installed by cloud-init).
# All VMs use QEMU aarch64 with HVF acceleration on Apple Silicon.
#
# 'make help' lists the targets: a '## text' after a target documents it and a line starting
# with '##@ Name' opens a section. Requires GNU Make 4.x (grouped targets, .SHELLFLAGS).
# tests/ and CI read pinned versions with 'make -s print-<VAR>' (see print-%).

# Grouped targets (&:) below are parse errors on the macOS system make (3.81); fail early with a
# hint. Keep this the first statement in the file.
ifeq ($(filter 4.% 5.%,$(MAKE_VERSION)),)
$(error GNU Make >= 4.x is required (found $(MAKE_VERSION)); add nixpkgs gnumake to the profile)
endif

# --- Global settings ---

# -r/-R: no builtin rules or variables (this is not a C build). --warn-undefined-variables catches
# typos in the per-node lookups ($(MEM_$*) and friends); it applies from this line on, so data is
# defined before it is referenced. GNUMAKEFLAGS is read by make itself before it is set, which
# would trip that warning in every sub-make (tests/ call 'make -s print-<VAR>'); define it empty.
GNUMAKEFLAGS ?=
MAKEFLAGS += --no-builtin-rules --no-builtin-variables --warn-undefined-variables
# -R resets .SHELLFLAGS to '-c', so set both explicitly. bash rather than sh: 'make test' also runs
# on Linux CI runners where /bin/sh is dash, which has no pipefail. /bin/bash exists on macOS
# (3.2) and Ubuntu. -e: a recipe line stops at its first failing command; -u: an unset $VAR is an
# error; pipefail: a failing producer fails the pipeline.
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
# Remove a target if its recipe fails, so a truncated download or a half-written config is not
# mistaken for a complete artifact on the next run. Applies to every member of a grouped target.
.DELETE_ON_ERROR:

# --- Tools ---
# Override on the command line or in the environment, e.g. 'make QEMU=/path/to/qemu up'.

QEMU     ?= qemu-system-aarch64
QEMU_IMG ?= qemu-img
KUBECTL  ?= kubectl
HELM     ?= helm
MKISOFS  ?= mkisofs
ZSTD     ?= zstd
SOCAT    ?= socat
CURL     ?= curl
JQ       ?= jq
# shasum ships with macOS (perl) and Ubuntu; sha512sum is not on macOS without coreutils.
SHASUM   ?= shasum
# talosctl binary. The machine config patches use Talos 1.14 multi-document kinds, so the client
# must not be older than TALOS_VERSION (checked by 'make check-tools'). Exported because tests/
# fall back to it: TALOSCTL=${TALOSCTL:-$(make -s print-TALOSCTL)}.
TALOSCTL ?= talosctl
export TALOSCTL
# -f: treat HTTP errors as failures (never save an error page as an image).
# --retry-all-errors: cloud.debian.org redirects to regional mirrors that intermittently drop the
# connection (curl exit 52); retry those too.
CURL_FLAGS ?= -fL --retry 5 --retry-delay 5 --retry-all-errors

# EDK2 AAVMF: UEFI firmware for aarch64 (ARM has no BIOS fallback). Used as pflash, not -bios:
# separate read-only code and a per-VM variable store. -bios does not persist UEFI variables on
# ARM and caused hangs with Talos v1.12+. The firmware comes from the same qemu package as the
# emulator on PATH (resolve the profile symlink, go up from bin/, append share/qemu/), so the two
# cannot drift apart. Recursive (=) so the lookup only runs when a recipe expands it.
qemu-path     = $(or $(realpath $(shell command -v $(QEMU))),$(error '$(QEMU)' not found on PATH))
QEMU_PREFIX   = $(abspath $(dir $(qemu-path))..)
FIRMWARE_CODE ?= $(QEMU_PREFIX)/share/qemu/edk2-aarch64-code.fd

# VDE (Virtual Distributed Ethernet) switch provides the internal L2 segment. QEMU's built-in
# multicast socket (-netdev socket,mcast=) is broken on macOS: the kernel ignores
# IP_MULTICAST_LOOP=0 semantics and drops all local delivery. VDE is a userspace switch: no root,
# no entitlements. vde_switch is not in the nix profile: use PATH when present, otherwise resolve
# it through nix, lazily and once per make run (the $(eval) turns VDE_SWITCH into a simple variable
# on first use), so help/status/clean never pay for a nix evaluation. '\#' reaches the shell
# unchanged on make >= 4.3 (which quotes it) and as '#' on older 4.x; both spell nixpkgs#vde2.
nix-vde2        = $(shell nix build nixpkgs\#vde2 --print-out-paths --no-link)
find-vde_switch = $(or $(shell command -v vde_switch),$(nix-vde2)/bin/vde_switch)
VDE_SWITCH     ?= $(eval VDE_SWITCH := $(find-vde_switch))$(VDE_SWITCH)

# --- Versions ---
# Read by tests/ and CI through 'make -s print-<VAR>'; keep the names and value formats.

# Cluster version triad - pinned together because they move as a tested set: Talos v1.14.0
# defaults to K8s 1.37.0, but stable Cilium (1.20.x) is only e2e-tested up to K8s 1.36, so K8s is
# held at 1.36.x. Keep all three within Cilium's supported window before bumping any one of them.
TALOS_VERSION      := v1.14.0
KUBERNETES_VERSION := 1.36.4
# CILIUM_VERSION pins the Helm chart (resolved against the repo index at install time), unlike
# TALOS_VERSION and KUBERNETES_VERSION which bake into the generated machine configs.
CILIUM_VERSION := 1.20.1
# FRR_VERSION pins the Route Reflector pod image. manifests/frr-route-reflector.yaml must carry
# the same tag and a matching 'frr version' header; tests/check-versions.sh enforces both.
# FRR_ROUTER_VERSION is the FRR release the upstream router gets from its Debian release via apt
# (not chosen here); the matching quay.io tag is used only to dry-run the router's frr.conf in
# tests/validate-frr.sh.
FRR_VERSION        := 10.7.1
FRR_ROUTER_VERSION := 10.3.4
# Debian release for the upstream router. Codename and major version describe the same release
# (13 == trixie); keep them in step. The cloud image is pinned to a dated build and verified
# against its SHA-512 ('make deps-bump DEPS=debian-image' moves both together); 'latest/' would
# change under a lab that is rebuilt from the same commit.
DEBIAN_RELEASE      := trixie
DEBIAN_VERSION      := 13
DEBIAN_IMAGE_BUILD  := 20261015-2632
DEBIAN_IMAGE_SHA512 := a34e1c1eea1fbb9ad31ebdfc6c776d1d579ce9e3d740ab10549ebcdca6fe1a46c28e0a42cbcdf1eb561795776733c178f6e816fe1a2cb60d26ffc56c07f915c4
DEBIAN_IMAGE_URL    := https://cloud.debian.org/images/cloud/$(DEBIAN_RELEASE)/$(DEBIAN_IMAGE_BUILD)/debian-$(DEBIAN_VERSION)-generic-arm64-$(DEBIAN_IMAGE_BUILD).qcow2
# Default schematic (no extensions) from Talos Image Factory. The nocloud variant reads machine
# config from a CIDATA ISO at boot.
TALOS_SCHEMATIC := 376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba
TALOS_IMAGE_URL := https://factory.talos.dev/image/$(TALOS_SCHEMATIC)/$(TALOS_VERSION)/nocloud-arm64.raw.zst
# Installer image for first boot and for 'talosctl upgrade --image'. Image Factory installers are
# platform-specific (<platform>-installer); the VMs boot the nocloud image, so the nocloud
# installer matches. ghcr.io/siderolabs/installer is no longer published since Talos 1.14.
TALOS_INSTALLER_IMAGE := factory.talos.dev/nocloud-installer/$(TALOS_SCHEMATIC):$(TALOS_VERSION)

# --- Node inventory ---

TALOS_CP_NODES     := control-plane-1
TALOS_WORKER_NODES := worker-1 worker-2
TALOS_NODES        := $(TALOS_CP_NODES) $(TALOS_WORKER_NODES)
DEBIAN_NODES       := upstream-router
NODES              := $(TALOS_NODES) $(DEBIAN_NODES)

# Two NICs per VM:
#   mgmt (QEMU user-mode NAT): host SSH/API/talosctl access via port forwarding. SLIRP networks
#     are isolated per VM, so VMs cannot reach each other over them.
#   internal (VDE switch): shared L2 segment for inter-VM traffic (BGP, pods).
# Stable MAC addresses let Talos/cloud-init bind NICs deterministically. The same MACs and IPs
# appear in talos/patches/<node>.yaml and cloud-init/upstream-router/network-config; keep them in
# sync.
MGMT_NET       := 192.168.100.0/24
TALOS_API_PORT := 50000
K8S_API_PORT   := 6443
SSH_PORT       := 2200
SSH_USER       := k8s
# Host address the port forwards listen on. Loopback only: an empty address makes QEMU listen on
# every interface, which puts the Talos API (unauthenticated while a node sits in maintenance
# mode), the Kubernetes API and router SSH on the LAN. talosconfig, kubeconfig and the API
# certificate SANs all use 127.0.0.1. For access from another machine prefer an SSH tunnel to
# this host; HOSTFWD_ADDR=0.0.0.0 opts back into listening everywhere.
HOSTFWD_ADDR ?= 127.0.0.1
# HOSTFWD_<node>: space-separated QEMU hostfwd specs, joined with commas at launch; empty for none.

SMP_upstream-router          := 1
MEM_upstream-router          := 512M
MAC_MGMT_upstream-router     := 52:54:00:00:01:00
MAC_INTERNAL_upstream-router := 52:54:00:00:02:00
IP_MGMT_upstream-router      := 192.168.100.13
HOSTFWD_upstream-router      := hostfwd=tcp:$(HOSTFWD_ADDR):$(SSH_PORT)-$(IP_MGMT_upstream-router):22

SMP_control-plane-1          := 2
MEM_control-plane-1          := 4G
MAC_MGMT_control-plane-1     := 52:54:00:00:01:01
MAC_INTERNAL_control-plane-1 := 52:54:00:00:02:01
IP_MGMT_control-plane-1      := 192.168.100.10
IP_INTERNAL_control-plane-1  := fd00:100::10
HOSTFWD_control-plane-1      := hostfwd=tcp:$(HOSTFWD_ADDR):$(TALOS_API_PORT)-$(IP_MGMT_control-plane-1):50000 \
                                hostfwd=tcp:$(HOSTFWD_ADDR):$(K8S_API_PORT)-$(IP_MGMT_control-plane-1):6443

SMP_worker-1          := 2
MEM_worker-1          := 4G
MAC_MGMT_worker-1     := 52:54:00:00:01:02
MAC_INTERNAL_worker-1 := 52:54:00:00:02:02
IP_MGMT_worker-1      := 192.168.100.11
IP_INTERNAL_worker-1  := fd00:100::11
# No forwards on the workers: talosctl reaches them through control-plane-1 (internal IPs). To
# debug a worker that never joined, use its serial console (make console-<node>).
HOSTFWD_worker-1      :=

SMP_worker-2          := 2
MEM_worker-2          := 4G
MAC_MGMT_worker-2     := 52:54:00:00:01:03
MAC_INTERNAL_worker-2 := 52:54:00:00:02:03
IP_MGMT_worker-2      := 192.168.100.12
IP_INTERNAL_worker-2  := fd00:100::12
HOSTFWD_worker-2      :=

# --- Cluster ---

CLUSTER_NAME := k8s-lab
# Workers reach the API server over the internal network (fd00:100::/64), not through SLIRP
# management IPs (isolated per-VM NAT).
CLUSTER_ENDPOINT    := https://[$(IP_INTERNAL_control-plane-1)]:$(K8S_API_PORT)
CP_INTERNAL_IPS     := $(foreach n,$(TALOS_CP_NODES),$(IP_INTERNAL_$(n)))
WORKER_INTERNAL_IPS := $(foreach n,$(TALOS_WORKER_NODES),$(IP_INTERNAL_$(n)))
DISK_SIZE := 20G
# Per-VM UEFI variable store (pflash1); the code image (pflash0) is shared read-only.
VARS_SIZE := 64M

# --- Paths and generated files ---

IMAGE_DIR       := images
DISK_DIR        := disks
TALOS_PATCH_DIR := talos/patches
TALOS_GEN_DIR   := talos/generated
CLOUD_INIT_DIR  := cloud-init
MANIFEST_DIR    := manifests
TEST_DIR        := tests
SCRIPT_DIR      := scripts
# Pidfiles, serial console sockets and the VDE control socket. Kept short because unix socket
# paths are limited to 104 bytes on macOS; cleared on reboot together with the VMs.
RUN_DIR ?= /tmp/$(CLUSTER_NAME)
DIRS := $(IMAGE_DIR)/ $(DISK_DIR)/ $(TALOS_GEN_DIR)/ $(RUN_DIR)/

# The Debian build and the Talos version are part of the filenames so a bump downloads a new image
# instead of silently reusing the old one.
DEBIAN_IMAGE  := $(IMAGE_DIR)/debian-$(DEBIAN_VERSION)-generic-arm64-$(DEBIAN_IMAGE_BUILD).qcow2
TALOS_IMAGE   := $(IMAGE_DIR)/talos-$(TALOS_VERSION)-nocloud-arm64.qcow2
TALOS_RAW     := $(TALOS_IMAGE:.qcow2=.raw)
TALOS_RAW_ZST := $(TALOS_RAW).zst

DISKS := $(NODES:%=$(DISK_DIR)/%.qcow2)
VARS  := $(NODES:%=$(DISK_DIR)/%-vars.fd)

TALOS_SECRETS      := $(TALOS_GEN_DIR)/secrets.yaml
TALOS_BASE_CONFIGS := $(TALOS_GEN_DIR)/controlplane.yaml $(TALOS_GEN_DIR)/worker.yaml
TALOSCONFIG        := $(TALOS_GEN_DIR)/talosconfig
# Exported so every talosctl invocation in a recipe picks it up.
export TALOSCONFIG
TALOS_NODE_CONFIGS := $(TALOS_NODES:%=$(TALOS_GEN_DIR)/%.yaml)
TALOS_META_DATA    := $(TALOS_NODES:%=$(TALOS_GEN_DIR)/%.meta-data)
TALOS_SEEDS        := $(TALOS_NODES:%=$(TALOS_GEN_DIR)/%-seed.iso)
CLOUD_INIT_SEED    := $(CLOUD_INIT_DIR)/upstream-router/seed.iso
# Not KUBECONFIG: a make variable of that name would be exported over the user's own setting.
# tests/e2e.sh defaults to this path.
KUBECONFIG_FILE    := $(TALOS_GEN_DIR)/kubeconfig
HUBBLE_CA_FILE     := $(TALOS_GEN_DIR)/hubble-ca.crt

VDE_CTL  := $(RUN_DIR)/vde.ctl
VDE_PID  := $(RUN_DIR)/vde.pid
PIDFILES := $(NODES:%=$(RUN_DIR)/%.pid)

# How long the cluster lifecycle targets wait for an API to come up, in seconds. Talos needs ~90s
# from 'make up' to serve its API, kube-apiserver another minute or two after bootstrap.
WAIT_TIMEOUT ?= 300
# $(call wait-for,<what>,<command>): recipe line that retries <command> every 5s until it succeeds
# or WAIT_TIMEOUT runs out. Each attempt is bounded by the command's own timeout. The QEMU port
# forwards accept TCP before the guest listens, so only a real API call proves readiness, not a
# port check. <command> must not contain a comma ($(call) splits on them).
define wait-for
@echo "Waiting for $(1) (up to $(WAIT_TIMEOUT)s)..."; \
	until $(2) >/dev/null 2>&1; do \
		[ $$SECONDS -lt $(WAIT_TIMEOUT) ] \
			|| { echo "$(1): not ready after $(WAIT_TIMEOUT)s; check 'make status', 'make console-<node>'" >&2; exit 1; }; \
		sleep 5; \
	done; \
	echo "$(1): ready"
endef

empty :=
space := $(empty) $(empty)
comma := ,
# $(call join-comma,<list>): "a b c" -> "a,b,c"
join-comma = $(subst $(space),$(comma),$(strip $(1)))

##@ General

.PHONY: help
help: ## Show this help
	@awk 'BEGIN { FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n" } \
	  /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next } \
	  /^(\$$\([^)]*\): )?[a-zA-Z0-9_][a-zA-Z0-9_%.-]*:.*##/ \
	    { sub(/^\$$\([^)]*\): /, ""); printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 }' \
	  $(MAKEFILE_LIST)

# Print a Makefile variable: 'make -s print-TALOS_VERSION'. Used by tests/ and CI so the Makefile
# stays the single source of truth for versions.
print-%: ## Print a Makefile variable (make -s print-<VAR>)
	@echo '$($*)'

# The patches in talos/patches/ use Talos 1.14 multi-document kinds (KubeNetworkConfig,
# KubeNodeConfig, ...). An older talosctl does not know them and fails with "not registered". A
# newer client is fine: --talos-version pins the generated layout. The '|| true' inside the
# substitutions keep a missing binary on the friendly-message path under pipefail.
.PHONY: check-tools
check-tools: ## Verify talosctl >= TALOS_VERSION, kubectl version skew, cilium-cli present
	@have=$$({ $(TALOSCTL) version --client 2>/dev/null || true; } \
		| sed -n 's/^[[:space:]]*Tag:[[:space:]]*v*//p' | head -1 || true); \
	[ -n "$$have" ] || { echo "check-tools: cannot run '$(TALOSCTL) version' (set TALOSCTL=/path/to/talosctl)" >&2; exit 1; }; \
	want=$(TALOS_VERSION:v%=%); \
	hm=$${have%%.*}; hn=$${have#*.}; hn=$${hn%%.*}; \
	wm=$${want%%.*}; wn=$${want#*.}; wn=$${wn%%.*}; \
	if [ "$$hm" -lt "$$wm" ] || { [ "$$hm" -eq "$$wm" ] && [ "$$hn" -lt "$$wn" ]; }; then \
		echo "check-tools: talosctl v$$have is older than TALOS_VERSION $(TALOS_VERSION);" \
		     "it cannot parse the Talos 1.14 multi-document patches. Install talosctl >= $(TALOS_VERSION)" \
		     "(nixpkgs override or release binary) or run make with TALOSCTL=/path/to/talosctl." >&2; \
		exit 1; \
	elif [ "$$hm" -ne "$$wm" ] || [ "$$hn" -ne "$$wn" ]; then \
		echo "check-tools: warning: talosctl v$$have is newer than TALOS_VERSION $(TALOS_VERSION)"; \
	else \
		echo "check-tools: talosctl v$$have matches TALOS_VERSION"; \
	fi
	@kminor=$$({ $(KUBECTL) version --client -o json 2>/dev/null || true; } \
		| $(JQ) -r '.clientVersion.minor' 2>/dev/null | tr -dc 0-9 || true); \
	want=$(KUBERNETES_VERSION); wn=$${want#*.}; wn=$${wn%%.*}; \
	if [ -z "$$kminor" ]; then echo "check-tools: warning: kubectl not found"; \
	elif [ $$((kminor - wn)) -gt 1 ] || [ $$((wn - kminor)) -gt 1 ]; then \
		echo "check-tools: warning: kubectl 1.$$kminor is more than one minor away from Kubernetes $(KUBERNETES_VERSION)"; \
	else echo "check-tools: kubectl 1.$$kminor is within one minor of Kubernetes $(KUBERNETES_VERSION)"; fi
	@command -v cilium >/dev/null 2>&1 && echo "check-tools: cilium-cli found" \
		|| echo "check-tools: warning: cilium-cli not found (needed by make test-e2e)"

##@ Infrastructure

.PHONY: images vms
images: $(DEBIAN_IMAGE) $(TALOS_IMAGE) ## Download base VM images (Debian + Talos)

# Debian cloud image for the upstream router. A digest mismatch fails the recipe, and
# .DELETE_ON_ERROR removes the file so the next run downloads it again.
$(DEBIAN_IMAGE): | $(IMAGE_DIR)/
	$(CURL) $(CURL_FLAGS) -o $@ $(DEBIAN_IMAGE_URL)
	echo '$(DEBIAN_IMAGE_SHA512)  $@' | $(SHASUM) -a 512 -c -

# Talos nocloud image: zstd-compressed raw from Image Factory -> raw -> qcow2. Make deletes the
# intermediates after a successful conversion and does not re-download them while the qcow2 exists.
.INTERMEDIATE: $(TALOS_RAW_ZST) $(TALOS_RAW)
$(TALOS_RAW_ZST): | $(IMAGE_DIR)/
	$(CURL) $(CURL_FLAGS) -o $@ $(TALOS_IMAGE_URL)
$(TALOS_RAW): $(TALOS_RAW_ZST)
	$(ZSTD) -d -f $< -o $@
$(TALOS_IMAGE): $(TALOS_RAW)
	$(QEMU_IMG) convert -f raw -O qcow2 $< $@

vms: $(DISKS) $(VARS) ## Create per-node CoW disks and UEFI variable stores

# Each node disk is a CoW overlay on its class's base image. The base image is an order-only
# prerequisite on purpose: an overlay must never be recreated because a newer base appeared (that
# destroys the node; Talos upgrades happen in place with 'talosctl upgrade'). After a version
# bump, 'make images' fetches the new base and 'make clean vms' rebuilds the disks on it.
$(TALOS_NODES:%=$(DISK_DIR)/%.qcow2):  BASE_IMAGE := $(TALOS_IMAGE)
$(TALOS_NODES:%=$(DISK_DIR)/%.qcow2):  | $(TALOS_IMAGE)
$(DEBIAN_NODES:%=$(DISK_DIR)/%.qcow2): BASE_IMAGE := $(DEBIAN_IMAGE)
$(DEBIAN_NODES:%=$(DISK_DIR)/%.qcow2): | $(DEBIAN_IMAGE)

# qcow2 stores the backing path relative to the overlay, hence ../ (DISK_DIR is one level deep).
$(DISKS): $(DISK_DIR)/%.qcow2: | $(DISK_DIR)/
	$(QEMU_IMG) create -f qcow2 -b ../$(BASE_IMAGE) -F qcow2 $@
	$(QEMU_IMG) resize $@ $(DISK_SIZE)

# Sparse and zero-filled, the same file 'truncate -s' produced before.
$(VARS): $(DISK_DIR)/%-vars.fd: | $(DISK_DIR)/
	$(QEMU_IMG) create -f raw $@ $(VARS_SIZE)

# Directory targets carry a trailing slash so they never collide with a phony target of the same
# name ('images'); make treats 'images/' and 'images' as different targets.
$(DIRS):
	mkdir -p $@

##@ Talos config

.PHONY: talos-gen talos-configs
# check-tools first: an old talosctl cannot parse the multi-document patches.
talos-gen: check-tools $(TALOS_BASE_CONFIGS) $(TALOSCONFIG) ## Generate base Talos machine configs and talosconfig

# Secrets bundle (PKI, tokens). Generated once and never regenerated automatically: a new bundle
# is a new PKI, existing nodes stop trusting configs derived from it and talosconfig stops
# working. 'make clean' keeps it; 'make nuke' removes it. The guard protects a cluster whose
# configs predate this file: import its PKI instead of minting a new one.
$(TALOS_SECRETS): | $(TALOS_GEN_DIR)/
	@if [ -e $(TALOS_GEN_DIR)/controlplane.yaml ]; then \
		echo "$@ is missing but $(TALOS_GEN_DIR)/controlplane.yaml exists." >&2; \
		echo "Import the existing PKI first (or 'make nuke' to start over):" >&2; \
		echo "  $(TALOSCTL) gen secrets --from-controlplane-config \
$(TALOS_GEN_DIR)/controlplane.yaml -o $@" >&2; \
		exit 1; \
	fi
	$(TALOSCTL) gen secrets --output-file $@

# One talosctl run writes all three files (grouped target). With --with-secrets the output is a
# pure function of secrets + patches + versions, so it can safely depend on them. --force is
# required because talosctl refuses to overwrite existing files. --talos-version pins the
# multi-document layout of the generated config to the pinned Talos release even when a newer
# talosctl is installed; --install-image pins the installer to TALOS_INSTALLER_IMAGE (the default
# follows the talosctl client's version). tests/validate-talos.sh mirrors this invocation.
$(TALOS_BASE_CONFIGS) $(TALOSCONFIG) &: $(TALOS_SECRETS) \
    $(addprefix $(TALOS_PATCH_DIR)/,common.yaml controlplane.yaml worker.yaml) | $(TALOS_GEN_DIR)/
	$(TALOSCTL) gen config $(CLUSTER_NAME) $(CLUSTER_ENDPOINT) \
		--with-secrets $(TALOS_SECRETS) \
		--talos-version $(TALOS_VERSION) \
		--kubernetes-version $(KUBERNETES_VERSION) \
		--install-image $(TALOS_INSTALLER_IMAGE) \
		-o $(TALOS_GEN_DIR) --force \
		--config-patch @$(TALOS_PATCH_DIR)/common.yaml \
		--config-patch-control-plane @$(TALOS_PATCH_DIR)/controlplane.yaml \
		--config-patch-worker @$(TALOS_PATCH_DIR)/worker.yaml
	@# talosconfig endpoint for QEMU NAT: the host reaches the Talos API through the forwarded
	@# 127.0.0.1:50000 (control-plane-1); after bootstrap talosctl proxies requests to workers
	@# through it. 127.0.0.1 rather than localhost avoids IPv6 resolution surprises.
	$(TALOSCTL) config endpoint 127.0.0.1:$(TALOS_API_PORT)
	$(TALOSCTL) config node $(IP_MGMT_control-plane-1)

talos-configs: $(TALOS_NODE_CONFIGS) ## Patch per-node identity (MACs, IPs, hostname) into node configs

# Control-plane nodes derive from controlplane.yaml, workers from worker.yaml. $(filter) picks the
# base and the patch out of $^ so the order of the prerequisite lines does not matter.
$(TALOS_CP_NODES:%=$(TALOS_GEN_DIR)/%.yaml):     $(TALOS_GEN_DIR)/controlplane.yaml
$(TALOS_WORKER_NODES:%=$(TALOS_GEN_DIR)/%.yaml): $(TALOS_GEN_DIR)/worker.yaml
$(TALOS_NODE_CONFIGS): $(TALOS_GEN_DIR)/%.yaml: $(TALOS_PATCH_DIR)/%.yaml
	$(TALOSCTL) machineconfig patch $(filter $(TALOS_GEN_DIR)/%,$^) \
		--patch @$(filter $(TALOS_PATCH_DIR)/%,$^) --output $@

##@ Seed ISOs

.PHONY: seed talos-seed cloud-init
seed: talos-seed cloud-init ## Build all seed ISOs (Talos + cloud-init)
talos-seed: $(TALOS_SEEDS) ## Build CIDATA ISOs for Talos nodes (machine config as user-data)
cloud-init: $(CLOUD_INIT_SEED) ## Build the cloud-init seed ISO for upstream-router

# The per-node HostnameConfig has priority; the nocloud meta-data local-hostname is a fallback.
$(TALOS_META_DATA): $(TALOS_GEN_DIR)/%.meta-data: | $(TALOS_GEN_DIR)/
	printf '{"instance-id": "%s", "local-hostname": "%s"}\n' $* $* > $@

# Talos machined (not cloud-init) reads the machine config as user-data from a CIDATA volume.
# -graft-points stores each source under the name the guest expects: no staging directory.
$(TALOS_SEEDS): $(TALOS_GEN_DIR)/%-seed.iso: $(TALOS_GEN_DIR)/%.yaml $(TALOS_GEN_DIR)/%.meta-data
	$(MKISOFS) -output $@ -volid cidata -joliet -rock -graft-points \
		user-data=$(filter %.yaml,$^) meta-data=$(filter %.meta-data,$^)

# Upstream router: standard cloud-init seed ISO (Debian).
$(CLOUD_INIT_SEED): $(addprefix $(CLOUD_INIT_DIR)/upstream-router/,user-data meta-data network-config)
	$(MKISOFS) -output $@ -volid cidata -joliet -rock $^

##@ VM lifecycle

.PHONY: vde-up vde-down
vde-up: $(VDE_PID) ## Start the VDE switch (internal L2 segment)
	@kill -0 "$$(cat $<)" 2>/dev/null \
		|| { echo "vde: stale pidfile $<, run 'make vde-down' and retry" >&2; exit 1; }

# vde_switch daemonizes with daemon(3); the parent may return before the control socket exists,
# so wait briefly for it before any VM tries to connect.
$(VDE_PID): | $(RUN_DIR)/
	@echo "Starting VDE switch..."
	$(VDE_SWITCH) --sock $(VDE_CTL) --mode 700 --daemon --pidfile $@
	@for i in 1 2 3 4 5 6 7 8 9 10; do [ -S $(VDE_CTL)/ctl ] && exit 0; sleep 0.2; done; \
		echo "vde: $(VDE_CTL)/ctl did not appear" >&2; kill "$$(cat $@)" 2>/dev/null || true; exit 1

.PHONY: up $(NODES:%=up-%)
up: $(DEBIAN_NODES:%=up-%) $(TALOS_NODES:%=up-%) ## Start the VDE switch and all VMs (no-op for VMs already running)

# The pidfile is the artifact: a running VM makes its up-<node> a no-op, a failed launch leaves no
# pidfile (.DELETE_ON_ERROR), and 'make -j up' is safe because the switch is an order-only
# prerequisite of every VM. The alias only checks that the pid is alive.
$(NODES:%=up-%): up-%: $(RUN_DIR)/%.pid ## Start one VM (up-<node>)
	@kill -0 "$$(cat $<)" 2>/dev/null && echo "$*: running (PID $$(cat $<))" \
		|| { echo "$*: stale pidfile $<, run 'make down-$*' and retry" >&2; exit 1; }

# Class-specific prerequisites and flags. Static pattern rules mention every pidfile and seed ISO
# explicitly, which restricts the rule to known nodes and keeps make from treating the files as
# deletable intermediates.
$(TALOS_NODES:%=$(RUN_DIR)/%.pid):  $(RUN_DIR)/%.pid: | $(TALOS_GEN_DIR)/%-seed.iso
$(DEBIAN_NODES:%=$(RUN_DIR)/%.pid): $(RUN_DIR)/%.pid: | $(CLOUD_INIT_DIR)/%/seed.iso
# Talos v1.12+ boots via systemd-stub, which takes the console from SMBIOS, not the kernel cmdline.
$(TALOS_NODES:%=$(RUN_DIR)/%.pid):  SMBIOS := -smbios type=11,value=io.systemd.stub.kernel-cmdline-extra=console=ttyS0
$(DEBIAN_NODES:%=$(RUN_DIR)/%.pid): SMBIOS :=

# Every prerequisite is order-only on purpose: a running VM keeps writing its disk and UEFI
# variable store, so a timestamp dependency would try to relaunch a live VM.
$(PIDFILES): $(RUN_DIR)/%.pid: | $(DISK_DIR)/%.qcow2 $(DISK_DIR)/%-vars.fd $(RUN_DIR)/ $(VDE_PID)
	@echo "Starting $*..."
	$(QEMU) \
		-name $* \
		-machine virt,gic-version=max,accel=hvf \
		-cpu max -smp $(SMP_$*) -m $(MEM_$*) \
		-drive file=$(FIRMWARE_CODE),format=raw,if=pflash,readonly=on \
		-drive file=$(DISK_DIR)/$*-vars.fd,format=raw,if=pflash \
		-drive file=$(DISK_DIR)/$*.qcow2,if=virtio,format=qcow2 \
		-drive file=$(filter %.iso,$|),if=virtio,format=raw \
		-device virtio-rng-pci \
		$(SMBIOS) \
		-netdev user,id=mgmt,net=$(MGMT_NET)$(addprefix $(comma),$(call join-comma,$(HOSTFWD_$*))) \
		-device virtio-net-pci,netdev=mgmt,mac=$(MAC_MGMT_$*) \
		-netdev vde,id=internal,sock=$(VDE_CTL) \
		-device virtio-net-pci,netdev=internal,mac=$(MAC_INTERNAL_$*) \
		-pidfile $@ \
		-daemonize -display none \
		-chardev socket,id=console,path=$(RUN_DIR)/$*.sock,server=on,wait=off \
		-serial chardev:console

.PHONY: down $(NODES:%=down-%)
down: vde-down ## Stop all VMs (SIGTERM = power off), then the VDE switch

$(NODES:%=down-%): down-%: ## Stop one VM (down-<node>); also clears a stale pidfile and socket
	@if [ -f $(RUN_DIR)/$*.pid ]; then \
		echo "Stopping $*..."; kill "$$(cat $(RUN_DIR)/$*.pid)" 2>/dev/null || true; \
	fi
	@rm -f $(RUN_DIR)/$*.pid $(RUN_DIR)/$*.sock

vde-down: $(NODES:%=down-%) ## Stop the VDE switch (after all VMs)
	@if [ -f $(VDE_PID) ]; then \
		echo "Stopping VDE switch..."; kill "$$(cat $(VDE_PID))" 2>/dev/null || true; \
	fi
	@rm -rf $(VDE_PID) $(VDE_CTL)

.PHONY: status
status: ## Show VM and VDE switch state (running / stopped / stale pidfile)
	@for name in $(NODES) vde; do \
		pidfile=$(RUN_DIR)/$$name.pid; \
		if [ ! -f "$$pidfile" ]; then echo "$$name: stopped"; \
		elif kill -0 "$$(cat "$$pidfile")" 2>/dev/null; then \
			echo "$$name: running (PID $$(cat "$$pidfile"))"; \
		else echo "$$name: stale pidfile ($$pidfile)"; fi; \
	done

##@ Cluster lifecycle

.PHONY: bootstrap kubeconfig cilium-install frr-rr cilium-bgp
# Initialize etcd and the Kubernetes control plane. Endpoint (127.0.0.1:50000) and default node
# are set in talosconfig. Waits for the Talos API first, so 'make up bootstrap' works without
# timing it. Talos answers by gRPC code, matched here:
#   FailedPrecondition  "bootstrap is not available yet": the API is up but the etcd service has
#                       not reached its waiting-to-join state; retried within WAIT_TIMEOUT
#   AlreadyExists       "etcd data directory is not empty": bootstrapped before; reported as done
bootstrap: $(TALOSCONFIG) ## Bootstrap etcd + control plane (waits for the Talos API; no-op if done)
	$(call wait-for,Talos API on control-plane-1,$(TALOSCTL) version)
	@told=; until out=$$($(TALOSCTL) bootstrap 2>&1); do \
		case $$out in \
			*AlreadyExists*) echo "bootstrap: already done"; exit 0;; \
			*FailedPrecondition*) \
				[ $$SECONDS -lt $(WAIT_TIMEOUT) ] || { echo "$$out" >&2; exit 1; }; \
				[ -n "$$told" ] || { echo "bootstrap: etcd not ready to bootstrap yet, retrying..."; told=1; }; \
				sleep 5;; \
			*) echo "$$out" >&2; exit 1;; \
		esac; \
	done; \
	[ -z "$$out" ] || echo "$$out"; \
	echo "bootstrap: started"

# Fetch kubeconfig into a file, rewrite the API server endpoint to the host-accessible port
# forward, then merge into the default kubeconfig. Safe for multi-cluster setups: only the
# $(CLUSTER_NAME) context is added or updated.
kubeconfig: $(TALOSCONFIG) ## Retrieve kubeconfig from Talos and merge it into ~/.kube/config
	$(TALOSCTL) kubeconfig $(KUBECONFIG_FILE) --force
	$(KUBECTL) config set-cluster $(CLUSTER_NAME) --server=https://127.0.0.1:$(K8S_API_PORT) \
		--kubeconfig $(KUBECONFIG_FILE)
	KUBECONFIG=$(KUBECONFIG_FILE):$$HOME/.kube/config \
		$(KUBECTL) config view --flatten > $$HOME/.kube/config.tmp
	mv $$HOME/.kube/config.tmp $$HOME/.kube/config
	$(KUBECTL) config use-context admin@$(CLUSTER_NAME)
	@echo "Merged $(CLUSTER_NAME) context into ~/.kube/config"

# Cilium CNI with eBPF datapath, kube-proxy replacement, and BGP. 'upgrade --install' is
# idempotent: re-running applies value changes instead of failing on an existing release.
# kube-apiserver comes up a minute or two after bootstrap; /readyz answers without a CNI because the
# control-plane static pods use host networking.
cilium-install: ## Install or upgrade Cilium CNI via Helm (waits for the Kubernetes API)
	@[ -f $(KUBECONFIG_FILE) ] || { echo "cilium-install: $(KUBECONFIG_FILE) missing, run 'make kubeconfig' first" >&2; exit 1; }
	$(call wait-for,Kubernetes API,$(KUBECTL) --kubeconfig $(KUBECONFIG_FILE) get --raw /readyz)
	$(HELM) repo add cilium https://helm.cilium.io/ 2>/dev/null || true
	$(HELM) repo update
	$(HELM) upgrade --install cilium cilium/cilium \
		--version $(CILIUM_VERSION) \
		--namespace kube-system \
		-f $(MANIFEST_DIR)/cilium-values.yaml

# FRR as a privileged pod on control-plane-1 for BGP route reflection. Uses hostNetwork - no CNI
# dependency. Peers with upstream-router (eBGP) and workers (iBGP).
frr-rr: ## Deploy the FRR Route Reflector pod on control-plane-1
	$(KUBECTL) apply -f $(MANIFEST_DIR)/frr-route-reflector.yaml

# Cilium BGP on worker nodes: iBGP peering with the FRR Route Reflector on control-plane-1. The
# CiliumBGP* CRDs are not in the Helm chart: cilium-operator registers them once it runs, a minute
# or so after cilium-install. A server-side dry run of the manifest succeeds once every kind in it
# resolves (and persists nothing), so the wait needs no CRD list of its own.
cilium-bgp: ## Apply Cilium iBGP peering CRDs for workers (waits for the CRDs)
	$(call wait-for,Cilium BGP CRDs,$(KUBECTL) apply --dry-run=server -f $(MANIFEST_DIR)/cilium-bgp.yaml)
	$(KUBECTL) apply -f $(MANIFEST_DIR)/cilium-bgp.yaml

##@ Tests

# lint is offline. validate needs network (Cilium chart, JSON schemas, FRR container image) and a
# running container runtime (docker or podman) for the FRR dry-run. test-e2e needs the lab up and
# bootstrapped. CI runs 'make test' on every push.
.PHONY: lint validate test test-e2e
lint: ## Lint YAML, Markdown, shell scripts, workflows (offline)
	$(TEST_DIR)/lint.sh

validate: ## Validate Talos configs, manifests, FRR and cloud-init (needs network)
	$(TEST_DIR)/validate-talos.sh
	$(TEST_DIR)/validate-manifests.sh
	$(TEST_DIR)/validate-frr.sh
	$(TEST_DIR)/validate-cloud-init.sh
	$(TEST_DIR)/check-versions.sh

test: lint validate ## lint + validate (what CI runs on every push)

test-e2e: ## End-to-end checks against the running lab
	$(TEST_DIR)/e2e.sh

##@ Dependencies

# scripts/deps.yaml lists every pin, its upstream source and the files that copy it. deps-bump
# applies each entry's default_level (patch for the cluster, minor for tools) unless LEVEL is set,
# never crosses a recorded constraint, and runs sync-versions afterwards. Judgment calls
# (compatibility, release notes, the live upgrade) are in .claude/skills/bump-deps/SKILL.md.
DEPS    ?=
LEVEL   ?=
DRY_RUN ?=
.PHONY: deps-outdated deps-bump sync-versions
deps-outdated: ## List pinned dependencies with newer upstream releases
	$(SCRIPT_DIR)/deps.sh outdated $(DEPS)

deps-bump: ## Bump pins (DEPS="talos cilium" LEVEL=patch|minor|major DRY_RUN=1), then sync copies
	$(SCRIPT_DIR)/deps.sh bump $(if $(LEVEL),--level $(LEVEL)) $(if $(DRY_RUN),--dry-run) $(DEPS)

sync-versions: ## Copy pinned versions into the manifests, cloud-init and README
	$(SCRIPT_DIR)/deps.sh sync

##@ Access and debugging

.PHONY: ssh-upstream talos-dashboard talos-health hubble-ca $(NODES:%=console-%)
# Only the Debian VM has SSH; Talos nodes have no sshd.
ssh-upstream: ## SSH to the upstream router (Debian)
	ssh -p $(SSH_PORT) $(SSH_USER)@127.0.0.1

# Serial console via the QEMU unix socket. Works for all VMs including Talos (boot messages,
# maintenance mode prompts).
$(NODES:%=console-%): console-%: ## Serial console via QEMU socket (console-<node>)
	$(SOCAT) -,raw,echo=0 unix-connect:$(RUN_DIR)/$*.sock

# After bootstrap, the control plane proxies requests to the workers.
talos-dashboard: $(TALOSCONFIG) ## Interactive Talos TUI dashboard across all Kubernetes nodes
	$(TALOSCTL) dashboard -n $(call join-comma,$(IP_MGMT_control-plane-1) $(WORKER_INTERNAL_IPS))

# Hubble Relay serves TLS with a certificate signed by the CA that Helm generates for Cilium: kept
# across helm upgrade, new with every cluster, so this always fetches it again. Only the export
# line goes to stdout (every recipe line is silent), so 'eval "$(make hubble-ca)"' sets up the
# hubble CLI in the current shell. A jsonpath on a missing key prints nothing and exits 0, hence
# the empty check before the file is written.
hubble-ca: ## Fetch the Hubble Relay CA; eval "$(make hubble-ca)" sets the hubble TLS env
	@[ -f $(KUBECONFIG_FILE) ] || { echo "hubble-ca: $(KUBECONFIG_FILE) missing, run 'make kubeconfig' first" >&2; exit 1; }
	@ca=$$($(KUBECTL) --kubeconfig $(KUBECONFIG_FILE) -n kube-system \
		get secret hubble-relay-server-certs -o jsonpath='{.data.ca\.crt}'); \
	[ -n "$$ca" ] || { echo "hubble-ca: no CA in secret hubble-relay-server-certs (is hubble.relay.tls.server enabled?)" >&2; exit 1; }; \
	printf '%s' "$$ca" | base64 -d > $(HUBBLE_CA_FILE)
	@echo "hubble-ca: wrote $(HUBBLE_CA_FILE)" >&2
	@echo "export HUBBLE_TLS=true HUBBLE_TLS_SERVER_NAME=instance.hubble-relay.cilium.io HUBBLE_TLS_CA_CERT_FILES='$(CURDIR)/$(HUBBLE_CA_FILE)'"

# Worker IPs use the internal network (fd00:100::/64): SLIRP IPs are per-VM isolated NAT, so the
# control plane can only reach workers via VDE.
talos-health: $(TALOSCONFIG) ## Check cluster health (etcd, kubelet, node readiness)
	$(TALOSCTL) health \
		--control-plane-nodes $(call join-comma,$(CP_INTERNAL_IPS)) \
		--worker-nodes $(call join-comma,$(WORKER_INTERNAL_IPS))

##@ Cleanup

.PHONY: clean nuke
# Stops the VMs first (their disks are about to go). Keeps the base images and secrets.yaml:
# rebuilding on the same PKI is harmless and saves a download. The cloud-init glob also removes
# seed ISOs left over from the pre-Talos layout.
clean: down ## Remove disks, generated configs, seed ISOs and kubeconfig (keeps images, secrets)
	rm -rf $(DISK_DIR)
	rm -f $(TALOS_BASE_CONFIGS) $(TALOSCONFIG) $(TALOS_NODE_CONFIGS) $(TALOS_META_DATA) \
		$(TALOS_SEEDS) $(KUBECONFIG_FILE) $(HUBBLE_CA_FILE) $(CLOUD_INIT_DIR)/*/seed.iso

nuke: clean ## Remove everything including base images and the Talos secrets bundle (new PKI)
	rm -rf $(IMAGE_DIR) $(TALOS_GEN_DIR)
