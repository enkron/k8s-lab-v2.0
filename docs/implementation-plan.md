# Kubernetes Lab v2.0 Implementation Plan

This document outlines the step-by-step implementation plan for provisioning
a local Kubernetes lab environment with IPv6-first networking, BGP routing,
and eBPF-based CNI.

**Goal**: Manual implementation for learning Kubernetes internals and modern
networking principles.<br>
Of course, this document's written with LLM help, but the ideas and the
implementation are totally manual.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Phase 1: Infrastructure Provisioning (QEMU VMs)](#2-phase-1-infrastructure-provisioning-qemu-vms)
3. [Phase 2: Base OS Configuration](#3-phase-2-base-os-configuration)
4. [Phase 3: Network Configuration](#4-phase-3-network-configuration)
5. [Phase 4: Upstream Router Setup](#5-phase-4-upstream-router-setup)
6. [Phase 5: BGP Setup with FRRouting](#6-phase-5-bgp-setup-with-frrouting)
7. [Phase 6: Kubernetes Prerequisites](#7-phase-6-kubernetes-prerequisites)
8. [Phase 7: Kubernetes Cluster Bootstrap](#8-phase-7-kubernetes-cluster-bootstrap)
9. [Phase 8: CNI Installation (Cilium)](#9-phase-8-cni-installation-cilium)
10. [Phase 9: Validation and Testing](#10-phase-9-validation-and-testing)
11. [Appendix A: Tooling Recommendations](#11-appendix-a-tooling-recommendations)
12. [Appendix B: Usage Workflow](#12-usage-workflow)

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
}
```

UEFI firmware: QEMU bundles EDK2 (OSS implementation of UEFI) firmware at
`$(nix build nixpkgs#qemu --print-out-paths --no-link)/share/qemu/edk2-aarch64-code.fd`

### 1.3 VM Guest OS Selection

Debian 12 (Bookworm)

Rationale:
- Linux kernel >= 6.1 with full eBPF support
- cgroup v2 unified hierarchy enabled by default
- systemd-networkd for predictable network configuration
- Community support and documentation
- kubeadm packages readily available
- Native aarch64 cloud images available
- Debian based image is lightweight and isn't bloated with desktop
  environments.

Alternatively: Fedora 40 or Rocky Linux 9 (for RHEL-like experience)

### 1.4 cgroup v2 Requirement

cgroup v2 verification:

```bash
stat -fc %T /sys/fs/cgroup
```

If cgroup v1 is detected, add `systemd.unified_cgroup_hierarchy=1` to kernel cmdline.

---

## 2. Phase 1: Infrastructure Provisioning (QEMU VMs)

### 2.1 VM Specifications

| Node            | vCPU | RAM | Disk | NICs |
|-----------------|------|-----|------|------|
| upstream-router | 1    | 512MB | 20GB | 2  |
| control-plane-1 | 2    | 4GB | 20GB | 2    |
| worker-1        | 2    | 4GB | 20GB | 2    |
| worker-2        | 2    | 4GB | 20GB | 2    |

The lab runs **4 VMs total**: 1 upstream router + 1 control plane + 2 workers.
The upstream router is infrastructure-only (no kubelet/container runtime).

### 2.2 Implementation Steps

#### Step 2.2.1: Create Base VM Image

1. Download cloud image (qcow2 format)
2. Create backing image for CoW (copy-on-write) efficiency:

   ```bash
   qemu-img create -f qcow2 -b base-image.qcow2 -F qcow2 upstream-router.qcow2
   qemu-img create -f qcow2 -b base-image.qcow2 -F qcow2 control-plane-1.qcow2
   qemu-img create -f qcow2 -b base-image.qcow2 -F qcow2 worker-1.qcow2
   qemu-img create -f qcow2 -b base-image.qcow2 -F qcow2 worker-2.qcow2
   ```

3. Resize disk images as needed:

   ```bash
   qemu-img resize upstream-router.qcow2 20G
   qemu-img resize control-plane-1.qcow2 20G
   qemu-img resize worker-1.qcow2 20G
   qemu-img resize worker-2.qcow2 20G
   ```

#### Step 2.2.2: Prepare cloud-init Configuration

Create `user-data`, `meta-data`, and `network-config` files per node (including
upstream-router). Files are stored under `cloud-init/<node>/`.

Each node requires three files:

**meta-data** — instance identity:

```yaml
instance-id: <node-name>
local-hostname: <node-name>
```

**user-data** — OS-level provisioning:

```yaml
#cloud-config

hostname: control-plane-1
manage_etc_hosts: true

users:
  - name: k8s
    gecos: Kubernetes Admin
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... user@host

growpart:
  mode: auto
  devices: ['/']

resize_rootfs: true

ssh_pwauth: false
disable_root: true

timezone: UTC

package_update: true
package_upgrade: true

final_message: "cloud-init completed for control-plane-1 ($UPTIME s)"
```

Configuration details:
- **users**: Only `k8s` user is created (replaces the default `debian` user).
  Password login disabled; SSH key-only access.
- **growpart/resize_rootfs**: Expands the root partition to fill the 20GB disk
  (the base cloud image ships with a ~2GB partition).
- **manage_etc_hosts**: Adds hostname to `/etc/hosts` so `sudo` and other tools
  can resolve it without DNS.
- **package_upgrade**: Runs `apt upgrade` on first boot for security patches.

**network-config** — NIC configuration (cloud-init v2 format):

```yaml
version: 2
ethernets:
  mgmt:
    match:
      macaddress: "52:54:00:00:01:01"
    dhcp4: false
    dhcp6: false
    addresses:
      - 192.168.100.10/24
    gateway4: 192.168.100.2
    nameservers:
      addresses:
        - 192.168.100.3
  internal:
    match:
      macaddress: "52:54:00:00:02:01"
    dhcp4: false
    dhcp6: false
    optional: true
```

Network config details:
- NICs matched by MAC address for deterministic interface binding regardless of
  the kernel's predictable naming (enp0sX).
- Management IPv4 addresses are deterministic:
  - `control-plane-1`: static `192.168.100.10/24`
  - `worker-1`: static `192.168.100.11/24`
  - `worker-2`: static `192.168.100.12/24`
  - `upstream-router`: static `192.168.100.13/24`
- Internal NIC is brought up with no addresses; static IPv6 is configured
  manually in Phase 3.
- `optional: true` prevents cloud-init from blocking boot while waiting for the
  internal NIC to be fully configured.

MAC address mapping (from Makefile QEMU definitions):

| Node            | Management MAC      | Internal MAC        |
|-----------------|---------------------|---------------------|
| upstream-router | 52:54:00:00:01:00   | 52:54:00:00:02:00   |
| control-plane-1 | 52:54:00:00:01:01   | 52:54:00:00:02:01   |
| worker-1        | 52:54:00:00:01:02   | 52:54:00:00:02:02   |
| worker-2        | 52:54:00:00:01:03   | 52:54:00:00:02:03   |

Generate seed ISOs (requires `mkisofs` from `cdrtools`):

```bash
make cloud-init
```

#### Step 2.2.3: Create Virtual Networks

**Network 1: Management (NAT)**
- QEMU user-mode networking with port forwarding
- Deterministic addressing on `192.168.100.0/24`:
  - `control-plane-1`: `192.168.100.10` (static in cloud-init)
  - `worker-1`: `192.168.100.11` (static in cloud-init)
  - `worker-2`: `192.168.100.12` (static in cloud-init)
  - `upstream-router`: `192.168.100.13` (static in cloud-init)
- SSH access via host ports (e.g., 2200, 2201, 2202, 2203)

**Network 2: Internal (L3 Routed)**
- QEMU socket or multicast networking for inter-VM communication
- No host NAT; pure L2 segment for nodes

```bash
# Example: socket-based networking for internal segment
-netdev socket,id=internal,mcast=230.0.0.1:1234
-device virtio-net-pci,netdev=internal,mac=52:54:00:XX:XX:XX
```

#### Step 2.2.4: QEMU Launch Scripts (macOS/HVF/aarch64)

Create per-node launch scripts. Run from Nix devShell where QEMU is available:

```bash
#!/usr/bin/env bash
# control-plane-1.sh - Control plane node (macOS/HVF/aarch64)

# EDK2 firmware - bundled with QEMU in Nix
FIRMWARE="$(nix build nixpkgs#qemu --print-out-paths --no-link)/share/qemu/edk2-aarch64-code.fd"

qemu-system-aarch64 \
  -name control-plane-1 \
  -machine virt,accel=hvf,highmem=on \
  -cpu host \
  -smp 2 \
  -m 4G \
  -bios "${FIRMWARE}" \
  -drive file=control-plane-1.qcow2,if=virtio,format=qcow2 \
  -drive file=control-plane-1-seed.iso,if=virtio,format=raw \
  -netdev user,id=mgmt,net=192.168.100.0/24,hostfwd=tcp::2201-192.168.100.10:22,hostfwd=tcp::6443-192.168.100.10:6443 \
  -device virtio-net-pci,netdev=mgmt,mac=52:54:00:00:01:01 \
  -netdev socket,id=internal,mcast=230.0.0.1:1234 \
  -device virtio-net-pci,netdev=internal,mac=52:54:00:00:02:01 \
  -nographic \
  -serial mon:stdio
```

#### Step 2.2.5: Verification Checklist

- [ ] All four VMs boot successfully
- [ ] SSH access works via management network
- [ ] Serial console accessible
- [ ] Internal NIC visible on each VM (`ip link`)

---

## 3. Phase 2: Base OS Configuration

### 3.1 Implementation Steps (Kubernetes Nodes Only)

Applies to `control-plane-1`, `worker-1`, and `worker-2`.
Do **not** install Kubernetes components on `upstream-router`.

#### Step 3.1.1: System Updates

```bash
sudo apt update && sudo apt upgrade -y
sudo reboot  # If kernel updated
```

#### Step 3.1.2: Disable Swap

Kubernetes requires swap disabled:

```bash
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab
# Verify: free -h shows 0 swap
```

#### Step 3.1.3: Load Required Kernel Modules

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
```

#### Step 3.1.4: Sysctl Parameters for Kubernetes

```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv6.conf.all.forwarding        = 1
EOF

sudo sysctl --system
```

#### Step 3.1.5: Install Container Runtime (containerd)

```bash
# Install containerd
sudo apt install -y containerd

# Generate default config
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml

# Enable systemd cgroup driver
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' \
  /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd
```

#### Step 3.1.6: Verify cgroup v2

```bash
# Must return "cgroup2fs"
stat -fc %T /sys/fs/cgroup

# Verify unified hierarchy
ls /sys/fs/cgroup/  # Should show controllers like cpu, memory, io
```

#### Step 3.1.7: Verification Checklist

- [ ] cgroup v2 enabled (`stat -fc %T /sys/fs/cgroup` returns `cgroup2fs`)
- [ ] Swap is disabled (`free -h`)
- [ ] Kernel modules loaded (`lsmod | grep overlay`)
- [ ] IPv6 forwarding enabled (`sysctl net.ipv6.conf.all.forwarding`)
- [ ] containerd running (`systemctl status containerd`)

---

## 4. Phase 3: Network Configuration

### 4.1 IP Addressing Scheme

| Node            | Management NIC (eth0)             | Internal NIC (eth1) |
|-----------------|-----------------------------------|---------------------|
| upstream-router | 192.168.100.13/24 (static)        | fd00:100::1/64      |
| control-plane-1 | 192.168.100.10/24 (static)        | fd00:100::10/64     |
| worker-1        | 192.168.100.11/24 (static)        | fd00:100::11/64     |
| worker-2        | 192.168.100.12/24 (static)        | fd00:100::12/64     |

### 4.2 Implementation Steps

#### Step 4.2.1: Identify Network Interfaces

```bash
ip link show
# Typically: eth0 (or enp0s1) = mgmt, eth1 (or enp0s2) = internal
```

#### Step 4.2.2: Configure Static IPv6 on Internal Interface

Using systemd-networkd (recommended for predictability):

```bash
# /etc/systemd/network/20-internal.network (control-plane-1 example)
[Match]
Name=eth1  # Adjust to actual interface name

[Network]
Address=fd00:100::10/64
IPv6AcceptRA=no
LinkLocalAddressing=ipv6

[Route]
# Routes to other nodes (initial; BGP will handle pod CIDRs)
Destination=fd00:100::11/128
Gateway=fd00:100::11
Destination=fd00:100::12/128
Gateway=fd00:100::12
```

Use the same pattern on `upstream-router`, with:
- `Address=fd00:100::1/64`
- `IPv6AcceptRA=no`
- no kubelet/node-level settings

**Critical**: Set `IPv6AcceptRA=no` to disable SLAAC per architecture requirements.

**Why no SLAAC?**
- Kubernetes requires stable node IPs; K8s does not handle IP changes at runtime
- Static addressing is the data center standard for infrastructure servers
- Deterministic addresses enable predictable BGP peering and debugging
- Prevents rogue Router Advertisement attacks

#### Step 4.2.3: Apply Network Configuration

```bash
sudo systemctl restart systemd-networkd
sudo networkctl status eth1
```

#### Step 4.2.4: Verification Checklist

- [ ] Each node has correct IPv6 address on internal NIC
- [ ] No SLAAC addresses present (only static fd00:100::XX)
- [ ] Nodes can ping each other via IPv6:
  ```bash
  ping6 -c 3 fd00:100::11  # From control-plane-1 to worker-1
  ```

---

## 5. Phase 4: Upstream Router Setup

The upstream router simulates edge/ToR infrastructure and provides:
- Default route advertisement to cluster nodes
- eBGP peering point for Route Reflectors
- North-south connectivity simulation

### 5.1 Architectural Role and Scope

- Boundary node between cluster AS `64512` and upstream AS `64513`.
- Not a Kubernetes node: no kubelet, kubeadm, kube-proxy, or CNI agent.
- Runs FRRouting (FRR) only, advertising `0.0.0.0/0` and `::/0` to the cluster.
- Receives Pod/Service routes from AS `64512` for north-south reachability tests.

### 5.2 Upstream Router Options

| Option | Description | Complexity |
|--------|-------------|------------|
| Dedicated VM | Lightweight Linux VM with FRR (architecture-aligned) | Medium |
| Host-based FRR | Run FRR on macOS host | Low |
| Container | FRR in Docker/Podman | Low |

**Recommended**: Dedicated VM. Host/container variants are acceptable for quick
experimentation but deviate from the architecture baseline.

### 5.3 IP Addressing and ASN

| Component                  | Address        |
|----------------------------|----------------|
| Upstream Router (mgmt)     | 192.168.100.13/24 (static) |
| Upstream Router (internal) | fd00:100::1/64 |
| Cluster AS                 | 64512          |
| Upstream AS                | 64513          |

### 5.4 Implementation Steps

#### Step 5.4.1: Option A - Dedicated VM

Create a minimal VM (Alpine Linux or similar) with FRR:

```bash
# upstream-router.sh
qemu-system-aarch64 \
  -name upstream-router \
  -machine virt,accel=hvf,highmem=on \
  -cpu host \
  -smp 1 \
  -m 512M \
  -bios "${FIRMWARE}" \
  -drive file=upstream-router.qcow2,if=virtio,format=qcow2 \
  -drive file=upstream-router-seed.iso,if=virtio,format=raw \
  -netdev user,id=mgmt,net=192.168.100.0/24,hostfwd=tcp::2200-192.168.100.13:22 \
  -device virtio-net-pci,netdev=mgmt,mac=52:54:00:00:01:00 \
  -netdev socket,id=internal,mcast=230.0.0.1:1234 \
  -device virtio-net-pci,netdev=internal,mac=52:54:00:00:02:00 \
  -nographic
```

#### Step 5.4.2: Option B - Host-based FRR (via Nix)

Add FRR to your Nix flake and run on host with a tap interface connected to the
internal network. This requires additional network bridge setup on macOS.

#### Step 5.4.3: Upstream Router FRR Configuration

```
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
 ! eBGP peers to Route Reflectors
 neighbor fd00:100::10 remote-as 64512
 neighbor fd00:100::10 description rr-control-plane-1
 !
 address-family ipv4 unicast
  ! Advertise default route
  network 0.0.0.0/0
  neighbor fd00:100::10 activate
  neighbor fd00:100::10 default-originate
 exit-address-family
 !
 address-family ipv6 unicast
  ! Advertise default route
  network ::/0
  neighbor fd00:100::10 activate
  neighbor fd00:100::10 default-originate
 exit-address-family
exit
!
! Static default routes (point to actual gateway or null for lab)
ip route 0.0.0.0/0 Null0
ipv6 route ::/0 Null0
!
```

#### Step 5.4.4: Verification Checklist

- [ ] Upstream router reachable from cluster nodes (`ping6 fd00:100::1`)
- [ ] eBGP session established with Route Reflector
- [ ] Default route advertised and received by nodes
- [ ] No Kubernetes components installed on `upstream-router`

---

## 6. Phase 5: BGP Setup with FRRouting

### 5.1 Tool Selection: FRRouting (FRR)

**Rationale**:
- Production-grade BGP implementation
- Native IPv6 support
- Integrates well with Cilium
- `vtysh` CLI familiar to network engineers
- Active development and community

**Alternative**: BIRD (lighter weight, excellent for labs)

### 5.2 Pod CIDR Allocation

| Node            | Pod CIDR (IPv4) | Pod CIDR (IPv6) |
|-----------------|-----------------|-----------------|
| control-plane-1 | 10.244.0.0/24   | fd00:244:0::/64 |
| worker-1        | 10.244.1.0/24   | fd00:244:1::/64 |
| worker-2        | 10.244.2.0/24   | fd00:244:2::/64 |

### 5.3 Implementation Steps

#### Step 5.3.1: Install FRRouting

```bash
# Add FRR repository (Debian/Ubuntu)
curl -s https://deb.frrouting.org/frr/keys.gpg | sudo tee \
  /usr/share/keyrings/frrouting.gpg > /dev/null

echo "deb [signed-by=/usr/share/keyrings/frrouting.gpg] \
  https://deb.frrouting.org/frr $(lsb_release -cs) frr-stable" | \
  sudo tee /etc/apt/sources.list.d/frr.list

sudo apt update
sudo apt install -y frr frr-pythontools
```

#### Step 5.3.2: Enable BGP Daemon

```bash
sudo sed -i 's/bgpd=no/bgpd=yes/' /etc/frr/daemons
sudo systemctl restart frr
```

#### Step 5.3.3: Configure BGP with Route Reflectors

The topology uses eBGP at the edge (upstream routers) and iBGP internally with Route Reflectors:

```
              [Upstream Router]     (AS 64513, runs on host or separate VM)
                     |
                eBGP peering
                     |
              [Route Reflector]     (AS 64512, co-located on control-plane-1)
                     |
            iBGP client sessions
                     |
              +------+------+
              |      |      |
[control-plane-1] [wrk-1] [wrk-2]   (AS 64512)
```

**Route Reflector configuration (control-plane-1)** (`/etc/frr/frr.conf`):

```
frr version 9.1
frr defaults traditional
hostname control-plane-1
log syslog informational
service integrated-vtysh-config
!
router bgp 64512
 bgp router-id 10.0.0.10
 bgp cluster-id 10.0.0.10
 no bgp ebgp-requires-policy
 bgp bestpath as-path multipath-relax
 !
 ! eBGP peer to upstream router
 neighbor fd00:100::1 remote-as 64513
 neighbor fd00:100::1 description upstream-router
 !
 ! iBGP clients (route reflector clients)
 neighbor fd00:100::11 remote-as 64512
 neighbor fd00:100::11 description worker-1
 neighbor fd00:100::12 remote-as 64512
 neighbor fd00:100::12 description worker-2
 !
 address-family ipv4 unicast
  network 10.244.0.0/24
  neighbor fd00:100::1 activate
  neighbor fd00:100::11 activate
  neighbor fd00:100::11 route-reflector-client
  neighbor fd00:100::11 next-hop-self
  neighbor fd00:100::12 activate
  neighbor fd00:100::12 route-reflector-client
  neighbor fd00:100::12 next-hop-self
 exit-address-family
 !
 address-family ipv6 unicast
  network fd00:244:0::/64
  neighbor fd00:100::1 activate
  neighbor fd00:100::11 activate
  neighbor fd00:100::11 route-reflector-client
  neighbor fd00:100::11 next-hop-self
  neighbor fd00:100::12 activate
  neighbor fd00:100::12 route-reflector-client
  neighbor fd00:100::12 next-hop-self
 exit-address-family
exit
!
```

**Worker node configuration (worker-1)** (`/etc/frr/frr.conf`):

```
frr version 9.1
frr defaults traditional
hostname worker-1
log syslog informational
service integrated-vtysh-config
!
router bgp 64512
 bgp router-id 10.0.0.11
 no bgp ebgp-requires-policy
 !
 ! iBGP peer to Route Reflector only (not to other workers)
 neighbor fd00:100::10 remote-as 64512
 neighbor fd00:100::10 description route-reflector-control-plane-1
 !
 address-family ipv4 unicast
  network 10.244.1.0/24
  neighbor fd00:100::10 activate
 exit-address-family
 !
 address-family ipv6 unicast
  network fd00:244:1::/64
  neighbor fd00:100::10 activate
 exit-address-family
exit
!
```

Worker-2 follows same pattern with its own router-id and pod CIDRs.

#### Step 5.3.4: Apply and Verify BGP Configuration

```bash
sudo systemctl restart frr

# Verify BGP neighbors
sudo vtysh -c "show bgp summary"
sudo vtysh -c "show bgp ipv6 unicast"
sudo vtysh -c "show ip route"
```

#### Step 5.3.5: Verification Checklist

- [ ] BGP sessions established between all nodes
- [ ] Pod CIDRs visible in routing table on each node:
  ```bash
  ip -6 route show | grep fd00:244
  ```
- [ ] Route count matches expected (2 remote pod CIDRs per node)

---

## 7. Phase 6: Kubernetes Prerequisites

### 7.1 Implementation Steps (Kubernetes Nodes Only)

Apply this phase only to `control-plane-1`, `worker-1`, and `worker-2`.
`upstream-router` remains outside Kubernetes lifecycle management.

#### Step 7.1.1: Add Kubernetes Repository

```bash
# Kubernetes apt repository
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list
```

#### Step 8.1.2: Install kubeadm, kubelet, kubectl

```bash
sudo apt update
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

#### Step 8.1.3: Configure kubelet for IPv6

Create kubelet configuration drop-in:

```bash
# /etc/default/kubelet
KUBELET_EXTRA_ARGS="--node-ip=fd00:100::10"  # Adjust per node
```

#### Step 8.1.4: Verification Checklist

- [ ] kubeadm version matches expected (`kubeadm version`)
- [ ] kubelet configured but not yet started
- [ ] kubectl available

---

## 8. Phase 7: Kubernetes Cluster Bootstrap

### 8.1 kubeadm Configuration

#### Step 8.1.1: Create kubeadm Configuration File (control-plane-1)

```yaml
# kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "fd00:100::10"
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  kubeletExtraArgs:
    node-ip: "fd00:100::10"
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v1.30.0
networking:
  podSubnet: "10.244.0.0/16,fd00:244::/48"
  serviceSubnet: "10.96.0.0/16,fd00:96::/112"
controllerManager:
  extraArgs:
    bind-address: "::"
    allocate-node-cidrs: "true"
    cluster-cidr: "10.244.0.0/16,fd00:244::/48"
    node-cidr-mask-size-ipv4: "24"
    node-cidr-mask-size-ipv6: "64"
scheduler:
  extraArgs:
    bind-address: "::"
apiServer:
  extraArgs:
    bind-address: "::"
etcd:
  local:
    extraArgs:
      listen-client-urls: "https://[::]:2379,https://127.0.0.1:2379"
      advertise-client-urls: "https://[fd00:100::10]:2379"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
```

#### Step 8.1.2: Initialize Control Plane

```bash
sudo kubeadm init --config kubeadm-config.yaml --skip-phases=addon/kube-proxy
```

**Note**: `--skip-phases=addon/kube-proxy` because Cilium will replace kube-proxy
with eBPF-based implementation.

#### Step 8.1.3: Configure kubectl Access

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

#### Step 8.1.4: Save Join Command

```bash
kubeadm token create --print-join-command > /tmp/join-command.sh
```

### 8.2 Join Worker Nodes

#### Step 8.2.1: Execute Join Command on Workers

```bash
# On worker-1 and worker-2
sudo kubeadm join [fd00:100::10]:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

#### Step 9.2.2: Verification Checklist

- [ ] Control plane initialized successfully
- [ ] etcd running as static pod (`crictl ps | grep etcd`)
- [ ] API server accessible (`kubectl get nodes`)
- [ ] Workers joined (status will be NotReady until CNI installed)
- [ ] All nodes use IPv6 addresses

---

## 9. Phase 8: CNI Installation (Cilium)

### 9.1 Tool Selection: Cilium

**Rationale**:
- eBPF-native datapath (no iptables)
- BGP peering support (CiliumBGP)
- Full IPv6 and dual-stack support
- kube-proxy replacement built-in
- Excellent observability (Hubble)
- Industry standard for modern Kubernetes networking

### 9.2 Implementation Steps

#### Step 9.2.1: Install Cilium CLI

```bash
CILIUM_CLI_VERSION=$(curl -s \
  https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --fail --remote-name-all \
  https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-arm64.tar.gz
sudo tar xzvfC cilium-linux-arm64.tar.gz /usr/local/bin
rm cilium-linux-arm64.tar.gz
```

#### Step 9.2.2: Install Cilium with Helm

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update

helm install cilium cilium/cilium --version 1.16.0 \
  --namespace kube-system \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=fd00:100::10 \
  --set k8sServicePort=6443 \
  --set ipv4.enabled=true \
  --set ipv6.enabled=true \
  --set bpf.masquerade=true \
  --set bgpControlPlane.enabled=true \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true
```

#### Step 9.2.3: Configure CiliumBGP Peering

Create BGP peering policy to integrate with FRR:

```yaml
# cilium-bgp-peering.yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPPeeringPolicy
metadata:
  name: rack-bgp
spec:
  nodeSelector:
    matchLabels:
      kubernetes.io/os: linux
  virtualRouters:
  - localASN: 64512
    exportPodCIDR: true
    neighbors:
    # Peer with FRR on the same node (localhost)
    - peerAddress: "fd00:100::10/128"
      peerASN: 64512
    - peerAddress: "fd00:100::11/128"
      peerASN: 64512
    - peerAddress: "fd00:100::12/128"
      peerASN: 64512
```

```bash
kubectl apply -f cilium-bgp-peering.yaml
```

#### Step 9.2.4: Verification Checklist

- [ ] Cilium pods running on all nodes:
  ```bash
  kubectl -n kube-system get pods -l k8s-app=cilium
  ```
- [ ] Cilium status healthy:
  ```bash
  cilium status
  ```
- [ ] eBPF programs loaded:
  ```bash
  cilium bpf endpoint list
  ```
- [ ] All nodes Ready:
  ```bash
  kubectl get nodes
  ```

---

## 10. Phase 9: Validation and Testing

### 10.1 Network Connectivity Tests

#### Step 10.1.1: Deploy Test Workloads

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

#### Step 10.1.2: Pod-to-Pod Connectivity Test

```bash
# Get pod IPs
kubectl get pods -o wide

# Exec into a pod and test connectivity
kubectl exec -it <pod-name> -- ping6 -c 3 <other-pod-ipv6>
```

#### Step 10.1.3: Service Connectivity Test

```bash
kubectl exec -it <pod-name> -- curl -6 http://test-nginx
```

#### Step 10.1.4: BGP Route Verification

```bash
# On any node
sudo vtysh -c "show bgp ipv6 unicast"

# Verify pod CIDR routes are present
ip -6 route | grep fd00:244
```

#### Step 10.1.5: eBPF Datapath Verification

```bash
# List eBPF maps
sudo bpftool map list

# Verify Cilium eBPF programs
cilium bpf lb list
cilium bpf ct list global
```

### 10.2 Validation Checklist

- [ ] Pods scheduled across all worker nodes
- [ ] Pod-to-pod connectivity works (same node)
- [ ] Pod-to-pod connectivity works (cross-node)
- [ ] Service VIPs resolve and load-balance
- [ ] IPv6 connectivity verified end-to-end
- [ ] BGP routes propagated correctly
- [ ] No iptables rules for service routing (eBPF handles it)
- [ ] Hubble flows visible (if enabled)

### 10.3 Traceability Verification

Per architecture requirements, verify packet path is traceable:

```bash
# Trace packet path with Hubble
hubble observe --pod <pod-name>

# Or with tcpdump on internal interface
sudo tcpdump -i eth1 -n icmp6
```

---

## 11. Appendix A: Tooling Recommendations

### 11.1 Recommended Tools Summary

| Category          | Tool                            | Rationale                             |
|-------------------|---------------------------------|---------------------------------------|
| Virtualization    | QEMU                            | Direct control, HVF/KVM acceleration  |
| Guest OS          | Debian 12 / Ubuntu 24.04        | Modern kernel, eBPF support           |
| Container Runtime | containerd                      | K8s default, stable                   |
| K8s Bootstrap     | kubeadm                         | Industry standard, educational        |
| CNI               | Cilium                          | eBPF-native, BGP support, no overlays |
| BGP Daemon        | FRRouting (FRR)                 | Production-grade, IPv6 native         |
| Observability     | Hubble                          | Integrated with Cilium, eBPF flows    |
| K8s TUI           | k9s                             | Efficient cluster navigation          |

### 11.2 Alternative Considerations

| Component      | Alternative        | When to Consider                   |
|----------------|--------------------|------------------------------------|
| CNI            | Calico (eBPF mode) | If Cilium proves problematic       |
| BGP            | BIRD               | Lighter weight, sufficient for lab |
| Guest OS       | Fedora             | If newer packages needed           |
| Virtualization | libvirt            | If GUI management desired          |

### 11.3 File Structure Recommendation

```
k8s_lab_v2.0/
├── cloud-init/
│   ├── control-plane-1/
│   │   ├── meta-data
│   │   ├── user-data
│   │   └── network-config
│   ├── worker-1/
│   │   ├── meta-data
│   │   ├── user-data
│   │   └── network-config
│   ├── worker-2/
│   │   ├── meta-data
│   │   ├── user-data
│   │   └── network-config
│   └── upstream-router/
│       ├── meta-data
│       ├── user-data
│       └── network-config
├── configs/
│   ├── frr/
│   │   ├── upstream-router.conf
│   │   ├── control-plane-1.conf
│   │   ├── worker-1.conf
│   │   └── worker-2.conf
│   ├── systemd-network/
│   │   └── 20-internal.network
│   └── kubeadm/
│       └── kubeadm-config.yaml
├── disks/                          # Generated: VM disk images (CoW from base)
├── docs/
│   ├── architecture/
│   │   ├── overview.md
│   │   └── bgp-topology.md
│   └── implementation-plan.md
├── images/                         # Downloaded: base cloud images
├── manifests/
│   ├── cilium-bgp-peering.yaml
│   └── test-workloads/
└── Makefile
```

---

## 12 Usage Workflow

```bash
# Download base image
make images

# Create VM disks
make vms

# Generate cloud-init ISOs (from cloud-init/<node>/{user-data,meta-data,network-config})
make cloud-init

# Start all VMs
make up

# Check status
make status

# SSH to control plane
make ssh-control-plane-1

# Stop all VMs
make down
```

---

## Revision History

| Version | Date       | Author    | Changes                     |
|---------|------------|-----------|-----------------------------|
| 1.0     | 2026-01-23 | Generated | Initial implementation plan |
