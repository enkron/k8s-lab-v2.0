#!/usr/bin/env bash
# Render the Talos machine configs exactly like the Makefile does, validate them with
# talosctl, and assert the multi-document structure the lab depends on.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"
need yq
TALOSCTL=${TALOSCTL:-$(mkvar TALOSCTL)}
TALOS_VERSION=$(mkvar TALOS_VERSION)
K8S_VERSION=$(mkvar KUBERNETES_VERSION)
CLUSTER_NAME=$(mkvar CLUSTER_NAME)
CLUSTER_ENDPOINT=$(mkvar CLUSTER_ENDPOINT)
TALOS_INSTALLER_IMAGE=$(mkvar TALOS_INSTALLER_IMAGE)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

client=$("$TALOSCTL" version --client | sed -n 's/^[[:space:]]*Tag:[[:space:]]*//p' | head -1)
log "rendering with talosctl $client (Talos $TALOS_VERSION, Kubernetes $K8S_VERSION)"
"$TALOSCTL" gen config "$CLUSTER_NAME" "$CLUSTER_ENDPOINT" \
  --talos-version "$TALOS_VERSION" \
  --kubernetes-version "$K8S_VERSION" \
  --install-image "$TALOS_INSTALLER_IMAGE" \
  -o "$tmp" --with-docs=false --with-examples=false \
  --config-patch @talos/patches/common.yaml \
  --config-patch-control-plane @talos/patches/controlplane.yaml \
  --config-patch-worker @talos/patches/worker.yaml >/dev/null
for node in control-plane-1 worker-1 worker-2; do
  base=worker
  [ "$node" = control-plane-1 ] && base=controlplane
  "$TALOSCTL" machineconfig patch "$tmp/$base.yaml" --patch "@talos/patches/$node.yaml" \
    -o "$tmp/$node.yaml"
done

for f in controlplane worker control-plane-1 worker-1 worker-2; do
  check "$f.yaml is valid (talosctl validate, cloud mode, strict)" \
    "$TALOSCTL" validate -c "$tmp/$f.yaml" -m cloud --strict
done

# yq does not deep-compare arrays/maps with ==, so list fields are compared through join()
# and maps through to_json. -e only reflects the last result, so multi-document kinds are
# checked by counting: every document of KIND must satisfy EXPR.
# doc KIND EXPR FILE: at least one document of KIND exists and all of them satisfy EXPR.
doc() {
  local total ok
  total=$(yq -N "select(.kind == \"$1\") | .kind" "$3" | grep -c . || true)
  ok=$(yq -N "select(.kind == \"$1\") | select($2) | .kind" "$3" | grep -c . || true)
  [ "$total" -gt 0 ] && [ "$ok" = "$total" ]
}
# named KIND NAME EXPR FILE: the single document KIND/NAME exists and satisfies EXPR.
named() {
  [ "$(yq -N "select(.kind == \"$1\" and .name == \"$2\") | select($3) | .kind" "$4" | grep -c . || true)" = 1 ]
}
# main EXPR FILE: EXPR is true (non-null) in the v1alpha1 (kind-less) document.
main() { yq -e "select(.kind == null) | $1" "$2" >/dev/null 2>&1; }
# count KIND FILE: number of documents of KIND.
count() { yq -N "select(.kind == \"$1\") | .kind" "$2" | grep -c . || true; }

node_checks() { # NODE MGMT_IP IP6 IP4
  local n=$1 cfg=$tmp/$1.yaml key migrated=0
  for key in .cluster.network .cluster.proxy .cluster.apiServer .cluster.controllerManager \
    .cluster.scheduler .cluster.discovery .machine.kubelet .machine.nodeLabels \
    .machine.network .machine.sysctls .machine.kernel .machine.time .machine.registries; do
    if main "$key" "$cfg"; then
      fail "$n: v1alpha1 document still sets $key (it has a multi-document replacement)"
      migrated=1
    fi
  done
  [ "$migrated" = 0 ] && pass "$n: v1alpha1 document carries no migrated fields"
  check "$n: installer image is the Image Factory nocloud installer" \
    doc UnattendedInstallConfig ".installer.image == \"$TALOS_INSTALLER_IMAGE\"" "$cfg"
  check "$n: v1alpha1 keeps machine.certSANs for talosctl via 127.0.0.1" \
    main '(.machine.certSANs | join(",")) == "127.0.0.1,localhost"' "$cfg"
  if [ "$(count KubeFlannelCNIConfig "$cfg")" = 0 ]; then
    pass "$n: no Flannel CNI document (Cilium is the CNI)"
  else
    fail "$n: KubeFlannelCNIConfig present"
  fi
  if [ "$(count DiscoveryServiceConfig "$cfg")" = 0 ]; then
    pass "$n: no DiscoveryServiceConfig (discovery off)"
  else
    fail "$n: DiscoveryServiceConfig present"
  fi
  check "$n: pod subnets are IPv6-first" \
    doc KubeNetworkConfig '(.podSubnets | join(",")) == "fd00:244::/48,10.244.0.0/16"' "$cfg"
  check "$n: service subnets are IPv6-first" \
    doc KubeNetworkConfig '(.serviceSubnets | join(",")) == "fd00:96::/112,10.96.0.0/16"' "$cfg"
  check "$n: per-node CIDR mask sizes are explicit (/24, /64)" \
    doc KubeNetworkConfig '.nodeCIDRMaskSizeIPv4 == 24 and .nodeCIDRMaskSizeIPv6 == 64' "$cfg"
  check "$n: kubelet nodeIP restricted to the internal network" \
    doc KubeNodeConfig '(.nodeIP.validSubnets | join(",")) == "fd00:100::/64,10.100.0.0/24"' "$cfg"
  check "$n: static hostname, generated auto hostname removed" \
    doc HostnameConfig ".hostname == \"$n\" and (has(\"auto\") | not)" "$cfg"
  check "$n: mgmt0 address and default route" \
    named LinkConfig mgmt0 "([.addresses[].address] | join(\",\")) == \"$2/24\" and .routes[0].gateway == \"192.168.100.2\" and (.routes[0] | has(\"destination\") | not)" "$cfg"
  check "$n: int0 dual-stack addresses, IPv6 first" \
    named LinkConfig int0 "([.addresses[].address] | join(\",\")) == \"$3/64,$4/24\"" "$cfg"
  check "$n: NIC aliases are bound by MAC" \
    doc LinkAliasConfig '.selector.match | test("^glob\\(\"52:54:00:00:0[12]:0[123]\", mac\\(link.permanent_addr\\)\\)$")' "$cfg"
  if [ "$(count LinkAliasConfig "$cfg")" = 2 ]; then
    pass "$n: two NIC aliases (mgmt0, int0)"
  else
    fail "$n: expected 2 LinkAliasConfig documents, found $(count LinkAliasConfig "$cfg")"
  fi
  check "$n: resolver uses the SLIRP DNS" doc ResolverConfig '.nameservers[0].address == "192.168.100.3"' "$cfg"
  check "$n: plain NTP without NTS" doc TimeSyncConfig '(.ntp.servers | join(",")) == "time.cloudflare.com" and .ntp.useNTS == false' "$cfg"
  check "$n: br_netfilter module" doc KernelModuleConfig '.name == "br_netfilter"' "$cfg"
  check "$n: forwarding and bridge-nf sysctls" \
    doc SysctlConfig '.params["net.ipv4.ip_forward"] == "1" and .params["net.ipv6.conf.all.forwarding"] == "1" and .params["net.bridge.bridge-nf-call-iptables"] == "1" and .params["net.bridge.bridge-nf-call-ip6tables"] == "1"' "$cfg"
  if [ "$(count RegistryTLSConfig "$cfg")" = 4 ]; then
    pass "$n: four RegistryTLSConfig documents (proxy-intercepted registries)"
  else
    fail "$n: expected 4 RegistryTLSConfig documents, found $(count RegistryTLSConfig "$cfg")"
  fi
}

node_checks control-plane-1 192.168.100.10 fd00:100::10 10.100.0.10
node_checks worker-1 192.168.100.11 fd00:100::11 10.100.0.11
node_checks worker-2 192.168.100.12 fd00:100::12 10.100.0.12

cp=$tmp/control-plane-1.yaml
check "control-plane-1: kube-proxy disabled (Cilium kube-proxy replacement)" doc KubeProxyConfig '.enabled == false' "$cp"
check "control-plane-1: API server SANs for all access paths" \
  doc KubeAPIServerConfig '(.certExtraSANs | join(",")) == "192.168.100.10,fd00:100::10,127.0.0.1" and .extraArgs["bind-address"] == "::"' "$cp"
check "control-plane-1: controller-manager/scheduler bind dual-stack, no CIDR extraArgs" \
  test "$(yq -N -o json -I0 'select(.kind == "KubeControllerManagerConfig" or .kind == "KubeSchedulerConfig") | .extraArgs' "$cp" | sort -u)" = '{"bind-address":"::"}'
check "control-plane-1: etcd advertises on the internal network" main '(.cluster.etcd.advertisedSubnets | join(",")) == "fd00:100::/64"' "$cp"
check "control-plane-1: route-reflector label, control-plane labels kept, no bgp-policy" \
  doc KubeNodeConfig '.labels["node-role.kubernetes.io/route-reflector"] == "" and .labels["node-role.kubernetes.io/control-plane"] == "" and (.labels | has("bgp-policy") | not)' "$cp"
for w in worker-1 worker-2; do
  check "$w: bgp-policy=worker label (Cilium BGP node selector)" doc KubeNodeConfig '.labels["bgp-policy"] == "worker"' "$tmp/$w.yaml"
  if [ "$(count KubeProxyConfig "$tmp/$w.yaml")" = 0 ]; then
    pass "$w: no control-plane-only documents leaked into the worker config"
  else
    fail "$w: KubeProxyConfig present on a worker"
  fi
done

summary validate-talos
