#!/usr/bin/env bash
# End-to-end checks against the running lab (after make up ... make cilium-bgp).
#
# Needs talosctl, kubectl, cilium (cilium-cli) and jq on the host. Uses the lab's own
# kubeconfig/talosconfig unless KUBECONFIG/TALOSCONFIG are set. Checks run in dependency
# order so the first failure points at the layer that broke.
#
#   E2E_TIMEOUT=300      wait budget per check, in seconds
#   E2E_SKIP_UPSTREAM=1  do not require the eBGP session to the upstream router
#   E2E_KEEP=1           keep the e2e-test namespace after the run
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"
need kubectl jq cilium
TALOSCTL=${TALOSCTL:-$(mkvar TALOSCTL)}
export KUBECONFIG=${KUBECONFIG:-$REPO_ROOT/talos/generated/kubeconfig}
export TALOSCONFIG=${TALOSCONFIG:-$REPO_ROOT/talos/generated/talosconfig}
TALOS_VERSION=$(mkvar TALOS_VERSION)
K8S_VERSION=$(mkvar KUBERNETES_VERSION)
CILIUM_VERSION=$(mkvar CILIUM_VERSION)
TIMEOUT=${E2E_TIMEOUT:-300}
NS=e2e-test
CP_IP6=fd00:100::10
W1_IP6=fd00:100::11
W2_IP6=fd00:100::12
UPSTREAM_IP6=fd00:100::1
WORKERS="worker-1 worker-2"
peer_ip() { case $1 in worker-1) echo "$W1_IP6" ;; worker-2) echo "$W2_IP6" ;; esac; }

frr() { kubectl -n kube-system exec ds/frr-route-reflector -- vtysh -c "$1"; }
peer_established() { # AFI(ipv4Unicast|ipv6Unicast) PEER
  frr 'show bgp summary json' | jq -e --arg afi "$1" --arg p "$2" '.[$afi].peers[$p].state == "Established"'
}
rib_has() { frr "show bgp $1 unicast json" | jq -e --arg p "$2" '.routes[$p] != null'; } # ipv4|ipv6 PREFIX
nodes_json() { kubectl get nodes -o json; }

log "1. Talos: health and versions"
check "talosctl health (control plane + workers)" \
  "$TALOSCTL" health --control-plane-nodes "$CP_IP6" --worker-nodes "$W1_IP6,$W2_IP6" --wait-timeout "${TIMEOUT}s"
server_tags() { "$TALOSCTL" version -n "$CP_IP6,$W1_IP6,$W2_IP6" | awk '/^Server:/ {s=1} s && /Tag:/ {print $2}'; }
check "all 3 nodes run Talos $TALOS_VERSION" \
  test "$(server_tags | sort | uniq -c | awk '{print $1, $2}')" = "3 $TALOS_VERSION"

log "2. Kubernetes nodes"
check "all nodes Ready" kubectl wait --for=condition=Ready node --all --timeout="${TIMEOUT}s"
check "exactly 3 nodes" test "$(nodes_json | jq '.items | length')" = 3
kubelets_ok() { nodes_json | jq -e --arg v "v$K8S_VERSION" '[.items[].status.nodeInfo.kubeletVersion] | all(. == $v)'; }
check "kubelet v$K8S_VERSION on every node" kubelets_ok
primary_ipv6() {
  nodes_json | jq -e '[.items[] | ([.status.addresses[] | select(.type == "InternalIP") | .address][0])] | all(startswith("fd00:100::"))'
}
check "primary InternalIP is the internal IPv6 address on every node" primary_ipv6

log "3. Cilium"
check "cilium DaemonSet rolled out" kubectl -n kube-system rollout status ds/cilium --timeout="${TIMEOUT}s"
check "cilium status healthy" cilium status --wait --wait-duration "${TIMEOUT}s"
cilium_image_ok() {
  kubectl -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].image}' \
    | grep -Eq "cilium:v$CILIUM_VERSION(@|$)"
}
check "cilium agent image is v$CILIUM_VERSION" cilium_image_ok
check "hubble-relay available" kubectl -n kube-system rollout status deploy/hubble-relay --timeout="${TIMEOUT}s"

log "4. FRR Route Reflector (control-plane-1)"
check "frr-route-reflector DaemonSet rolled out" \
  kubectl -n kube-system rollout status ds/frr-route-reflector --timeout="${TIMEOUT}s"
for w in $WORKERS; do
  for afi in ipv4Unicast ipv6Unicast; do
    check "iBGP $afi session with $w ($(peer_ip "$w")) established" \
      wait_for "$TIMEOUT" peer_established "$afi" "$(peer_ip "$w")"
  done
done
if [ -z "${E2E_SKIP_UPSTREAM:-}" ]; then
  for afi in ipv4Unicast ipv6Unicast; do
    check "eBGP $afi session with upstream router ($UPSTREAM_IP6) established" \
      wait_for "$TIMEOUT" peer_established "$afi" "$UPSTREAM_IP6"
  done
else
  printf 'SKIP: eBGP upstream session checks (E2E_SKIP_UPSTREAM=1)\n'
fi

log "5. Cilium BGP (worker side)"
cilium_peer_established() { cilium bgp peers | awk -v n="$1" '$1 == n && tolower($0) ~ /established/ {f=1} END {exit !f}'; }
for w in $WORKERS; do
  check "cilium bgp peers: $w session established" wait_for "$TIMEOUT" cilium_peer_established "$w"
done

log "6. Route propagation"
node_pod_cidrs() { kubectl get node "$1" -o json | jq -r '.spec.podCIDRs[]'; }
# control-plane-1's CIDRs are originated by the RR's `network` statements, which `make frr-rr`
# renders from the Node object, so this also catches a ConfigMap that is stale against the
# CIDRs Kubernetes actually allocated.
for n in control-plane-1 $WORKERS; do
  for cidr in $(node_pod_cidrs "$n"); do
    afi=ipv4
    case $cidr in *:*) afi=ipv6 ;; esac
    check "RR RIB ($afi) carries $n pod CIDR $cidr" wait_for "$TIMEOUT" rib_has "$afi" "$cidr"
  done
done
if [ -z "${E2E_SKIP_UPSTREAM:-}" ]; then
  check "RR RIB carries the IPv6 default route from upstream" wait_for "$TIMEOUT" rib_has ipv6 '::/0'
  check "RR RIB carries the IPv4 default route from upstream" wait_for "$TIMEOUT" rib_has ipv4 '0.0.0.0/0'
fi

log "7. Dual-stack workload connectivity"
cleanup() {
  if [ -z "${E2E_KEEP:-}" ]; then
    kubectl delete -f tests/manifests/e2e-workload.yaml --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
kubectl apply -f tests/manifests/e2e-workload.yaml >/dev/null
check "e2e workload rolled out (one pod per worker)" \
  kubectl -n "$NS" rollout status ds/e2e-agnhost --timeout="${TIMEOUT}s"
pod_on() { kubectl -n "$NS" get pods -l app=e2e-agnhost -o json | jq -r --arg n "$1" '.items[] | select(.spec.nodeName == $n) | .metadata.name'; }
pod_ip() { # POD 4|6
  kubectl -n "$NS" get pod "$1" -o json \
    | jq -r --arg f "$2" '[.status.podIPs[].ip] | map(select(contains(":") == ($f == "6")))[0]'
}
pexec() { kubectl -n "$NS" exec "$1" -- "${@:2}"; }
hostname_via() { [ "$(pexec "$1" curl -gsS --max-time 5 "http://$2:8080/hostname")" = "$3" ]; } # SRC HOST EXPECTED
reachable() { pexec "$1" curl -gsS --max-time 5 -o /dev/null "http://$2:8080/hostname"; }     # SRC HOST
src=$(pod_on worker-1)
dst=$(pod_on worker-2)
if [ -n "$src" ] && [ -n "$dst" ]; then
  dst6=$(pod_ip "$dst" 6)
  dst4=$(pod_ip "$dst" 4)
  check "pod -> pod across nodes over IPv6 ($dst6)" hostname_via "$src" "[$dst6]" "$dst"
  check "pod -> pod across nodes over IPv4 ($dst4)" hostname_via "$src" "$dst4" "$dst"
  svc6=$(kubectl -n "$NS" get svc e2e-agnhost -o jsonpath='{.spec.clusterIPs[0]}')
  svc4=$(kubectl -n "$NS" get svc e2e-agnhost -o jsonpath='{.spec.clusterIPs[1]}')
  check "Service ClusterIP over IPv6 ($svc6)" reachable "$src" "[$svc6]"
  check "Service ClusterIP over IPv4 ($svc4)" reachable "$src" "$svc4"
  check "in-cluster DNS resolves the Service name" reachable "$src" "e2e-agnhost.$NS.svc.cluster.local"
  if [ -z "${E2E_SKIP_UPSTREAM:-}" ]; then
    check "pod reaches the upstream router over IPv6 (TCP 179)" \
      pexec "$src" /agnhost connect "[$UPSTREAM_IP6]:179" --timeout=5s
  fi
else
  fail "e2e workload pods not found on both workers"
fi

summary e2e
