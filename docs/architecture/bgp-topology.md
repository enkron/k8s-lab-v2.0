# BGP Topology Architecture

## 1. Purpose and Scope
This document describes the Border Gateway Protocol (BGP) topology used in the
k8s_lab_v2.0 environment. It complements the main Architecture document by
focusing specifically on routing design, control-plane behavior, and failure
domains related to BGP. The intent is to provide a clear,
implementation-oriented reference for operators and contributors.

Scope includes:
- Physical and logical topology
- BGP roles and responsibilities
- Peering models
- Route advertisement and policy
- Failure handling and convergence
- Operational considerations

## 2. Design Goals
The BGP topology is designed to achieve the following goals:

- Deterministic and predictable routing behavior
- Clear separation of failure domains
- Minimal operational complexity
- Compatibility with common Kubernetes networking stacks (e.g. Cilium, Calico)
- Alignment with lab constraints while reflecting production-grade patterns

Non-goals:
- Internet-scale routing
- Complex traffic engineering using advanced BGP features (e.g. communities for
  multi-tenant policy)

## 3. High-Level Topology Overview
At a high level, the topology follows a hierarchical, spine–leaf-inspired model
adapted for a lab environment:

```
         [External Network]
                |
      +---------+---------+
      |                   |
[Upstream-1]        [Upstream-2]
      |                   |
      +----+----+----+----+
           |    |    |
      [Node-1] [Node-2] [Node-3]
           |    |    |
       [Pods] [Pods] [Pods]
```

- Edge / Upstream Routers
  - Act as default gateways to external networks
  - Provide north–south connectivity

- Leaf / Node Routers
  - Represent Kubernetes worker and control-plane nodes
  - Originate pod and service CIDRs

- Optional Spine / Route-Reflector Layer
  - Used when scaling beyond a small number of nodes
  - Reduces full-mesh requirements

Logical connectivity:
- eBGP is preferred between nodes and upstream routers
- iBGP is used only when route reflectors are introduced

## 4. Autonomous System (AS) Design
### 4.1 AS Numbering Strategy
- A private AS range is used (64512–65534)
- Single-AS design by default for simplicity
- Optional multi-AS design supported for experimentation

Example:
- AS 65000: Kubernetes cluster
- AS 65010: Upstream / edge routers

### 4.2 Rationale
- Single-AS simplifies policy and debugging
- Multi-AS allows testing of realistic eBGP behavior and loop prevention

## 5. BGP Roles and Responsibilities
### 5.1 Upstream / Edge Routers
Responsibilities:
- Advertise default route (0.0.0.0/0, ::/0)
- Optionally advertise external service prefixes
- Enforce inbound and outbound routing policy

Characteristics:
- eBGP neighbors to all leaf/node routers
- No pod or service CIDRs originated

### 5.2 Kubernetes Nodes (Leaf Routers)
Responsibilities:
- Advertise:
  - Node IP CIDRs (if applicable)
  - Pod CIDRs
  - Service CIDRs (depending on CNI mode)

Characteristics:
- Typically one BGP daemon per node (`BIRD`, `FRR`)
- eBGP sessions to upstream routers

### 5.3 Route Reflectors (Optional)
Responsibilities:
- Reduce BGP session count
- Reflect routes between nodes

Characteristics:
- iBGP sessions to clients
- No data-plane traffic
- Deployed only when node count justifies complexity

## 6. Peering Model
### 6.1 Default Model: eBGP Full Fan-Out
- Each node peers with all upstream routers
- No node-to-node peering

```
[Upstream-1]              [Upstream-2]
     |  \                  /  |
     |   \                /   |
     |    \              /    |
     |     \            /     |
     |      \          /      |
     |       \        /       |
     |        \      /        |
     |         \    /         |
  [cp-1]   [worker-1]   [worker-2]
(AS 64512)  (AS 64512)   (AS 64512)
```

Pros:
- Simple mental model
- Fast convergence
- Clear failure boundaries

Cons:
- Session count grows with number of nodes

### 6.2 Alternative Model: iBGP with Route Reflectors
- Nodes peer only with route reflectors
- Reflectors peer with upstream routers

```
  [Upstream-1]    [Upstream-2]
         |              |
    +----+----+    +----+----+
    |         |    |         |
  [RR-1]    [RR-2]  (Route Reflectors, AS 64512)
    |         |
+---+----+----+---+
|   |    |    |   |
[cp-1] [worker-1] [worker-2] [worker-N]
```

Pros:
- Scales better

Cons:
- Additional control-plane complexity
- Reflector failure becomes critical

## 7. Route Advertisement and Policy
### 7.1 Advertised Prefixes
Nodes may advertise:
- Pod CIDRs (primary)
- Service CIDRs (optional, depending on CNI)
- Node loopback addresses (for control-plane stability)

Example:
- cp-1 advertises: fd00:100::10/128 (node), 10.244.0.0/24 (pod CIDR)
- worker-1 advertises: fd00:100::11/128 (node), 10.244.1.0/24 (pod CIDR)
- worker-2 advertises: fd00:100::12/128 (node), 10.244.2.0/24 (pod CIDR)

Upstream routers advertise:
- Default route
- Optional lab-external prefixes

### 7.2 Policy Principles
- Explicit allow-lists for advertised prefixes
- Reject unexpected or overly broad prefixes
- Prefer shortest AS path by default

No aggressive traffic engineering is applied unless explicitly enabled for
experiments.

## 8. Failure Domains and Convergence
### 8.1 Node Failure
- Loss of BGP session withdraws pod/service prefixes
- Traffic reroutes to remaining nodes
- No impact beyond affected workloads

```
Before Failure:
[Upstream]
    |
  [Node-1] --> [Pods: 10.244.1.0/24]
  [Node-2] --> [Pods: 10.244.2.0/24]
  [Node-3] --> [Pods: 10.244.3.0/24]

After Node-2 Failure:
[Upstream]
    |
  [Node-1] --> [Pods: 10.244.1.0/24]
  [Node-2] --> [X withdrawn]
  [Node-3] --> [Pods: 10.244.3.0/24]
```

### 8.2 Upstream Router Failure
- Nodes maintain sessions to multiple upstreams
- ECMP or best-path selection handles failover

### 8.3 Route Reflector Failure (If Used)
- Clients lose reflected routes
- Mitigated by deploying at least two reflectors

## 9. IPv6 Considerations
- Dual-stack BGP is supported
- IPv4 and IPv6 sessions are independent
- Same policy model applies to both families

## 10. Security Considerations
- BGP sessions are restricted by IP allow-lists
- TTL security (GTSM) enabled where supported
- MD5 or TCP-AO authentication optional in lab

No assumption is made about hostile networks, but misconfiguration is treated
as a primary risk.

## 11. Observability and Operations
Recommended practices:
- Export BGP metrics (session state, prefix count)
- Log route changes at INFO level
- Periodically validate RIB vs expected state

Common tools:
- `birdc`, `vtysh`
- Prometheus exporters
- Packet capture for session debugging

## 12. Future Extensions
Potential evolutions of the topology:
- Dedicated service AS
- BGP communities for policy experiments
- Integration with external load balancers
- Simulation of internet-style peering

## 13. Related Documents
- [Architecture Overview](overview.md) - main architecture design covering
compute, networking, and Kubernetes bootstrap

This document should be read together with the main Architecture document and
kept in sync as topology or design assumptions evolve.
