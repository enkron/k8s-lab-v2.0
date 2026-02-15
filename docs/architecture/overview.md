# Kubernetes Local Laboratory - Architectural Design (v2.0)

## 1. At a Glance
- 1 + upstream router + 1 control plane + 2 worker VMs; each node has two NICs
  (mgmt + internal).
- QEMU with KVM (Linux) or HVF (macOS).
- kubeadm bootstraps; `etcd` runs as a static pod.
- Explicit L3 routing without hidden overlays.
- Pod and Service networks are distinct; Pod CIDRs via iBGP (AS 64512).
- IPv6-first; IPv4 kept only where required.

## 2. Purpose and Goals
This design defines a local Kubernetes lab that mirrors production patterns
while staying fully inspectable. It enables experimentation with Kubernetes
internals, CI/CD automation, eBPF networking, and IPv6-first design.

## 3. Scope and Non-Goals
- No managed Kubernetes distributions or cloud-specific networking.
- Lab shortcuts must be explicit and reversible.
- See Design Principles for constraints that must hold across changes.

## 4. Design Principles
- Minimal abstraction: prefer primitives (Linux, QEMU, Kubernetes, BGP).
- Production alignment: decisions should scale to real infrastructure.
- Networking realism: explicit L3 routing; clear node/pod/service separation.
- IPv6-first: IPv6 is the primary target; IPv4 only when needed.
- Observability: deterministic topology, static addressing where useful.

## 5. Topology Overview
### 5.1 Logical Diagram
```
                          [ Host ]
                             |
                  NAT / mgmt network (192.168.100.0/24)
                             |
      +------------+---------+---------+------------+
      |            |                   |            |
[upstream-router] [control-plane-1] [worker-1]  [worker-2]
   NIC1 (mgmt)     NIC1 (mgmt)     NIC1 (mgmt)  NIC1 (mgmt)
   NIC2 (internal)  NIC2 (internal) NIC2 (internal) NIC2 (internal)
      |            |                   |            |
      +------------+---------+---------+------------+
                             |
               internal routed network (fd00:100::/64)
```
Each VM has two NICs: one for management/SSH/API access, one for Kubernetes
internal traffic and BGP peering.

## 6. Compute and Virtualization Model
### 6.1 Virtualization Layer
- QEMU is used directly as the virtualization engine.
- Hardware acceleration:
    - Linux: KVM
    - macOS (Apple Silicon): HVF

No higher-level orchestration (libvirt, UTM) is required, though Makefiles or
scripts may wrap QEMU for convenience.

### 6.2 Node Model
Initial cluster topology:

| Role            | Count | vCPU | RAM   | Description                                         |
|-----------------|-------|------|-------|-----------------------------------------------------|
| Upstream Router | 1     | 1    | 512MB | FRR-based edge router; eBGP peer, default gateway   |
| Control Plane   | 1     | 2    | 2GB   | kube-apiserver, scheduler, controller-manager, etcd |
| Worker Node     | 2     | 2    | 2GB   | Run workloads and CNI datapath                      |

Each node is a full Linux VM.

### 6.3 Upstream Router
The upstream router is a dedicated node that sits at the boundary between the
Kubernetes cluster (AS 64512) and the simulated external network (AS 64513). It
is not a Kubernetes node — it runs no kubelet or container runtime.

**Summary:**
- In production, Kubernetes clusters do not exist in isolation. They connect to
  the rest of the network through edge or Top-of-Rack (ToR) routers. The
  upstream router fills this role, giving the lab a realistic north–south
  boundary to route traffic through.
- Without it, the cluster would be a closed network with no default route and no
  external reachability — BGP peering would have no upstream peer, and there
  would be no way to test traffic leaving the cluster.
- It establishes the AS boundary (64512 ↔ 64513) required for eBGP, which is
  the standard way production clusters exchange routes with infrastructure
  outside the cluster.

**Functions:**
- Runs FRRouting (FRR) as the BGP daemon.
- Peers with Route Reflectors in the cluster via eBGP.
- Advertises default routes (0.0.0.0/0 and ::/0) into the cluster, acting as
  the northbound gateway.
- Receives pod and service CIDRs from the cluster, making them reachable from
  outside.

**Addressing:**
- Management NIC: IPv4 via DHCP (192.168.100.x).
- Internal NIC: static IPv6 fd00:100::1/64.

This node is intentionally lightweight (1 vCPU, 512MB RAM) because it handles
only control-plane BGP sessions and forwards no data-plane traffic in the
current design.

## 7. Kubernetes Bootstrapping Model
- Cluster is initialized using `kubeadm`.
- `etcd` runs as a static pod on the control-plane node.
- No managed Kubernetes distributions are used.

This preserves visibility into TLS bootstrap, certificate rotation, component
manifests, and lifecycle behavior.

## 8. Networking Architecture Overview
The network design separates three layers:
1. Node Network - VM-to-VM connectivity
2. Pod Network - workload IP addressing and routing
3. Service Network - virtual IPs for Kubernetes Services

All routing decisions are explicit and inspectable. See [Design
Principles](#4.-design-principles).

### 8.1 Terminology and CIDRs
| Term            | Meaning                              | Example/CIDR      |
|-----------------|--------------------------------------|-------------------|
| Node network    | VM management + node-to-node traffic | 192.168.100.0/24  |
| Internal net    | Routed node interconnect (L3)        | fd00:100::/64     |
| Pod network     | Per-pod addressing                   | Per-node Pod CIDR |
| Service network | Virtual IPs for Services             | Service CIDRs     |

## 9. Node Network
### 9.1 Interfaces
Each node has two network interfaces:

| Interface | Purpose                                               |
|-----------|-------------------------------------------------------|
| NIC-1     | Management / bootstrap / SSH / API access             |
| NIC-2     | Kubernetes internal traffic (pods, services, routing) |

This mirrors production practices where control and data planes are separated.

### 9.2 Addressing
| Network          | Address | Family | Purpose          |
|------------------|---------|--------|------------------|
| 192.168.100.0/24 | IPv4    | Node   | management (NAT) |
| fd00:100::/64    | IPv6    | Node   | internal routing |

- Management network uses NAT for host access.
- Internal network is routed, not bridged.

## 10. Pod Network vs Service Network
### 10.1 Pod Network
- Each Pod receives its own IP address.
- Pod IPs are routable within the cluster.
- Pod CIDRs are advertised via BGP.

Purpose:
- Direct workload-to-workload communication.
- Foundation for eBPF datapath.

### 10.2 Service Network
- Service IPs are virtual IPs.
- Represent Kubernetes Service objects.
- Backed by kube-proxy replacement (eBPF).

Purpose:
- Stable frontends for dynamic pod sets.
- Load balancing and service discovery.

Pod and Service networks are logically distinct even if implemented by the same
CNI.

## 11. BGP Design
### 11.1 Autonomous System (AS) Structure
- Kubernetes cluster: AS 64512 (private ASN)
- Upstream routers: AS 64513 (private ASN)

This represents typical production separation between infrastructure and edge routing.

### 11.2 eBGP with Route Reflectors
Default topology uses eBGP between nodes and upstream routers, with Route Reflectors
for scalability:

- Upstream routers peer with Route Reflectors via eBGP
- Kubernetes nodes peer with Route Reflectors via iBGP
- Route Reflectors reflect routes between nodes without full mesh

Each node advertises:
- its Pod CIDR
- optionally service CIDRs

Rationale:
- Avoids O(n²) session scaling of full mesh
- Production-aligned (spine-leaf inspired)
- Keeps routing explicit and inspectable
- Scales to larger deployments without redesign

See [BGP Topology Architecture](bgp-topology.md) for detailed peering models.

### 11.3 Future Extension
The design allows later introduction of:
- eBGP peering with ToR routers
- External routability of pods
- Multi-cluster or multi-AS topologies

Without redesigning the cluster.

## 12. IPv6 Strategy
- IPv6 is enabled from day one.
- Static addressing is required for node interfaces.
- SLAAC explicitly disabled (`IPv6AcceptRA=no`).

Rationale:
- **Kubernetes requirement**: Node IPs must be stable; K8s does not handle IP changes at runtime.
- **Data center alignment**: Production servers use static IPv6 addressing, not SLAAC.
- **Deterministic debugging**: Static addresses enable predictable packet tracing and troubleshooting.
- **Security**: Prevents rogue Router Advertisement attacks; no dependency on RA messages.
- **BGP integration**: Static node addresses required for stable BGP peering sessions.

Note: SLAAC is appropriate for end-user devices, not infrastructure servers.

## 13. CNI Direction (Non-Binding)
The lab is designed to support:
- eBPF-based CNI
- BGP-native routing
- IPv6 support
- Policy-driven networking

Assumptions:
- No overlay requirement.
- No mandatory encapsulation.
- Kernel-level datapath visibility.

## 14. Review Checklist
This design allows to:
- Be implemented manually.
- Trace every packet path.
- Scale conceptually to production.
- Evolve without significant rewrites.
- Learning (no / almost no hidden complexity)

## 15. Status
This document represents the baseline architecture. All future changes should
reference this document, justify deviations explicitly, and preserve the
underlying principles.

## 16. Related Documents
- [BGP Topology Architecture](bgp-topology.md) - detailed BGP design, peering
  models, AS structure, failure domains, and routing policy.
