#!/usr/bin/env bash
# Render the Talos machine configs through the Makefile's own rules into a scratch directory,
# validate them with talosctl, and assert the multi-document structure the lab depends on.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"
need yq openssl
TALOSCTL=${TALOSCTL:-$(mkvar TALOSCTL)}
export TALOSCTL
TALOS_VERSION=$(mkvar TALOS_VERSION)
K8S_VERSION=$(mkvar KUBERNETES_VERSION)
TALOS_INSTALLER_IMAGE=$(mkvar TALOS_INSTALLER_IMAGE)
NODES=$(mkvar TALOS_NODES)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# render DIR [PROXY_CA]: the base and per-node configs, built by the Makefile's own rules with
# TALOS_GEN_DIR pointed at DIR (a fresh secrets bundle included), so the test exercises the
# exact talosctl invocations, the proxy patch and the per-node patch template.
render() {
  local dir=$1 node targets="$1/controlplane.yaml $1/worker.yaml"
  for node in $NODES; do targets="$targets $dir/$node.yaml"; done
  mkdir -p "$dir"
  # shellcheck disable=SC2086 # word-split the target list
  make -s -C "$REPO_ROOT" TALOS_GEN_DIR="$dir" PROXY_CA="${2:-}" $targets >/dev/null 2>"$dir/make.log" \
    || { cat "$dir/make.log" >&2; return 1; }
}

client=$("$TALOSCTL" version --client | sed -n 's/^[[:space:]]*Tag:[[:space:]]*//p' | head -1)
log "rendering with talosctl $client (Talos $TALOS_VERSION, Kubernetes $K8S_VERSION)"
render "$tmp"

for f in controlplane worker $NODES; do
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

node_checks() { # NODE: the node's addressing comes from the Makefile inventory
  local n=$1 cfg=$tmp/$1.yaml key migrated=0
  local mgmt ip6 ip4 mac_mgmt mac_int
  mgmt=$(mkvar "IP_MGMT_$n")
  ip6=$(mkvar "IP_INTERNAL_$n")
  ip4=$(mkvar "IP4_INTERNAL_$n")
  mac_mgmt=$(mkvar "MAC_MGMT_$n")
  mac_int=$(mkvar "MAC_INTERNAL_$n")
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
    named LinkConfig mgmt0 "([.addresses[].address] | join(\",\")) == \"$mgmt/24\" and .routes[0].gateway == \"$MGMT_GW\" and (.routes[0] | has(\"destination\") | not)" "$cfg"
  check "$n: int0 dual-stack addresses, IPv6 first" \
    named LinkConfig int0 "([.addresses[].address] | join(\",\")) == \"$ip6/64,$ip4/24\"" "$cfg"
  check "$n: mgmt0 alias bound by MAC $mac_mgmt" \
    named LinkAliasConfig mgmt0 ".selector.match == \"glob(\\\"$mac_mgmt\\\", mac(link.permanent_addr))\"" "$cfg"
  check "$n: int0 alias bound by MAC $mac_int" \
    named LinkAliasConfig int0 ".selector.match == \"glob(\\\"$mac_int\\\", mac(link.permanent_addr))\"" "$cfg"
  if [ "$(count LinkAliasConfig "$cfg")" = 2 ]; then
    pass "$n: two NIC aliases (mgmt0, int0)"
  else
    fail "$n: expected 2 LinkAliasConfig documents, found $(count LinkAliasConfig "$cfg")"
  fi
  check "$n: resolver uses the SLIRP DNS" doc ResolverConfig ".nameservers[0].address == \"$MGMT_DNS\"" "$cfg"
  check "$n: IPv6 forwarding on all interfaces (the rest are Talos defaults)" \
    doc SysctlConfig '(.params | to_json(0)) == "{\"net.ipv6.conf.all.forwarding\":\"1\"}"' "$cfg"
  local kind
  for kind in KernelModuleConfig RegistryTLSConfig TimeSyncConfig TrustedRootsConfig; do
    if [ "$(count "$kind" "$cfg")" = 0 ]; then
      pass "$n: no $kind (Talos defaults; verified TLS and NTS without PROXY_CA)"
    else
      fail "$n: unexpected $kind document"
    fi
  done
}

MGMT_GW=$(mkvar MGMT_GW)
MGMT_DNS=$(mkvar MGMT_DNS)
for node in $NODES; do node_checks "$node"; done

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

# Opt-in proxy patch: render again with a throwaway self-signed CA as PROXY_CA (CRLF line
# endings, like a bundle exported from the macOS keychain).
log "rendering with PROXY_CA"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
  -subj /CN=k8s-lab-test-proxy -keyout "$tmp/ca.key" -out "$tmp/ca.pem" 2>/dev/null
sed 's/$/\r/' "$tmp/ca.pem" > "$tmp/ca-crlf.pem"
render "$tmp/proxy" "$tmp/ca-crlf.pem"
ca_pem=$(cat "$tmp/ca.pem")
export ca_pem
for f in $NODES; do
  cfg=$tmp/proxy/$f.yaml
  check "$f (PROXY_CA): valid (talosctl validate, cloud mode, strict)" \
    "$TALOSCTL" validate -c "$cfg" -m cloud --strict
  check "$f (PROXY_CA): TrustedRootsConfig carries the CA without CRs" \
    named TrustedRootsConfig proxy-ca '(.certificates | trim) == (strenv(ca_pem) | trim)' "$cfg"
  check "$f (PROXY_CA): plain NTP without NTS" \
    doc TimeSyncConfig '(.ntp.servers | join(",")) == "time.cloudflare.com" and .ntp.useNTS == false' "$cfg"
  if [ "$(count RegistryTLSConfig "$cfg")" = 0 ]; then
    pass "$f (PROXY_CA): registry TLS verification stays on"
  else
    fail "$f (PROXY_CA): RegistryTLSConfig present"
  fi
done

summary validate-talos
