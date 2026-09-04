# k8s-lab

[![ci](https://github.com/enkron/k8s-lab-v2.0/actions/workflows/ci.yaml/badge.svg)](https://github.com/enkron/k8s-lab-v2.0/actions/workflows/ci.yaml)

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
  Debian 13      Talos v1.14        Talos        Talos
  FRR (eBGP)     FRR pod (RR)      Cilium BGP   Cilium BGP
      |            |                   |            |
      +------------+---------+---------+------------+
                             |
                    VDE switch / internal
                  fd00:100::/64 + 10.100.0.0/24
```

**4 VMs**: 1 upstream router (Debian 13 + FRR) + 3 Kubernetes nodes (Talos
Linux). Dual-NIC per VM: management (SLIRP, host access) + internal (VDE,
inter-VM L2).

## Key decisions

- **Talos Linux** -- immutable, API-driven OS; no SSH, declarative machine
  configs (Talos 1.14 multi-document format)
- **Cilium** -- eBPF CNI with native routing (no VXLAN), kube-proxy replacement
- **iBGP + Route Reflector** -- FRR as privileged pod on control-plane, Cilium
  BGP on workers; eBGP to upstream router. Scales without full mesh
- **IPv6-first dual-stack** -- IPv6 primary for all cluster traffic; IPv4
  secondary where required (Cilium datapath)
- **VDE networking** -- userspace virtual switch for inter-VM L2 (QEMU multicast
  socket is broken on macOS)
- **Reproducible router** -- cloud-init installs and configures FRR on the
  upstream router at first boot; no manual steps anywhere

## Versions

| Component | Version | Pinned in |
|---|---|---|
| Talos Linux | v1.14.0 | `Makefile` (`TALOS_VERSION`) |
| Kubernetes | 1.36.4 | `Makefile` (`KUBERNETES_VERSION`) |
| Cilium (Helm chart) | 1.20.1 | `Makefile` (`CILIUM_VERSION`) |
| FRR (Route Reflector pod) | 10.7.1 | `Makefile` (`FRR_VERSION`), mirrored in the manifest |
| FRR (upstream router) | 10.3 (Debian 13 package) | `Makefile` (`FRR_ROUTER_VERSION`, check only) |
| Debian (upstream router) | 13 trixie | `Makefile` (`DEBIAN_RELEASE`) |

Kubernetes stays on the newest minor that the stable Cilium release is
e2e-tested against (Talos 1.14 itself defaults to 1.37). The machine config
patches use the Talos 1.14 multi-document kinds, so `talosctl` must not be
older than `TALOS_VERSION`; `make check-tools` enforces this. Until nixpkgs
ships talosctl 1.14, override the package in the env flake or point
`TALOSCTL=/path/to/talosctl` at a release binary when running `make`.

## Quick start

```bash
make check-tools    # talosctl/kubectl/cilium-cli match the pinned versions
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
make test-e2e       # end-to-end checks (BGP, routes, dual-stack connectivity)
```

See `make help` for all targets.

A version bump is applied by rebuilding, not by upgrading in place: the
Talos 1.14 config-format migration is simpler on a fresh cluster than through
`talosctl upgrade` and `talosctl upgrade-k8s` (if you do upgrade in place,
`make -s print-TALOS_INSTALLER_IMAGE` gives the Image Factory installer for
`talosctl upgrade --image`). `make clean` stops the VMs and
removes disks and generated configs but keeps the base images and the Talos
secrets bundle (`talos/generated/secrets.yaml`, so the PKI survives); `make
nuke` also removes images and secrets. After bumping `TALOS_VERSION` the new
base image is downloaded on `make images`, but existing disks are not
recreated: run `make clean vms`. Then continue with the quick start.

## Testing

| Target | What it checks | Needs |
|---|---|---|
| `make lint` | yamllint, rumdl, shellcheck, actionlint | nothing (offline) |
| `make validate` | Talos configs rendered with the pinned `talosctl`, `talosctl validate`, structural assertions; Cilium chart rendered and schema-checked with kubeconform (incl. BGP CRDs); FRR `vtysh -C` dry-run of both FRR configs; cloud-init schema; version consistency | network, container runtime |
| `make test` | `lint` + `validate`; runs in GitHub Actions on every push | as above |
| `make test-e2e` | live lab: Talos health and versions, Cilium, iBGP + eBGP sessions, route propagation, dual-stack pod/Service/DNS connectivity, north-south reachability | running lab |

GitHub-hosted runners cannot run the QEMU/HVF lab (no nested virtualization
on Apple Silicon runners, no KVM on arm64 Linux runners), so the e2e tier
stays local or on a self-hosted Apple Silicon runner. CI reads every pinned
version from the Makefile (`make -s print-<VAR>`), which is the single source
of truth.

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
├── Makefile                  # All build/run/test targets; pins every version
├── cloud-init/
│   └── upstream-router/      # Debian cloud-init (router: network + FRR)
├── talos/
│   ├── patches/              # Machine config patches (common + per-node)
│   └── generated/            # gitignored: talosctl output, seed ISOs
├── manifests/
│   ├── cilium-values.yaml    # Helm values (native routing, BGP, Talos)
│   ├── cilium-bgp.yaml       # CiliumBGPClusterConfig CRDs
│   └── frr-route-reflector.yaml  # FRR DaemonSet + ConfigMap
├── tests/                    # make test (static) and make test-e2e (live lab)
├── .github/workflows/ci.yaml # runs make test on every push
└── docs/
```

## Requirements

- macOS with Apple Silicon (M1+) and HVF
- [Nix](https://nixos.org/download/) with flakes enabled
- ~16 GB RAM, ~50 GB disk

Tools (all via Nix): `gnumake` (GNU Make >= 4; the macOS system `make` 3.81
exits with a hint), `qemu`, `vde2`, `zstd`, `talosctl` (>= 1.14), `kubectl`,
`helm`, `cilium-cli`, `socat`, `cdrtools` (mkisofs), `yq`, `jq`. The test
harness also uses `yamllint`, `rumdl`, `shellcheck`, `actionlint`,
`kubeconform` (`nix shell nixpkgs#<tool>`) and a running container runtime
(`podman`) for the FRR dry-run.

## License

[MIT](LICENSE)
