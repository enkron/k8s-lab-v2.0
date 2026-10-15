---
name: bump-deps
description: Bump the lab's pinned dependencies (Talos, Kubernetes, Cilium, FRR,
  Debian image, test images, CI tools). Use when asked to update, bump or check
  versions, or to review what `make deps-outdated` reports. Drives
  scripts/deps.sh for the mechanical part; this skill covers compatibility
  review, release notes, docs and the hand-off to the live-lab upgrade.
argument-hint: "[NAME...] [--level patch|minor|major]"
---

# Bump dependencies

`scripts/deps.yaml` lists every pin, its upstream source, its constraint and
the files that copy it; `scripts/deps.sh` (behind `make deps-outdated`,
`make deps-bump`, `make sync-versions`) does all lookups and edits. Never edit
a pinned value or a derived copy by hand: change the pin through
`make deps-bump`, or correct the registry, then run `make sync-versions`.
The judgment below is what the script cannot do.

## 1. Survey

Run `scripts/deps.sh outdated --json $ARGUMENTS` (names only; drop a
`--level`). For each entry note `current`, `patch`, `minor`, `major`,
`latest`, `blocked`, `constraint`, `note`, `error`. Report lookup errors
instead of guessing a version.

Split the candidates into commits by `group`: `cluster`, `test`, `ci-tools`.
One group per commit; within `cluster`, Talos, Kubernetes and Cilium move as
one tested set.

## 2. Review (cluster group, and anything beyond patch)

Patch releases of tools and test images need no review. For everything else
read the primary sources (WebFetch) before applying:

- Talos: the support matrix of the target minor
  (`https://docs.siderolabs.com/talos/v<minor>/getting-started/support-matrix`;
  talos.dev links redirect away from it) and the release notes/upgrade
  notes. Look for
  machine-config changes that affect `talos/patches/` (the 1.14 move to
  multi-document kinds is the precedent) and for the default Kubernetes
  version.
- Kubernetes: must be inside the Talos support matrix and inside the range
  the target Cilium release is e2e-tested against
  (`https://docs.cilium.io/en/v<minor>/network/kubernetes/compatibility/`).
  The `constraint` on `kubernetes` records that ceiling.
- Cilium: release notes and the upgrade guide for the target minor; check
  that every key in `manifests/cilium-values.yaml` still exists and that the
  BGP CRDs in `manifests/cilium-bgp.yaml` keep their API version.
- FRR (Route Reflector): a minor bump moves the `frr version` header, which
  changes version-gated defaults; read the FRR release notes for default
  changes in bgpd.
- frr-router follows Debian's `frr` package and debian-image is a point
  build of the same release: no review beyond the changelog headline.
- debian-release is manual: a new Debian major means editing
  `DEBIAN_RELEASE` and `DEBIAN_VERSION` together, re-checking cloud-init and
  the router FRR version; propose it, do not do it unasked.
- CI tools: for yamllint and rumdl, CI mirrors the workstation (nix) version;
  run `yamllint --version` / `rumdl --version` and do not bump past them
  unless asked.

When the review moves the compatibility window (for example a Cilium minor
that is tested against a newer Kubernetes), update `constraint` in
`scripts/deps.yaml` with its comment, the triad comment above
`TALOS_VERSION` in the `Makefile` and the paragraph under the README version
table, in the same commit.

If the review finds a breaking change that needs manual edits (patches,
values, manifests), make them in the same commit and list them in the commit
body.

## 3. Apply and validate

```sh
make deps-bump DEPS="<names>" [LEVEL=minor|major] DRY_RUN=1   # preview
make deps-bump DEPS="<names>" [LEVEL=minor|major]
make test
```

`deps-bump` never crosses a `constraint` and runs `sync-versions` itself.
`make test` needs network and a container runtime; if a check fails, fix the
cause, never the check.

For a `cluster` group bump also add a row to the revision history at the end
of `docs/implementation-plan.md` (next version number, today's date, the new
versions), and update README prose that names a minor (for example "Talos
v1.14" in the diagram), which `tests/check-versions.sh` only warns about.

## 4. Hand off the live-lab verification

Do not run anything that changes the lab (`make up`, `cilium-install`,
`frr-rr`, `cilium-bgp`, `talosctl upgrade`, `helm`, `kubectl apply`): give the
user the commands. CI cannot run the lab, so a `cluster` bump is only
verified once the user has run them.

Rebuild (the README's documented path):

```sh
make check-tools                     # talosctl/kubectl skew vs the new pins
make images                          # new Talos/Debian base images
make clean vms talos-gen talos-configs seed up
make bootstrap kubeconfig cilium-install frr-rr cilium-bgp talos-health
make test-e2e
```

In place, for a patch bump of a running lab: `talosctl upgrade --image
"$(make -s print-TALOS_INSTALLER_IMAGE)"` node by node, `talosctl upgrade-k8s
--to <KUBERNETES_VERSION>`, `make cilium-install`, then `make test-e2e`.

If `make check-tools` would fail because nixpkgs does not ship the new
talosctl yet, say so: the env flake needs an override, or
`TALOSCTL=/path/to/talosctl` for the run.

## 5. Commit

Draft one commit per group, in the repository's style, e.g.:

```text
chore: bump Talos to v1.14.3, Kubernetes to 1.36.5, Cilium to 1.20.3

<what changed and why, review findings, held-back versions and why>
```

Commit only when the user asks, with `git add` of the touched files (or
`jj commit`), never `git add -A`. Mention versions the script held back
(`blocked`) and the reason, so the next bump starts from that.
