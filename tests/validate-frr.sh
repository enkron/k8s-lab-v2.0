#!/usr/bin/env bash
# Syntax-check both FRR configurations with `vtysh -C` (dry run, needs no running daemons)
# inside the FRR image of the version that will actually run each of them.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"
need yq
FRR_VERSION=$(mkvar FRR_VERSION)
FRR_ROUTER_VERSION=$(mkvar FRR_ROUTER_VERSION)

if ! rt=$(container_runtime); then
  skip "no running container runtime (docker/podman) for the FRR dry-run"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/rr" "$tmp/router"
# The RR's control-plane-1 pod CIDRs are placeholders filled by `make frr-rr`; any CIDR of
# the right family checks the syntax.
yq 'select(.kind == "ConfigMap") | .data["frr.conf"]' manifests/frr-route-reflector.yaml \
  | sed -e 's|@CP_POD_CIDR_IPV4@|10.244.0.0/24|' -e 's|@CP_POD_CIDR_IPV6@|fd00:244::/64|' \
  > "$tmp/rr/frr.conf"
yq '.write_files[] | select(.path == "/etc/frr/frr.conf") | .content' cloud-init/upstream-router/user-data \
  > "$tmp/router/frr.conf"

dryrun() { "$rt" run --rm -v "$1:/w:ro" "quay.io/frrouting/frr:$2" vtysh -C -f /w/frr.conf; }
check "Route Reflector frr.conf is valid for FRR $FRR_VERSION" dryrun "$tmp/rr" "$FRR_VERSION"
check "upstream router frr.conf is valid for FRR $FRR_ROUTER_VERSION" dryrun "$tmp/router" "$FRR_ROUTER_VERSION"

summary validate-frr
