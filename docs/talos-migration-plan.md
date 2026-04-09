# Plan: Migrate k8s_lab from Debian + kubeadm to Talos Linux

## Context

The k8s_lab provisions 4 QEMU aarch64 VMs (Apple Silicon/HVF): 1 upstream router
+ 3 Kubernetes nodes. Currently all run Debian 12 with cloud-init for first-boot
provisioning, followed by ~7 phases of manual SSH work (disable swap, kernel
modules, containerd, systemd-networkd, FRR, kubeadm init/join, Cilium).

Talos Linux is a purpose-built, immutable, API-driven OS for Kubernetes. It
eliminates most manual phases, replaces cloud-init with declarative machine
configs, and replaces kubeadm with `talosctl bootstrap`. The upstream-router
stays on Debian because Talos cannot run FRR as a system daemon (Talos runs
only Kubernetes workloads).

---

## 1. Hybrid Image Strategy

Two base images instead of one:

| Image | Source | Used by |
|---|---|---|
| `debian-12-generic-arm64.qcow2` | cloud.debian.org (existing) | upstream-router |
| `talos-arm64-nocloud.qcow2` | GitHub releases → `qemu-img convert` | control-plane-1, worker-1, worker-2 |

The `nocloud-arm64` variant is chosen because it reads machine config from a
CIDATA ISO at boot — matching the existing `mkisofs` seed ISO pattern.

Download + convert flow:

```bash
curl -L -o images/nocloud-arm64.raw.xz \
  https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/nocloud-arm64.raw.xz
xz -d images/nocloud-arm64.raw.xz
qemu-img convert -f raw -O qcow2 images/nocloud-arm64.raw images/talos-arm64-nocloud.qcow2
```

Per-node CoW disks become OS-aware:

- `disks/control-plane-1.qcow2` backs to `talos-arm64-nocloud.qcow2`
- `disks/upstream-router.qcow2` backs to `debian-12-generic-arm64.qcow2`

---

## 2. Talos Machine Config (replaces cloud-init for k8s nodes)

### Directory structure

```text
talos/
  patches/
    common.yaml              # Kernel modules, sysctls, cluster CIDRs, CNI=none, proxy=disabled
    controlplane.yaml         # etcd, scheduler, controller-manager bind addresses
    worker.yaml               # Worker defaults (may be empty)
    control-plane-1.yaml      # Hostname, MAC-based NIC matching, static IPs
    worker-1.yaml             # Same pattern
    worker-2.yaml             # Same pattern
  generated/                  # gitignored: talosctl output + seed ISOs
```

### Generation flow

```bash
# 1. Generate base configs
talosctl gen config k8s-lab https://192.168.100.10:6443 \
  --output-dir talos/generated \
  --config-patch @talos/patches/common.yaml \
  --config-patch-control-plane @talos/patches/controlplane.yaml \
  --config-patch-worker @talos/patches/worker.yaml

# 2. Per-node patching
talosctl machineconfig patch talos/generated/controlplane.yaml \
  --patch @talos/patches/control-plane-1.yaml \
  --output talos/generated/control-plane-1.yaml

# 3. Seed ISOs (machine config becomes user-data on CIDATA volume)
mkisofs -output talos/generated/control-plane-1-seed.iso \
  -volid cidata -joliet -rock \
  -graft-points user-data=talos/generated/control-plane-1.yaml
```

### Key patch content

**`talos/patches/common.yaml`** (shared across all k8s nodes):

```yaml
machine:
  kernel:
    modules:
      - name: br_netfilter
  sysctls:
    net.ipv4.ip_forward: "1"
    net.ipv6.conf.all.forwarding: "1"
    net.bridge.bridge-nf-call-iptables: "1"
    net.bridge.bridge-nf-call-ip6tables: "1"
cluster:
  network:
    cni:
      name: none              # Cilium installed separately
    podSubnets:
      - 10.244.0.0/16
      - fd00:244::/48
    serviceSubnets:
      - 10.96.0.0/16
      - fd00:96::/112
  proxy:
    disabled: true            # Cilium replaces kube-proxy
```

**`talos/patches/control-plane-1.yaml`** (per-node identity):

```yaml
machine:
  network:
    hostname: control-plane-1
    interfaces:
      - deviceSelector:
          hardwareAddr: "52:54:00:00:01:01"
        addresses:
          - 192.168.100.10/24
        routes:
          - network: 0.0.0.0/0
            gateway: 192.168.100.2
        dhcp: false
      - deviceSelector:
          hardwareAddr: "52:54:00:00:02:01"
        addresses:
          - fd00:100::10/64
        dhcp: false
    nameservers:
      - 192.168.100.3
  nodeLabels:
    bgp-policy: active
```

Worker patches follow the same pattern with their respective MACs and IPs.

---

## 3. Networking Changes

| Aspect | Current (cloud-init) | Talos |
|---|---|---|
| NIC matching | `match.macaddress` in netplan v2 | `deviceSelector.hardwareAddr` |
| IPv6 on internal NIC | Omitted from cloud-init; added manually in Phase 3 via systemd-networkd | Declared in machine config; applied at first boot |
| SLAAC disabled | `IPv6AcceptRA=no` in networkd unit | `dhcp: false` on interface (no RA client) |
| DNS | `nameservers.addresses` | `machine.network.nameservers` |

Both NICs get full static config from boot. No manual Phase 3 step needed.

### QEMU port forwarding additions

Talos API runs on port 50000. Add forwards for `talosctl` access:

```text
control-plane-1: hostfwd=tcp::50000-192.168.100.10:50000
worker-1:        hostfwd=tcp::50001-192.168.100.11:50000
worker-2:        hostfwd=tcp::50002-192.168.100.12:50000
```

SSH port forwards removed for k8s nodes (no sshd on Talos). Keep for
upstream-router.

---

## 4. BGP Architecture Change: eBGP Fan-Out with Cilium BGP

### Problem

FRR cannot run as a native daemon on Talos (no package manager, immutable FS).
Running it as a Talos extension service requires building a custom image via
Image Factory. Running it as a privileged DaemonSet adds complexity.

### Solution

Replace all node-side FRR with **Cilium's built-in BGP control plane**
(GoBGP-based). Cilium is already required for CNI, so this adds zero new
components.

The topology shifts from **iBGP + Route Reflector** (current section 6.1 of
`bgp-topology.md`) to **eBGP Full Fan-Out** (current section 6.2). The
architecture doc already describes this model and notes it's "appropriate for
very small deployments (< 5 nodes)" — which is exactly this lab.

### New topology

```text
        [Upstream Router]           (AS 64513, Debian + FRR)
          /     |      \
     eBGP    eBGP     eBGP
        /       |        \
[cp-1/Cilium] [w-1/Cilium] [w-2/Cilium]   (AS 64512, Cilium BGP)
```

Each Cilium node independently:

- Announces its Pod CIDR to upstream-router
- Receives default route from upstream-router
- Receives other nodes' Pod CIDRs (upstream re-advertises)

### Upstream-router FRR config update

Peers with all 3 nodes directly (instead of only the Route Reflector):

```text
router bgp 64513
 neighbor fd00:100::10 remote-as 64512   # control-plane-1
 neighbor fd00:100::11 remote-as 64512   # worker-1
 neighbor fd00:100::12 remote-as 64512   # worker-2
 # ... address-family config with default-originate for each
```

### Cilium BGP configuration

**`manifests/cilium-values.yaml`** (Helm):

```yaml
ipam:
  mode: kubernetes
kubeProxyReplacement: true
k8sServiceHost: localhost
k8sServicePort: 7445              # Talos KubePrism
ipv4:
  enabled: true
ipv6:
  enabled: true
bgpControlPlane:
  enabled: true
cgroup:
  autoMount:
    enabled: false                # Talos manages cgroups
  hostRoot: /sys/fs/cgroup
hubble:
  enabled: true
  relay:
    enabled: true
```

**`manifests/cilium-bgp.yaml`** (CRDs):

```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPClusterConfig
metadata:
  name: bgp-cluster
spec:
  bgpInstances:
    - name: rack-bgp
      localASN: 64512
      peers:
        - name: upstream-router
          peerASN: 64513
          peerAddress: fd00:100::1
          peerConfigRef:
            name: upstream-peer
---
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPPeerConfig
metadata:
  name: upstream-peer
spec:
  families:
    - afi: ipv4
      safi: unicast
    - afi: ipv6
      safi: unicast
---
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPAdvertisement
metadata:
  name: pod-cidrs
spec:
  advertisements:
    - advertisementType: PodCIDR
```

### Tradeoff

| | Cilium BGP (recommended) | FRR on Talos (alternative) |
|---|---|---|
| Components | Cilium only | Cilium + FRR extension/DaemonSet |
| Image | Standard Talos | Custom Image Factory build |
| Topology | eBGP fan-out | iBGP + RR (current) |
| Debugging | `cilium bgp peers/routes` | `vtysh` in privileged pod |
| Principle fit | Minimal abstraction | More moving parts |

---

## 5. Phase-by-Phase Impact

| Phase | Current | After | Status |
|---|---|---|---|
| 1: Infrastructure Provisioning | Debian qcow2 + cloud-init | Dual images + Talos machine configs | **Modified** |
| 2: Base OS Configuration | SSH: swap, modules, containerd | Talos handles all natively | **Eliminated** |
| 3: Network Configuration | SSH: systemd-networkd static IPv6 | In machine config from boot | **Eliminated** |
| 4: Upstream Router Setup | FRR on Debian | Same, but config updated for 3-peer eBGP | **Modified** |
| 5: BGP with FRRouting | FRR on all k8s nodes | Replaced by Cilium BGP (Phase 8) | **Eliminated** |
| 6: K8s Prerequisites | apt: kubeadm, kubelet, kubectl | Built into Talos | **Eliminated** |
| 7: K8s Bootstrap | `kubeadm init/join` | `talosctl bootstrap` | **Replaced** |
| 8: CNI (Cilium) | Helm install | Same + Talos-specific values + BGP CRDs | **Modified** |
| 9: Validation | SSH-based checks | `talosctl` + `cilium` CLI | **Modified** |

**9 phases collapse to 4 operational steps:**

1. Provision (images, disks, configs, boot)
2. Bootstrap (`talosctl bootstrap`, retrieve kubeconfig)
3. Install Cilium + apply BGP CRDs
4. Validate

---

## 6. Makefile Redesign

### New variables

```makefile
TALOS_VERSION := v1.9.5
TALOS_IMAGE_URL := https://github.com/siderolabs/talos/releases/download/$(TALOS_VERSION)/nocloud-arm64.raw.xz
TALOS_NODES := control-plane-1 worker-1 worker-2
DEBIAN_NODES := upstream-router
CLUSTER_NAME := k8s-lab
CLUSTER_ENDPOINT := https://192.168.100.10:6443
TALOSCONFIG := talos/generated/talosconfig
```

### Target changes summary

| Target | Change |
|---|---|
| `images` | Adds Talos image download + convert |
| `vms` | Split: Talos nodes back to Talos image, upstream to Debian |
| `cloud-init` | Now only covers upstream-router |
| `talos-gen` | **New**: generate base Talos configs |
| `talos-configs` | **New**: per-node patched configs |
| `talos-seed` | **New**: CIDATA ISOs for Talos nodes |
| `seed` | **New**: umbrella for talos-seed + cloud-init |
| `up-*` | Modified: Talos nodes use talos seed ISOs, add port 50000 forward |
| `bootstrap` | **New**: `talosctl bootstrap` |
| `kubeconfig` | **New**: `talosctl kubeconfig` |
| `cilium-install` | **New**: `helm install cilium` |
| `cilium-bgp` | **New**: `kubectl apply -f manifests/cilium-bgp.yaml` |
| `talos-dashboard` | **New**: `talosctl dashboard` |
| `talos-health` | **New**: `talosctl health` |
| `ssh-control-plane-1` | **Removed** (no SSH on Talos) |
| `ssh-worker-{1,2}` | **Removed** |
| `ssh-upstream` | Kept |
| `console-%` | Kept (QEMU serial still works) |
| `clean` | Updated: also removes `talos/generated/` |

---

## 7. Developer Workflow (Before and After)

**Before:**

```bash
make images && make vms && make cloud-init && make up
make ssh-control-plane-1
# ... ~1-2 hours of manual Phase 2-8 commands ...
```

**After:**

```bash
make images && make vms && make talos-gen && make talos-configs && make seed && make up
# Wait ~90s for Talos to boot
make bootstrap        # ~2-3 min
make kubeconfig
make cilium-install
# Wait for Cilium ready
make cilium-bgp
make talos-health     # verify
```

**Day-to-day node access:**

| Task | Before | After |
|---|---|---|
| Logs | SSH + `journalctl` | `talosctl -n <ip> logs <service>` |
| Network debug | SSH + `ip addr/route` | `talosctl -n <ip> get addresses/routes` |
| Packet capture | SSH + `tcpdump` | `talosctl -n <ip> pcap` |
| BGP status | SSH + `vtysh` | `cilium bgp peers` / `cilium bgp routes` |
| Reboot | SSH + `sudo reboot` | `talosctl -n <ip> reboot` |
| Dashboard | N/A | `make talos-dashboard` |
| Serial console | `make console-<node>` | Same |

---

## 8. New Repository Structure

```text
k8s_lab/
+-- Makefile                          # Redesigned
+-- .gitignore                        # Add talos/generated/
+-- cloud-init/
|   +-- upstream-router/              # Kept (only Debian VM)
|       +-- meta-data
|       +-- user-data
|       +-- network-config
+-- talos/                            # NEW
|   +-- patches/
|   |   +-- common.yaml
|   |   +-- controlplane.yaml
|   |   +-- worker.yaml
|   |   +-- control-plane-1.yaml
|   |   +-- worker-1.yaml
|   |   +-- worker-2.yaml
|   +-- generated/                    # gitignored
+-- manifests/                        # NEW
|   +-- cilium-values.yaml
|   +-- cilium-bgp.yaml
+-- docs/
|   +-- implementation-plan.md        # Major rewrite
|   +-- talos-migration-plan.md       # This document
|   +-- architecture/
|       +-- overview.md               # Updated
|       +-- bgp-topology.md           # Updated
+-- TODO.md
+-- .rumdl.toml
+-- disks/                            # gitignored
+-- images/                           # gitignored
```

Remove `cloud-init/control-plane-1/`, `cloud-init/worker-1/`,
`cloud-init/worker-2/`.

---

## 9. Host Prerequisites Update

Add to Nix flakes (implementation-plan.md section 1.2):

```nix
{
  qemu             # unchanged
  socat            # unchanged
  netcat           # unchanged
  kubectl          # unchanged
  kubernetes-helm  # unchanged
  talosctl         # NEW: Talos management CLI
  cilium-cli       # NEW: optional, for cilium bgp/status commands
}
```

---

## 10. Documentation Updates

| File | Changes |
|---|---|
| `docs/implementation-plan.md` | Major rewrite: update prereqs, Phase 1 for dual images + Talos configs, eliminate Phases 2/3/5/6, replace Phase 7 with talosctl, update Phase 4/8/9 |
| `docs/architecture/overview.md` | Section 7: Talos replaces kubeadm. Section 6.2: note Talos for k8s nodes, Debian for router. Section 11: eBGP fan-out replaces iBGP+RR |
| `docs/architecture/bgp-topology.md` | Section 6.1 default model becomes eBGP fan-out. Section 5.3 RR role: note removal rationale. Update diagrams |
| `.gitignore` | Add `talos/generated/` |
| `TODO.md` | Update for new architecture |

---

## 11. Verification Plan

```bash
# 1. Infrastructure
make images && make vms && make talos-gen && make talos-configs && make seed
make up && make status    # all 4 VMs running

# 2. Talos boot
export TALOSCONFIG=talos/generated/talosconfig
talosctl -n 192.168.100.10 version              # reachable
talosctl -n 192.168.100.10 get addresses         # both NICs configured
talosctl -n 192.168.100.11 get addresses
talosctl -n 192.168.100.12 get addresses

# 3. K8s bootstrap
make bootstrap && make kubeconfig
kubectl get nodes                                 # 3 nodes (NotReady)

# 4. Cilium + BGP
make cilium-install
kubectl -n kube-system rollout status ds/cilium
kubectl get nodes                                 # 3 nodes (Ready)
make cilium-bgp

# 5. BGP verification
cilium bgp peers                                  # 3 sessions Established
make ssh-upstream
sudo vtysh -c "show bgp summary"                 # 3 eBGP peers up
sudo vtysh -c "show bgp ipv6 unicast"            # pod CIDRs visible

# 6. Workload test
kubectl create deployment nginx --image=nginx --replicas=3
kubectl get pods -o wide                          # pods across nodes
```

---

## 12. Potential Risks

1. **Talos NoCloud CIDATA format**: The `mkisofs` user-data approach with Talos
   machine config needs validation. Fallback: use
   `talosctl apply-config --insecure` after boot (requires mgmt NIC DHCP
   temporarily).

2. **qemu-img convert preserving EFI partition**: The raw to qcow2 conversion of
   the Talos image must preserve the EFI System Partition. Verify with
   `qemu-img info` after conversion.

3. **Cilium BGP CRD API version**: The `CiliumBGPClusterConfig` API is v2alpha1
   and may change between Cilium releases. Pin to a tested Cilium version.

4. **KubePrism port 7445**: Talos 1.6+ required. Cilium must use
   `k8sServiceHost=localhost`, `k8sServicePort=7445`. Wrong values mean Cilium
   can't reach API server.

---

## 13. Implementation Order

1. Create `talos/patches/` directory + all 6 patch YAML files
2. Create `manifests/` directory with `cilium-values.yaml` and `cilium-bgp.yaml`
3. Update `.gitignore` (add `talos/generated/`)
4. Rewrite `Makefile`
5. Remove `cloud-init/control-plane-1/`, `cloud-init/worker-1/`,
   `cloud-init/worker-2/`
6. Update `docs/implementation-plan.md`
7. Update `docs/architecture/overview.md`
8. Update `docs/architecture/bgp-topology.md`
9. Update `TODO.md`
10. End-to-end test per verification plan
