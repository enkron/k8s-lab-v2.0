# Kubernetes Lab v2.0 Implementation Plan

This document outlines the step-by-step implementation plan for provisioning
a local Kubernetes lab environment with IPv6-first networking, BGP routing,
and eBPF-based CNI.

**Goal**: Manual implementation for learning Kubernetes internals and modern
networking principles.<br>
Of course, this document's written with LLM help, but the idea and the
implementation are manual.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Phase 1: Infrastructure Provisioning](#2-phase-1-infrastructure-provisioning)
3. [Phase 2: Upstream Router Setup](#3-phase-2-upstream-router-setup)
4. [Phase 3: Kubernetes Cluster Bootstrap](#4-phase-3-kubernetes-cluster-bootstrap)
5. [Phase 4: CNI Installation (Cilium)](#5-phase-4-cni-installation-cilium)
6. [Phase 5: BGP Setup](#6-phase-5-bgp-setup)
7. [Phase 6: Validation and Testing](#7-phase-6-validation-and-testing)
8. [Appendix A: Tooling Recommendations](#8-appendix-a-tooling-recommendations)
9. [Appendix B: Usage Workflow](#9-appendix-b-usage-workflow)

---

## 1. Prerequisites

### 1.1 Host Requirements

| Requirement  | Specification                         |
|--------------|---------------------------------------|
| CPU          | Apple Silicon (M1..=M4)               |
| RAM          | 16GB minimum (32GB recommended)       |
| Storage      | 50GB+ free disk space                 |
| OS           | macOS with HVF (Hypervisor.framework) |
| Architecture | aarch64 (ARM64)                       |

**Target Platform**: macOS on Apple M4 Pro with HVF acceleration.

### 1.2 Required Software on Host

All dependencies managed via **Nix Flakes**:

```nix
{
  qemu             # >= 8.0, with HVF support
  socat            # Serial console access
  netcat           # Connectivity testing
  kubectl          # >= 1.29
  kubernetes-helm  # >= 3.14
  talosctl         # Talos node management CLI
  cilium-cli       # Cilium status and BGP commands
}
```

UEFI firmware: QEMU bundles EDK2 (OSS implementation of UEFI) firmware at
`$(nix build nixpkgs#qemu --print-out-paths --no-link)/share/qemu/edk2-aarch64-code.fd`

### 1.3 VM Guest OS Selection

**Hybrid approach**: Two operating systems, chosen for their respective roles.

**Talos Linux** (Kubernetes nodes: control-plane-1, worker-1, worker-2)

Rationale:

- Purpose-built, immutable OS for Kubernetes
- API-driven management via `talosctl` (no SSH, no shell, no package manager)
- Declarative machine config: networking, kernel modules, Kubernetes settings,
  and cluster membership defined in a single YAML document
- Linux kernel >= 6.12 with full eBPF support and cgroup v2
- containerd built-in with systemd cgroup driver
- Eliminates manual post-boot configuration (swap, kernel modules, kubeadm)
- Reproducible: same config always produces the same node state

**Debian 12 Bookworm** (upstream-router only)

Rationale:

- The upstream router runs FRRouting (FRR) as a system daemon, which requires
  a general-purpose OS with a package manager
- Talos cannot run arbitrary daemons outside Kubernetes
- Lightweight cloud image, native aarch64 support

### 1.4 Image Variants

| Image | Source | Nodes |
|---|---|---|
| `talos-arm64-nocloud.qcow2` | Talos Image Factory, converted from raw | control-plane-1, worker-1, worker-2 |
| `debian-12-generic-arm64.qcow2` | cloud.debian.org | upstream-router |

The Talos `nocloud` variant reads machine config from a CIDATA ISO at boot.
This uses the same physical delivery mechanism (ISO volume labeled `cidata`)
as the Debian cloud-init setup, but the content and processing engine are
entirely different:

| | Debian | Talos |
|---|---|---|
| Transport | CIDATA ISO via `mkisofs` | CIDATA ISO via `mkisofs` (same) |
| Content of `user-data` | `#cloud-config` YAML | Talos machine config YAML |
| Processing engine | `cloud-init` daemon | `machined` (Talos init) |
| Model | Imperative (run commands) | Declarative (desired OS state) |

---

## 2. Phase 1: Infrastructure Provisioning

### 2.1 VM Specifications

| Node            | vCPU | RAM   | Disk | NICs | OS    |
|-----------------|------|-------|------|------|-------|
| upstream-router | 1    | 512MB | 20GB | 2    | Debian 12 |
| control-plane-1 | 2    | 4GB   | 20GB | 2    | Talos |
| worker-1        | 2    | 4GB   | 20GB | 2    | Talos |
| worker-2        | 2    | 4GB   | 20GB | 2    | Talos |

The lab runs **4 VMs total**: 1 upstream router + 1 control plane + 2 workers.
The upstream router is infrastructure-only (no kubelet/container runtime).

### 2.1.1 QEMU Configuration (aarch64/HVF)

QEMU on Apple Silicon (HVF) requires specific flags that differ from Linux/KVM:

| Flag | Value | Why |
|------|-------|-----|
| `-cpu` | `max` | Enables all QEMU-emulated CPU features; `-cpu host` causes hangs on HVF with Talos v1.12+ |
| `-machine` | `virt,gic-version=max,accel=hvf` | `gic-version=max` selects the best GIC (interrupt controller); missing it defaults to GICv2 which breaks newer kernels |
| UEFI firmware | Two `-drive if=pflash` (code RO + vars RW) | `-bios` shorthand doesn't persist UEFI variables properly on ARM; pflash with separate code and 64MB variable store is required |
| Console | `-smbios type=11,...console=ttyS0` | Talos v1.12+ uses systemd-stub which reads console from SMBIOS, not kernel cmdline |
| RNG | `-device virtio-rng-pci` | Hardware entropy source for faster boot |

### 2.2 Implementation Steps

#### Step 2.2.1: Download Base Images

```bash
make images
```

This downloads the Debian cloud image and the Talos nocloud image (compressed
raw, converted to qcow2).

#### Step 2.2.2: Create VM Disk Images

```bash
make vms
```

Creates per-node CoW (copy-on-write) disks backed by the appropriate base
image. Talos nodes back to `talos-arm64-nocloud.qcow2`, upstream-router backs
to `debian-12-generic-arm64.qcow2`. Each disk is resized to 20G.

#### Step 2.2.3: Generate Talos Machine Configs

Talos machine config is a single YAML document declaring the entire node state.
Configs are generated in two steps: base generation + per-node patching.

```bash
# Generate base controlplane.yaml, worker.yaml, and talosconfig
make talos-gen

# Merge per-node patches (hostname, MAC addresses, static IPs)
make talos-configs
```

Patch files are stored in `talos/patches/`:

- `common.yaml` — shared: kernel modules, sysctls, cluster CIDRs, CNI=none,
  kube-proxy=disabled, `machine.certSANs` includes `127.0.0.1` and `localhost`
  (required for talosctl access through QEMU NAT port forwarding),
  `kubelet.nodeIP.validSubnets: [fd00:100::/64, 10.100.0.0/24]` (forces
  kubelet to register with internal VDE network addresses — IPv6 primary, IPv4
  secondary for Cilium native routing datapath)
- `controlplane.yaml` — scheduler, controller-manager, API server bind
  addresses, API server certSANs for all access paths,
  `etcd.advertisedSubnets: [fd00:100::/64]` (etcd must advertise on the
  internal network — default SLIRP addresses are per-VM isolated NAT)
- `worker.yaml` — worker-specific labels
- `control-plane-1.yaml` — MAC-based NIC matching, static IPs
- `worker-1.yaml`, `worker-2.yaml` — same pattern per node

Note: Talos v1.12+ requires hostname in the nocloud `meta-data` file (not in
`machine.network.hostname`). The seed ISO generation sets `local-hostname` in
meta-data automatically.

Network configuration is fully declarative in the machine config. Both NICs
receive static addresses at first boot (no manual post-boot step):

| Node            | Management NIC (by MAC)     | Internal NIC (by MAC)                  |
|-----------------|-----------------------------|-----------------------------------------|
| control-plane-1 | 192.168.100.10/24           | fd00:100::10/64, 10.100.0.10/24        |
| worker-1        | 192.168.100.11/24           | fd00:100::11/64, 10.100.0.11/24        |
| worker-2        | 192.168.100.12/24           | fd00:100::12/64, 10.100.0.12/24        |

The internal NIC carries both IPv6 (primary) and IPv4 (secondary). The IPv4
address (`10.100.0.0/24`) is required because Cilium's native routing datapath
needs an IPv4 source address on the routing device, even when the cluster
endpoint is IPv6.

Talos uses `deviceSelector.hardwareAddr` for MAC-based NIC binding (equivalent
to cloud-init's `match.macaddress`). DHCP and SLAAC are disabled on all
interfaces.

#### Step 2.2.4: Prepare Cloud-Init for Upstream Router

The upstream router uses standard cloud-init with three files under
`cloud-init/upstream-router/`:

- **meta-data**: instance identity and hostname
- **user-data**: `k8s` user with SSH key, partition resize, security hardening
- **network-config**: static IPv4 on management NIC (192.168.100.13/24),
  internal NIC brought up with `optional: true`

#### Step 2.2.5: Generate Seed ISOs

```bash
make seed
```

This generates:

- Talos CIDATA ISOs (machine config as `user-data`) for k8s nodes
- Cloud-init seed ISO for upstream-router

#### Step 2.2.6: Create Virtual Networks

Each VM has two NICs:

**Network 1: Management (NAT)**

- QEMU user-mode networking with port forwarding
- Static addressing on `192.168.100.0/24`
- Host access via forwarded ports:
  - upstream-router: SSH 2200
  - control-plane-1: K8s API 6443, Talos API 50000
  - worker-1: Talos API 50001
  - worker-2: Talos API 50002
  - No SSH on Talos nodes (immutable OS, no sshd)

**Network 2: Internal (L3 Routed)**

- VDE (Virtual Distributed Ethernet) switch for inter-VM L2 segment
- VDE is a userspace virtual switch — no root privileges or macOS entitlements
  required. QEMU's built-in multicast socket (`-netdev socket,mcast=`) cannot
  be used on macOS: the kernel's `IP_MULTICAST_LOOP=0` behavior differs from
  Linux and prevents inter-process multicast delivery entirely
- Carries BGP peering, pod traffic, and internal IPv6 routing
- No host NAT

MAC address mapping:

| Node            | Management MAC    | Internal MAC      |
|-----------------|-------------------|-------------------|
| upstream-router | 52:54:00:00:01:00 | 52:54:00:00:02:00 |
| control-plane-1 | 52:54:00:00:01:01 | 52:54:00:00:02:01 |
| worker-1        | 52:54:00:00:01:02 | 52:54:00:00:02:02 |
| worker-2        | 52:54:00:00:01:03 | 52:54:00:00:02:03 |

#### Step 2.2.7: Boot All VMs

```bash
make up
make status
```

Talos nodes boot and apply their machine config from the CIDATA ISO
automatically. The upstream router runs cloud-init on first boot.

#### Step 2.2.8: Verification Checklist

- [ ] All four VMs boot successfully (`make status`)
- [ ] Talos nodes reachable via `talosctl`:

  ```bash
  export TALOSCONFIG=talos/generated/talosconfig
  talosctl -n 192.168.100.10 version
  ```

- [ ] Both NICs configured on each Talos node:

  ```bash
  talosctl -n 192.168.100.10 get addresses
  ```

- [ ] Upstream router accessible via SSH (`make ssh-upstream`)
- [ ] Serial console accessible (`make console-<node>`)

---

## 3. Phase 2: Upstream Router Setup

The upstream router simulates edge/ToR infrastructure and provides:

- Default route advertisement to cluster nodes
- eBGP peering point for the Route Reflector
- North-south connectivity simulation

### 3.1 Architectural Role and Scope

- Boundary node between cluster AS `64512` and upstream AS `64513`.
- Not a Kubernetes node: no kubelet, container runtime, or CNI agent.
- Runs FRRouting (FRR) only, advertising `0.0.0.0/0` and `::/0` to the cluster.
- Receives Pod/Service routes from AS `64512` for north-south reachability
  tests.

### 3.2 IP Addressing and ASN

| Component                  | Address                      |
|----------------------------|------------------------------|
| Upstream Router (mgmt)     | 192.168.100.13/24 (static)   |
| Upstream Router (internal) | fd00:100::1/64               |
| Cluster AS                 | 64512                        |
| Upstream AS                | 64513                        |

### 3.3 Implementation Steps

#### Step 3.3.1: Configure Static IPv6 on Internal Interface

SSH into the upstream router and configure the internal NIC with
systemd-networkd:

```bash
# /etc/systemd/network/20-internal.network
[Match]
Name=eth1  # Adjust to actual interface name

[Network]
Address=fd00:100::1/64
IPv6AcceptRA=no
LinkLocalAddressing=ipv6
```

```bash
sudo systemctl restart systemd-networkd
```

#### Step 3.3.2: Install and Configure FRRouting

```bash
sudo apt install -y frr

# Enable BGP daemon
sudo sed -i 's/bgpd=no/bgpd=yes/' /etc/frr/daemons
```

FRR configuration (`/etc/frr/frr.conf`):

```text
frr version 9.1
frr defaults traditional
hostname upstream-router
log syslog informational
service integrated-vtysh-config
!
router bgp 64513
 bgp router-id 10.0.0.1
 no bgp ebgp-requires-policy
 !
 ! eBGP peer to Route Reflector on control-plane-1
 neighbor fd00:100::10 remote-as 64512
 neighbor fd00:100::10 description rr-control-plane-1
 !
 address-family ipv4 unicast
  network 0.0.0.0/0
  neighbor fd00:100::10 activate
  neighbor fd00:100::10 default-originate
 exit-address-family
 !
 address-family ipv6 unicast
  network ::/0
  neighbor fd00:100::10 activate
  neighbor fd00:100::10 default-originate
 exit-address-family
exit
!
ip route 0.0.0.0/0 Null0
ipv6 route ::/0 Null0
!
```

```bash
sudo systemctl restart frr
```

#### Step 3.3.3: Verification Checklist

- [ ] Upstream router reachable from cluster nodes (`ping6 fd00:100::1`)
- [ ] FRR running with BGP daemon enabled (`sudo vtysh -c "show bgp summary"`)
- [ ] No Kubernetes components installed on `upstream-router`

---

## 4. Phase 3: Kubernetes Cluster Bootstrap

With Talos Linux, there is no manual OS configuration phase. Talos handles
swap (disabled by design), kernel modules (declared in machine config),
containerd (built-in), and cgroup v2 (always enabled). The cluster is
bootstrapped via `talosctl`.

### 4.1 Bootstrap Control Plane

```bash
make bootstrap
```

This runs `talosctl bootstrap` against the control-plane-1 node, which
initializes etcd and starts the Kubernetes control plane components.

Run this **once**, on initial cluster setup only.

### 4.2 Retrieve Kubeconfig

```bash
make kubeconfig
```

Fetches the admin kubeconfig from control-plane-1 and merges it into the
default kubeconfig location.

### 4.3 Verify Cluster State

```bash
kubectl get nodes
```

Expected output: 3 nodes in `NotReady` state (CNI not yet installed).

```text
NAME              STATUS     ROLES           AGE   VERSION
control-plane-1   NotReady   control-plane   1m    v1.35.x
worker-1          NotReady   <none>          1m    v1.35.x
worker-2          NotReady   <none>          1m    v1.35.x
```

Workers auto-join because their machine config contains the cluster
membership credentials generated during `talosctl gen config`.

### 4.4 Verification Checklist

- [ ] `talosctl bootstrap` completes without errors
- [ ] kubeconfig retrieved and `kubectl` works
- [ ] All 3 nodes visible (`kubectl get nodes`)
- [ ] etcd running (`talosctl -n 192.168.100.10 services`)

---

## 5. Phase 4: CNI Installation (Cilium)

### 5.1 Tool Selection: Cilium

**Rationale**:

- eBPF-native datapath (no iptables)
- BGP peering support (CiliumBGP control plane)
- Full IPv6 and dual-stack support
- kube-proxy replacement built-in
- Excellent observability (Hubble)
- Industry standard for modern Kubernetes networking

### 5.2 Implementation Steps

#### Step 5.2.1: Install Cilium with Helm

```bash
make cilium-install
```

This runs `helm install` with Talos-specific values from
`manifests/cilium-values.yaml`:

- `k8sServiceHost: localhost`, `k8sServicePort: 7445` — Talos KubePrism
  (local kube-apiserver proxy, required because kube-proxy is disabled)
- `cgroup.autoMount.enabled: false` — Talos manages cgroup mounts
- `bgpControlPlane.enabled: true` — enables Cilium BGP for worker peering
- `kubeProxyReplacement: true` — eBPF replaces kube-proxy
- `hubble.enabled: true` — flow observability

#### Step 5.2.2: Wait for Cilium to Be Ready

```bash
kubectl -n kube-system rollout status daemonset/cilium --timeout=300s
kubectl get nodes
```

All nodes should transition to `Ready` once Cilium is running.

#### Step 5.2.3: Verification Checklist

- [ ] Cilium pods running on all nodes:

  ```bash
  kubectl -n kube-system get pods -l k8s-app=cilium
  ```

- [ ] All nodes Ready:

  ```bash
  kubectl get nodes
  ```

- [ ] Cilium status healthy:

  ```bash
  cilium status
  ```

---

## 6. Phase 5: BGP Setup

The BGP topology uses iBGP with Route Reflectors inside the cluster (AS 64512)
and eBGP at the edge to the upstream router (AS 64513). This is the
production-aligned model from `bgp-topology.md` section 6.1.

### 6.1 Topology

```text
        [Upstream Router]           (AS 64513, Debian + FRR system daemon)
               |
          eBGP peering
               |
     [control-plane-1]             (AS 64512)
       FRR pod (RR, hostNetwork)
               |
         iBGP client sessions
           /        \
    [worker-1]    [worker-2]       (AS 64512, Cilium iBGP clients)
```

- **Upstream-router**: FRR system daemon. eBGP peer to Route Reflector.
  Unchanged from production pattern.
- **control-plane-1**: FRR runs as a privileged Kubernetes pod with
  `hostNetwork: true`. Acts as Route Reflector. Peers with upstream-router
  (eBGP) and workers (iBGP). This is production-common: FRR in containers
  is how Cumulus/NVIDIA and many bare-metal deployments run network daemons.
- **worker-1, worker-2**: Cilium BGP control plane (GoBGP-based) acts as iBGP
  client, peering with the FRR Route Reflector. Advertises pod CIDRs.

### 6.2 Pod CIDR Allocation

| Node            | Pod CIDR (IPv4) | Pod CIDR (IPv6)   |
|-----------------|-----------------|-------------------|
| control-plane-1 | 10.244.0.0/24   | fd00:244:0::/64   |
| worker-1        | 10.244.1.0/24   | fd00:244:1::/64   |
| worker-2        | 10.244.2.0/24   | fd00:244:2::/64   |

### 6.3 Implementation Steps

#### Step 6.3.1: Deploy FRR Route Reflector Pod

```bash
make frr-rr
```

This deploys `manifests/frr-route-reflector.yaml`: a DaemonSet pinned to the
control-plane node with `hostNetwork: true` (no CNI dependency) and a ConfigMap
containing the FRR configuration.

The FRR pod:

- Peers with upstream-router (`fd00:100::1`) via eBGP (AS 64513)
- Peers with worker-1 (`fd00:100::11`) and worker-2 (`fd00:100::12`) via iBGP
  (AS 64512) as route-reflector-client
- Advertises control-plane-1's pod CIDR (`10.244.0.0/24`, `fd00:244:0::/64`)
- Reflects routes between workers and upstream

Verify FRR is running:

```bash
kubectl -n kube-system rollout status daemonset/frr-route-reflector
kubectl -n kube-system exec -it ds/frr-route-reflector -- \
  vtysh -c "show bgp summary"
```

#### Step 6.3.2: Configure Cilium iBGP on Workers

```bash
make cilium-bgp
```

This applies `manifests/cilium-bgp.yaml`: CiliumBGPClusterConfig,
CiliumBGPPeerConfig, and CiliumBGPAdvertisement CRDs. Workers peer via iBGP
(localASN=64512, peerASN=64512) with the FRR Route Reflector on
control-plane-1.

#### Step 6.3.3: Verify BGP Sessions

```bash
# FRR Route Reflector: all sessions established
kubectl -n kube-system exec -it ds/frr-route-reflector -- \
  vtysh -c "show bgp summary"

# Cilium workers: iBGP peer to RR established
cilium bgp peers

# Upstream router: eBGP session to RR established
make ssh-upstream
sudo vtysh -c "show bgp summary"
```

#### Step 6.3.4: Verify Route Propagation

```bash
# Pod CIDRs visible on Route Reflector
kubectl -n kube-system exec -it ds/frr-route-reflector -- \
  vtysh -c "show bgp ipv6 unicast"

# Pod CIDRs visible on upstream router (received via eBGP from RR)
# From upstream-router SSH session:
sudo vtysh -c "show bgp ipv6 unicast"
# Should show: fd00:244:0::/64, fd00:244:1::/64, fd00:244:2::/64
```

#### Step 6.3.5: Verification Checklist

- [ ] FRR pod running on control-plane-1 with hostNetwork
- [ ] eBGP session established between FRR RR and upstream-router
- [ ] iBGP sessions established between FRR RR and both workers (via Cilium)
- [ ] Pod CIDRs propagated to all nodes and upstream router
- [ ] Default route received by cluster from upstream-router

---

## 7. Phase 6: Validation and Testing

### 7.1 Network Connectivity Tests

#### Step 7.1.1: Deploy Test Workloads

```yaml
# test-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-nginx
spec:
  replicas: 3
  selector:
    matchLabels:
      app: test-nginx
  template:
    metadata:
      labels:
        app: test-nginx
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: test-nginx
spec:
  selector:
    app: test-nginx
  ports:
  - port: 80
    targetPort: 80
  ipFamilyPolicy: PreferDualStack
  ipFamilies:
  - IPv6
  - IPv4
```

#### Step 7.1.2: Pod-to-Pod Connectivity Test

```bash
kubectl get pods -o wide
kubectl exec -it <pod-name> -- ping6 -c 3 <other-pod-ipv6>
```

#### Step 7.1.3: Service Connectivity Test

```bash
kubectl exec -it <pod-name> -- curl -6 http://test-nginx
```

#### Step 7.1.4: BGP Route Verification

```bash
# From FRR Route Reflector
kubectl -n kube-system exec -it ds/frr-route-reflector -- \
  vtysh -c "show bgp ipv6 unicast"

# From Cilium on workers
cilium bgp routes
```

#### Step 7.1.5: eBPF Datapath Verification

```bash
cilium bpf lb list
cilium bpf ct list global
```

### 7.2 Validation Checklist

- [ ] Pods scheduled across all worker nodes
- [ ] Pod-to-pod connectivity works (same node)
- [ ] Pod-to-pod connectivity works (cross-node)
- [ ] Service VIPs resolve and load-balance
- [ ] IPv6 connectivity verified end-to-end
- [ ] BGP routes propagated correctly
- [ ] No iptables rules for service routing (eBPF handles it)
- [ ] Hubble flows visible (if enabled)

### 7.3 Traceability Verification

Per architecture requirements, verify packet path is traceable:

```bash
# Trace packet path with Hubble
hubble observe --pod <pod-name>

# Packet capture via talosctl (replaces tcpdump over SSH)
talosctl -n 192.168.100.11 pcap --interface eth1
```

---

## 8. Appendix A: Tooling Recommendations

### 8.1 Recommended Tools Summary

| Category          | Tool                | Rationale                              |
|-------------------|---------------------|----------------------------------------|
| Virtualization    | QEMU                | Direct control, HVF/KVM acceleration   |
| Guest OS (k8s)    | Talos Linux         | Immutable, API-driven, purpose-built   |
| Guest OS (router) | Debian 12           | General-purpose, FRR as system daemon  |
| Container Runtime | containerd          | Built into Talos                       |
| K8s Bootstrap     | talosctl            | Declarative, no SSH required           |
| CNI               | Cilium              | eBPF-native, BGP support, no overlays  |
| BGP (RR)          | FRRouting (FRR)     | Production-grade, IPv6 native, as pod  |
| BGP (workers)     | Cilium BGP          | GoBGP-based, iBGP client to FRR RR    |
| Observability     | Hubble              | Integrated with Cilium, eBPF flows     |
| K8s TUI           | k9s                 | Efficient cluster navigation           |
| Node management   | talosctl            | Dashboard, logs, pcap, processes       |

### 8.2 File Structure

```text
k8s_lab/
+-- Makefile
+-- .gitignore
+-- cloud-init/
|   +-- upstream-router/
|       +-- meta-data
|       +-- user-data
|       +-- network-config
+-- talos/
|   +-- patches/
|   |   +-- common.yaml
|   |   +-- controlplane.yaml
|   |   +-- worker.yaml
|   |   +-- control-plane-1.yaml
|   |   +-- worker-1.yaml
|   |   +-- worker-2.yaml
|   +-- generated/                  # gitignored
+-- manifests/
|   +-- cilium-values.yaml
|   +-- cilium-bgp.yaml
|   +-- frr-route-reflector.yaml
+-- docs/
|   +-- architecture/
|   |   +-- overview.md
|   |   +-- bgp-topology.md
|   +-- implementation-plan.md
|   +-- talos-migration-plan.md
+-- disks/                          # gitignored
+-- images/                         # gitignored
```

---

## 9. Appendix B: Usage Workflow

```bash
# Download base images (Debian + Talos)
make images

# Create per-node CoW disk images
make vms

# Generate Talos machine configs
make talos-gen
make talos-configs

# Generate all seed ISOs
make seed

# Start all VMs
make up

# Wait ~90s for Talos to boot, then bootstrap Kubernetes
make bootstrap
make kubeconfig

# Install Cilium CNI
make cilium-install

# Deploy FRR Route Reflector and configure BGP
make frr-rr
make cilium-bgp

# Verify
make talos-health
kubectl get nodes

# Interactive dashboard
make talos-dashboard

# Stop all VMs
make down
```

---

## Revision History

| Version | Date       | Author    | Changes                                   |
|---------|------------|-----------|-------------------------------------------|
| 1.0     | 2026-01-23 | Generated | Initial implementation plan               |
| 2.0     | 2026-04-10 | Generated | Talos Linux migration, iBGP+RR with Cilium |
| 2.1     | 2026-04-15 | Generated | Talos v1.12.6, VDE networking, pflash UEFI, native routing, dual-stack internal NIC |
| 2.2     | 2026-05-01 | Generated | Talos v1.13.0; Kubernetes pinned to v1.35.4 (Cilium 1.19 stable until 1.20 GA) |
| 2.3     | 2026-07-01 | Generated | Talos v1.13.5, Kubernetes 1.35.6, Cilium 1.19.5, FRR 10.4.4 |
