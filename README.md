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
| Debian cloud image build | 20261015-2632 | `Makefile` (`DEBIAN_IMAGE_BUILD`, SHA-512 verified) |

Kubernetes stays on the newest minor that the stable Cilium release is
e2e-tested against (Talos 1.14 itself defaults to 1.37). The machine config
patches use the Talos 1.14 multi-document kinds, so `talosctl` must not be
older than `TALOS_VERSION`; `make check-tools` enforces this. If nixpkgs lags
behind `TALOS_VERSION` after a bump, override the package or point
`TALOSCTL=/path/to/talosctl` at a release binary when running `make`.

## Before you start

- **SSH key for the router**: `cloud-init/upstream-router/user-data` lets
  user `k8s` in only with the key listed under `ssh_authorized_keys`. Put your
  own public key there before `make seed`, or `make ssh-upstream` is refused
  (password login is disabled). Nothing else needs SSH: the Talos nodes have
  no sshd and `make test-e2e` does not use it.
- **Free host ports**: QEMU forwards `127.0.0.1` ports 50000 (Talos API,
  control-plane-1), 6443 (Kubernetes API) and 2200 (SSH to the router); a VM
  fails to start if its port is taken. The forwards listen on loopback only,
  so nothing is exposed to your network. To reach the lab from another
  machine, tunnel through SSH to this host (e.g. `ssh -L 6443:127.0.0.1:6443
  -L 50000:127.0.0.1:50000 <mac>`); `make HOSTFWD_ADDR=0.0.0.0 up` opts into
  listening on every interface. The workers have no forwards: talosctl
  reaches them through control-plane-1.
- **Tools**: see [Requirements](#requirements); `make check-tools` covers the
  version-sensitive ones.

## Quick start

```bash
make check-tools    # talosctl >= TALOS_VERSION, kubectl skew, cilium-cli present
make images         # download Debian + Talos base images
make vms            # create per-node CoW disks
make talos-gen      # generate Talos machine configs
make talos-configs  # patch per-node identity (MACs, IPs)
make seed           # build CIDATA ISOs
make up             # start all VMs
make bootstrap      # initialize etcd + control plane (waits for the Talos API)
make kubeconfig     # merge kubeconfig into ~/.kube/config
make cilium-install # install Cilium CNI (waits for the Kubernetes API)
make frr-rr         # deploy FRR Route Reflector pod
make cilium-bgp     # configure iBGP peering on workers (waits for the CRDs)
make talos-health   # verify cluster health
make test-e2e       # end-to-end checks (BGP, routes, dual-stack connectivity)
```

See `make help` for all targets. The steps can be chained in one `make`
call: `bootstrap`, `cilium-install` and `cilium-bgp` wait for what they
depend on (Talos API, Kubernetes API, the Cilium BGP CRDs that
cilium-operator registers; up to `WAIT_TIMEOUT=300` seconds each) instead of
failing while it comes up, and `bootstrap` is a no-op on an already
bootstrapped cluster.

## Using the lab

| Task | How |
|---|---|
| kubectl | `make kubeconfig` adds and selects the `admin@k8s-lab` context in `~/.kube/config` |
| talosctl by hand | `export TALOSCONFIG=$PWD/talos/generated/talosconfig` (make targets set it themselves) |
| Cluster health / TUI | `make talos-health`, `make talos-dashboard` |
| Router shell | `make ssh-upstream` (`ssh -p 2200 k8s@127.0.0.1`) |
| Hubble flows | `eval "$(make hubble-ca)"`, then `hubble observe -P` |
| Serial console | `make console-<node>`, e.g. `make console-worker-1` (any VM, also before boot completes) |
| VM state | `make status` |
| Stop / resume | `make down`, later `make up`: the VMs boot from their disks, no new `bootstrap` |
| Tear down | `make clean` (keeps images and the PKI), `make nuke` (everything) |

The talosconfig endpoint is `127.0.0.1:50000` (control-plane-1); after
bootstrap, requests for the workers are proxied through it, addressed by
their internal IPs (`fd00:100::11`, `fd00:100::12`).

Hubble Relay serves its API over TLS with a certificate for
`*.hubble-relay.cilium.io`, signed by the CA that Helm generates (`helm
upgrade` keeps it, a rebuilt cluster gets a new one). `make hubble-ca` saves
that CA to `talos/generated/hubble-ca.crt` and prints the `HUBBLE_TLS*`
exports for the `hubble` CLI, so `eval` sets up the current shell; `-P` makes
`hubble` port-forward to the relay itself:

```sh
eval "$(make hubble-ca)"
hubble observe -P --namespace e2e-test
```

The settings live in the shell, not in the global `hubble config`, so other
clusters are not affected.

## Rebuilding after a version bump

A version bump is applied by rebuilding, not by upgrading in place: the
Talos 1.14 config-format migration is simpler on a fresh cluster than through
`talosctl upgrade` and `talosctl upgrade-k8s` (if you do upgrade in place,
`make -s print-TALOS_INSTALLER_IMAGE` gives the Image Factory installer for
`talosctl upgrade --image`). `make clean` stops the VMs and
removes disks and generated configs but keeps the base images and the Talos
secrets bundle (`talos/generated/secrets.yaml`, so the PKI survives); `make
nuke` also removes images and secrets. After bumping `TALOS_VERSION` or
`DEBIAN_IMAGE_BUILD` the new base image is downloaded on `make images`, but
existing disks are not recreated: run `make clean`, then the quick start from
the top. Superseded base images stay in `images/`; delete them by hand.

## Updating dependencies

`scripts/deps.yaml` lists every pinned version (cluster components, the
Debian image build, the e2e test image, CI tools), where to look for new
releases upstream, and which files copy each value.

| Target | What it does |
|---|---|
| `make deps-outdated` | newer upstream releases per pin, by update level |
| `make deps-bump` | move pins to the newest allowed release, then sync |
| `make sync-versions` | copy pinned values into manifests, cloud-init, README |

`make deps-bump` applies patch releases of the cluster components and minor
releases of tools by default. `DEPS="talos cilium"` selects entries,
`LEVEL=minor` raises the level, `DRY_RUN=1` previews. A `constraint` in the
registry (Kubernetes below the newest minor that stable Cilium is tested
against) is never crossed; moving it is a review decision. In Claude Code,
`/bump-deps` runs the whole process: compatibility and release-note review,
the bump, `make test`, docs, and the live-lab commands to run afterwards. CI
posts the `deps-outdated` table to the job summary every Monday.

## Testing

| Target | What it checks | Needs |
|---|---|---|
| `make lint` | yamllint, rumdl, shellcheck, actionlint | nothing (offline) |
| `make validate` | Talos configs rendered with the pinned `talosctl`, `talosctl validate`, structural assertions; Cilium chart rendered and schema-checked with kubeconform (incl. BGP CRDs); FRR `vtysh -C` dry-run of both FRR configs; cloud-init schema; version consistency | network, container runtime |
| `make test` | `lint` + `validate`; runs in GitHub Actions on every push | as above |
| `make test-e2e` | live lab: Talos health and versions, Cilium, iBGP + eBGP sessions, route propagation, dual-stack pod/Service/DNS connectivity, north-south reachability | running lab |

`make test-e2e` takes `E2E_TIMEOUT=<seconds>` (wait budget per check, default
300), `E2E_SKIP_UPSTREAM=1` (do not require the eBGP session to the router)
and `E2E_KEEP=1` (keep the `e2e-test` namespace for debugging).

GitHub-hosted runners cannot run the QEMU/HVF lab (no nested virtualization
on Apple Silicon runners, no KVM on arm64 Linux runners), so the e2e tier
stays local or on a self-hosted Apple Silicon runner. CI
(`.github/workflows/ci.yaml`) runs:

- on every push: `make test`, plus `tests/check-versions.sh --remote`
  (every pinned artifact still exists upstream; reports only, never fails
  the build)
- every Monday: the `make deps-outdated` table in the job summary

Cluster versions come from the Makefile (`make -s print-<VAR>`), CI tool
versions from the workflow `env`; `scripts/deps.yaml` lists both.

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
├── scripts/                  # deps.yaml registry + deps.sh (bump/sync)
├── tests/                    # make test (static) and make test-e2e (live lab)
├── .github/workflows/ci.yaml # make test on push, weekly dependency report
├── .claude/skills/bump-deps/ # /bump-deps: reviewed dependency bumps (Claude Code)
└── docs/
```

## Requirements

- macOS with Apple Silicon (M1+) and HVF
- [Nix](https://nixos.org/download/) with flakes enabled
- ~16 GB RAM, ~50 GB disk

Tools (all via Nix): `gnumake` (GNU Make >= 4; the macOS system `make` 3.81
exits with a hint), `qemu`, `vde2` (resolved with `nix build nixpkgs#vde2`
when `vde_switch` is not on `PATH`), `zstd`, `talosctl` (>= 1.14), `kubectl`,
`helm`, `cilium-cli`, `socat`, `cdrtools` (mkisofs), `curl`, `yq`, `jq`. The
test harness also uses `yamllint`, `rumdl`, `shellcheck`, `actionlint`,
`kubeconform` (`nix shell nixpkgs#<tool>`) and a running container runtime
(`podman` or `docker`) for the FRR dry-run; `cloud-init` for the schema check
is optional locally (skipped when missing, required in CI). The dependency
scripts need `git` and `skopeo`.

## License

[MIT](LICENSE)
