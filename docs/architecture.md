Kubernetes Local Laboratory – Architectural Design (v2.0)

1. Purpose and Goals

This document defines the initial architectural design for a local Kubernetes
laboratory intended to:
    - Closely resemble future production bare-metal or VM-based Kubernetes deployments
    - Provide full transparency into cluster bootstrapping, networking, routing, and control-plane behavior
    - Serve as a long-lived environment for experimentation with:
        - Kubernetes internals
        - CI/CD pipelines and automation
        - eBPF-based networking
        - IPv6-first designs
        - Custom controllers and CRDs

This document is design-only. It intentionally avoids implementation scripts or
automation so that all concepts can be understood, reviewed, and implemented
manually.


2. Design Principles

    1. Minimal abstraction
        - Avoid vendor-specific orchestration layers
        - Prefer primitives (Linux, QEMU, Kubernetes, BGP)
    2. Production alignment
        - Decisions should scale conceptually to real infrastructure
        - Lab shortcuts must be explicit and reversible
    3. Networking realism
        - Explicit L3 routing
        - No hidden overlays by default
        - Clear separation of responsibilities (node, pod, service)
    4. IPv6-first mindset
        - IPv6 as a first-class design target
        - IPv4 retained only where pragmatically required
    5. Observability and debuggability
        - Static addressing where helpful
        - Deterministic topology
        - Simple failure domains


3. Compute and Virtualization Model

3.1 Virtualization Layer
    - QEMU is used directly as the virtualization engine
    - Hardware acceleration:
        - Linux: KVM
        - macOS (Apple Silicon): HVF

No higher-level orchestration (libvirt, UTM) is required for the core design,
though Makefiles or scripts may wrap QEMU for convenience.

3.2 Node Model

Initial cluster topology:

Role    Count    Description
Control Plane    1    kube-apiserver, scheduler, controller-manager, etcd
Worker Nodes    2    Run workloads and CNI datapath

Each node is a full Linux VM.


4. Kubernetes Bootstrapping Model
    - Cluster is initialized using kubeadm
    - etcd runs as a static pod on the control-plane node
    - No managed Kubernetes distributions are used

This preserves full visibility into:
    - TLS bootstrap
    - certificate rotation
    - component manifests
    - cluster lifecycle behavior


5. Networking Architecture Overview

The network design intentionally separates concerns into three layers:
    1. Node Network – VM-to-VM connectivity
    2. Pod Network – workload IP addressing and routing
    3. Service Network – virtual IPs for Kubernetes Services

All routing decisions are explicit and inspectable.


6. Node Network

6.1 Interfaces

Each node has two network interfaces:

Interface    Purpose
NIC-1    Management / bootstrap / SSH / API access
NIC-2    Kubernetes internal traffic (pods, services, routing)

This mirrors common production practices where control and data planes are
logically separated.

6.2 Addressing

Network    Address Family    Purpose
192.168.100.0/24    IPv4    Node management (NAT)
fd00:100::/64    IPv6    Node internal routing

- Management network uses NAT for host access
- Internal network is routed, not bridged


7. Pod Network vs Service Network

7.1 Pod Network
    - Each Pod receives its own IP address
    - Pod IPs are routable within the cluster
    - Pod CIDRs are advertised via BGP

Purpose:
    - Direct workload-to-workload communication
    - Foundation for eBPF datapath

7.2 Service Network
    - Service IPs are virtual IPs
    - Represent Kubernetes Service objects
    - Backed by kube-proxy replacement (eBPF)

Purpose:
    - Stable frontends for dynamic pod sets
    - Load balancing and service discovery

Pod and Service networks are logically distinct even if implemented by the same
CNI.


8. BGP Design

8.1 Autonomous System (AS)
    - All nodes belong to one AS
    - Private ASN: 64512

This represents:
    - Single administrative control
    - Unified routing policy
    - One cluster / one fabric

8.2 iBGP Topology
    - iBGP sessions established between all nodes
    - Each node advertises:
        - its Pod CIDR
        - optionally service CIDRs

No external BGP peers are assumed at this stage.

8.3 Future Extension

The design allows later introduction of:
    - eBGP peering with ToR routers
    - External routability of pods
    - Multi-cluster or multi-AS topologies

Without redesigning the cluster.


9. IPv6 Strategy
    - IPv6 is enabled from day one
    - Static addressing is preferred
    - No SLAAC dependency

Rationale:
    - Server environments do not rely on router advertisements
    - Predictable addressing aids debugging
    - Aligns with modern data-center practices

IPv6 is required for:
    - Pod networking
    - eBPF datapath testing
    - Future dual-stack or IPv6-only scenarios


10. CNI Direction (Non-Binding)

The lab is designed to support:
    - eBPF-based CNI
    - BGP-native routing
    - IPv6 support
    - Policy-driven networking

Specific CNI choice is intentionally deferred.

The architecture assumes:
    - No overlay requirement
    - No mandatory encapsulation
    - Kernel-level datapath visibility


11. What This Design Explicitly Avoids
    - Managed Kubernetes distributions
    - Cloud-specific networking abstractions
    - Implicit overlays
    - SLAAC-only IPv6 designs
    - Vendor-locked tooling


12. Review Checklist

This design answers “yes” to:
    - Can it be implemented manually?
    - Can every packet path be traced?
    - Does it scale conceptually to production?
    - Can it evolve without rewrites?
    - Does it encourage learning, not hiding complexity?


13. Status

This document represents the baseline architecture.

All future changes should:
    - reference this document
    - justify deviations explicitly
    - preserve the underlying principles
