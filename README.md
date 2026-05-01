# k8s-lab

Local Kubernetes lab on QEMU aarch64 (Apple Silicon / HVF). Production-aligned
architecture with IPv6-first networking, BGP routing, and eBPF datapath.

```text
                        [ macOS Host ]
                             |
                   SLIRP NAT / management
                             |
      +------------+---------+---------+------------+
      |            |                   |            |
 [upstream-     [control-          [worker-1]   [worker-2]
  router]        plane-1]
  Debian 12      Talos v1.13        Talos        Talos
  FRR (eBGP)     FRR pod (RR)      Cilium BGP   Cilium BGP
      |            |                   |            |
      +------------+---------+---------+------------+
                             |
                    VDE switch / internal
                  fd00:100::/64 + 10.100.0.0/24
```

**4 VMs**: 1 upstream router (Debian 12 + FRR) + 3 Kubernetes nodes (Talos Linux).
Dual-NIC per VM: management (SLIRP, host access) + internal (VDE, inter-VM L2).

## Key decisions

- **Talos Linux** -- immutable, API-driven OS; no SSH, declarative machine configs
- **Cilium** -- eBPF CNI with native routing (no VXLAN), kube-proxy replacement
- **iBGP + Route Reflector** -- FRR as privileged pod on control-plane, Cilium
  BGP on workers; eBGP to upstream router. Scales without full mesh
- **IPv6-first dual-stack** -- IPv6 primary for all cluster traffic; IPv4
  secondary where required (Cilium datapath)
- **VDE networking** -- userspace virtual switch for inter-VM L2 (QEMU multicast
  socket is broken on macOS)

## Quick start

```bash
make images         # download Debian + Talos base images
make vms            # create per-node CoW disks
make talos-gen      # generate Talos machine configs
make talos-configs  # patch per-node identity (MACs, IPs)
make seed           # build CIDATA ISOs
make up             # start all VMs (wait ~90s for boot)
make bootstrap      # initialize etcd + control plane
make kubeconfig     # merge kubeconfig into ~/.kube/config
make cilium-install # install Cilium CNI
make frr-rr         # deploy FRR Route Reflector pod
make cilium-bgp     # configure iBGP peering on workers
make talos-health   # verify cluster health
```

See `make help` for all targets.

## Documentation

| Document | Description |
|----------|-------------|
| [Implementation Plan](docs/implementation-plan.md) | Step-by-step build guide: prerequisites, phases, verification checklists |
| [Architecture Overview](docs/architecture/overview.md) | Design principles, topology, networking model, Kubernetes bootstrap |
| [BGP Topology](docs/architecture/bgp-topology.md) | AS structure, peering models (iBGP+RR vs eBGP fan-out), failure domains |
| [Migration Plan](docs/talos-migration-plan.md) | Historical: rationale for Debian/kubeadm to Talos migration |
| [TODO](TODO.md) | Open tasks and future work |

## Repository layout

```text
k8s_lab/
├── Makefile                  # All build/run targets
├── cloud-init/
│   └── upstream-router/      # Debian cloud-init (router only)
├── talos/
│   ├── patches/              # Machine config patches (common + per-node)
│   └── generated/            # gitignored: talosctl output, seed ISOs
├── manifests/
│   ├── cilium-values.yaml    # Helm values (native routing, BGP, Talos)
│   ├── cilium-bgp.yaml       # CiliumBGPClusterConfig CRDs
│   └── frr-route-reflector.yaml  # FRR DaemonSet + ConfigMap
└── docs/
```

## Requirements

- macOS with Apple Silicon (M1+) and HVF
- [Nix](https://nixos.org/download/) with flakes enabled
- ~16 GB RAM, ~50 GB disk

Tools (all via Nix): `qemu`, `talosctl`, `kubectl`, `helm`, `cilium-cli`,
`socat`, `cdrtools` (mkisofs).

## License

[MIT](LICENSE)
