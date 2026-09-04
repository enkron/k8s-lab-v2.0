#!/usr/bin/env bash
# Version consistency: the Makefile is the single source of truth; everything that repeats a
# version elsewhere must agree with it. With --remote, also verify that every pinned
# artifact exists upstream (run by the non-blocking CI job, since upstream availability is
# not something a push can regress).
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"
need yq
TALOS_VERSION=$(mkvar TALOS_VERSION)
K8S_VERSION=$(mkvar KUBERNETES_VERSION)
CILIUM_VERSION=$(mkvar CILIUM_VERSION)
FRR_VERSION=$(mkvar FRR_VERSION)
FRR_ROUTER_VERSION=$(mkvar FRR_ROUTER_VERSION)
DEBIAN_VERSION=$(mkvar DEBIAN_VERSION)
TALOS_IMAGE_URL=$(mkvar TALOS_IMAGE_URL)
DEBIAN_IMAGE_URL=$(mkvar DEBIAN_IMAGE_URL)

minor() { local v=${1#v}; printf '%s\n' "${v%.*}"; } # v1.14.0 -> 1.14, 10.7.1 -> 10.7

rr_image=$(yq 'select(.kind == "DaemonSet") | .spec.template.spec.containers[0].image' manifests/frr-route-reflector.yaml)
if [ "$rr_image" = "quay.io/frrouting/frr:$FRR_VERSION" ]; then
  pass "Route Reflector image $rr_image matches FRR_VERSION"
else
  fail "Route Reflector image is $rr_image, FRR_VERSION is $FRR_VERSION"
fi
rr_header=$(yq 'select(.kind == "ConfigMap") | .data["frr.conf"]' manifests/frr-route-reflector.yaml | sed -n 's/^frr version //p')
if [ "$rr_header" = "$(minor "$FRR_VERSION")" ]; then
  pass "Route Reflector 'frr version $rr_header' header matches FRR_VERSION"
else
  fail "Route Reflector header is 'frr version $rr_header', expected $(minor "$FRR_VERSION")"
fi
router_header=$(yq '.write_files[] | select(.path == "/etc/frr/frr.conf") | .content' cloud-init/upstream-router/user-data | sed -n 's/^frr version //p')
if [ "$router_header" = "$(minor "$FRR_ROUTER_VERSION")" ]; then
  pass "upstream router 'frr version $router_header' header matches FRR_ROUTER_VERSION"
else
  fail "upstream router header is 'frr version $router_header', expected $(minor "$FRR_ROUTER_VERSION")"
fi
# Prose anchors are warnings: they drift on innocent rewording.
anchor() { # TEXT
  if grep -q "$1" README.md; then pass "README mentions $1"; else warn "README does not mention $1"; fi
}
anchor "Talos v$(minor "$TALOS_VERSION")"
anchor "Debian $DEBIAN_VERSION"

if [ "${1:-}" = --remote ]; then
  need curl jq
  head_ok() { curl -fsSIL --retry 3 -o /dev/null "$1"; }
  check "Talos image exists: $TALOS_IMAGE_URL" head_ok "$TALOS_IMAGE_URL"
  check "Debian image exists: $DEBIAN_IMAGE_URL" head_ok "$DEBIAN_IMAGE_URL"
  check "Kubernetes v$K8S_VERSION release exists (kubectl binary)" \
    head_ok "https://dl.k8s.io/release/v$K8S_VERSION/bin/linux/amd64/kubectl"
  chart_ok() {
    curl -fsSL --retry 3 https://helm.cilium.io/index.yaml \
      | yq -e ".entries.cilium[] | select(.version == \"$1\") | .version" >/dev/null
  }
  check "Cilium chart $CILIUM_VERSION is in the Helm index" chart_ok "$CILIUM_VERSION"
  quay_ok() {
    curl -fsSL --retry 3 "https://quay.io/api/v1/repository/frrouting/frr/tag/?specificTag=$1&onlyActiveTags=true" \
      | jq -e '.tags | length > 0' >/dev/null
  }
  check "FRR image tag $FRR_VERSION exists on quay.io" quay_ok "$FRR_VERSION"
  check "FRR image tag $FRR_ROUTER_VERSION exists on quay.io" quay_ok "$FRR_ROUTER_VERSION"
fi

summary check-versions
