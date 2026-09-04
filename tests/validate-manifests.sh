#!/usr/bin/env bash
# Render the pinned Cilium chart with the lab values and schema-check every Kubernetes
# manifest with kubeconform: core schemas for the pinned Kubernetes version, Cilium CRD
# schemas from the datreeio CRDs-catalog. Needs network; caches under .cache/.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"
need helm kubeconform curl yq
CILIUM_VERSION=$(mkvar CILIUM_VERSION)
K8S_VERSION=$(mkvar KUBERNETES_VERSION)
cache=$REPO_ROOT/.cache
mkdir -p "$cache/kubeconform"

chart=$cache/cilium-$CILIUM_VERSION.tgz
if [ ! -s "$chart" ]; then
  log "downloading Cilium chart $CILIUM_VERSION"
  curl -fsSL --retry 3 -o "$chart" "https://helm.cilium.io/cilium-$CILIUM_VERSION.tgz"
fi

CRD_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
kc() {
  kubeconform -strict -summary -kubernetes-version "$K8S_VERSION" -cache "$cache/kubeconform" \
    -schema-location default -schema-location "$CRD_SCHEMAS" "$@"
}

rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT
log "helm template cilium $CILIUM_VERSION with manifests/cilium-values.yaml"
# helm validates the values against the chart's values.schema.json while rendering.
render() {
  helm template cilium "$chart" --namespace kube-system --kube-version "$K8S_VERSION" \
    -f manifests/cilium-values.yaml > "$rendered"
}
check "Cilium chart renders (values accepted by the chart schema)" render
check "rendered Cilium objects pass kubeconform" kc "$rendered"

# The values file must keep producing the datapath the lab is built around.
cfg() { yq -e "select(.kind == \"ConfigMap\" and .metadata.name == \"cilium-config\") | .data[\"$1\"] == \"$2\"" "$rendered" >/dev/null; }
check "cilium-config: kube-proxy replacement on" cfg kube-proxy-replacement true
check "cilium-config: native routing (no overlay)" cfg routing-mode native
check "cilium-config: BGP control plane on" cfg enable-bgp-control-plane true
check "cilium-config: eBPF masquerade on" cfg enable-bpf-masquerade true
check "cilium-config: dual-stack" cfg enable-ipv6 true
# k8sServiceHost/Port land in the agent's environment, not in the ConfigMap.
agent_env() {
  yq -e "select(.kind == \"DaemonSet\" and .metadata.name == \"cilium\") | .spec.template.spec.containers[0].env[] | select(.name == \"$1\") | .value == \"$2\"" "$rendered" >/dev/null
}
check "cilium agent: KubePrism API endpoint (localhost:7445)" agent_env KUBERNETES_SERVICE_PORT 7445

log "kubeconform on repo manifests"
check "manifests/*.yaml and tests/manifests/*.yaml pass kubeconform (incl. Cilium BGP CRDs)" \
  kc manifests/cilium-bgp.yaml manifests/frr-route-reflector.yaml tests/manifests/e2e-workload.yaml

summary validate-manifests
