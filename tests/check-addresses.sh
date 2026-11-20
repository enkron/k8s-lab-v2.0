#!/usr/bin/env bash
# Addressing consistency: the Makefile node inventory is the source of truth. The Talos per-node
# patches are generated from it; the files below still carry their own copies, so check each
# copy against it, and check that the BGP speakers agree on the AS numbers.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"
need yq

net=cloud-init/upstream-router/network-config
user_data=cloud-init/upstream-router/user-data
rr_manifest=manifests/frr-route-reflector.yaml
bgp=manifests/cilium-bgp.yaml
cp_patch=talos/patches/controlplane.yaml

r_mac_mgmt=$(mkvar MAC_MGMT_upstream-router)
r_mac_int=$(mkvar MAC_INTERNAL_upstream-router)
r_mgmt=$(mkvar IP_MGMT_upstream-router)
r_ip6=$(mkvar IP_INTERNAL_upstream-router)
r_ip4=$(mkvar IP4_INTERNAL_upstream-router)
cp_mgmt=$(mkvar IP_MGMT_control-plane-1)
cp_ip6=$(mkvar IP_INTERNAL_control-plane-1)
cp_ip4=$(mkvar IP4_INTERNAL_control-plane-1)
worker_ip6s=$(mkvar WORKER_INTERNAL_IPS)
mgmt_gw=$(mkvar MGMT_GW)
mgmt_dns=$(mkvar MGMT_DNS)
mgmt_len=$(mkvar MGMT_NET)
mgmt_len=${mgmt_len#*/}

# eq DESCRIPTION ACTUAL EXPECTED
eq() {
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1: found '$2', expected '$3'"
  fi
}

rr_conf=$(yq 'select(.kind == "ConfigMap") | .data["frr.conf"]' "$rr_manifest")
router_conf=$(yq '.write_files[] | select(.path == "/etc/frr/frr.conf") | .content' "$user_data")
# frr_get CONF REGEX: the first capture of REGEX (a sed ERE with one group) in CONF.
frr_get() { printf '%s\n' "$1" | sed -En "s/$2/\\1/p" | head -1; }
# frr_neighbors CONF: "ADDRESS ASN" per neighbor, sorted.
frr_neighbors() {
  printf '%s\n' "$1" | sed -En 's/^[[:space:]]*neighbor ([^ ]+) remote-as ([0-9]+).*/\1 \2/p' | sort
}

log "upstream router: cloud-init network-config"
eq "mgmt NIC MAC" "$(yq '.ethernets.mgmt.match.macaddress' "$net")" "$r_mac_mgmt"
eq "mgmt NIC address" "$(yq '.ethernets.mgmt.addresses | join(" ")' "$net")" "$r_mgmt/$mgmt_len"
eq "mgmt default route via the SLIRP gateway" "$(yq '.ethernets.mgmt.routes[0].via' "$net")" "$mgmt_gw"
eq "mgmt DNS is the SLIRP forwarder" \
  "$(yq '.ethernets.mgmt.nameservers.addresses | join(" ")' "$net")" "$mgmt_dns"
eq "internal NIC MAC" "$(yq '.ethernets.internal.match.macaddress' "$net")" "$r_mac_int"
eq "internal NIC addresses, IPv6 first" \
  "$(yq '.ethernets.internal.addresses | join(" ")' "$net")" "$r_ip6/64 $r_ip4/24"

log "BGP speakers"
rr_asn=$(frr_get "$rr_conf" '^router bgp ([0-9]+).*')
router_asn=$(frr_get "$router_conf" '^router bgp ([0-9]+).*')
eq "upstream router: router-id is its internal IPv4" \
  "$(frr_get "$router_conf" '^[[:space:]]*bgp router-id ([^ ]+).*')" "$r_ip4"
eq "upstream router: one neighbor, the RR in the cluster AS" \
  "$(frr_neighbors "$router_conf" | tr '\n' ' ' | sed 's/ $//')" "$cp_ip6 $rr_asn"
eq "RR: router-id is control-plane-1's internal IPv4" \
  "$(frr_get "$rr_conf" '^[[:space:]]*bgp router-id ([^ ]+).*')" "$cp_ip4"
eq "RR: cluster-id is control-plane-1's internal IPv4" \
  "$(frr_get "$rr_conf" '^[[:space:]]*bgp cluster-id ([^ ]+).*')" "$cp_ip4"
expected_rr=$( { echo "$r_ip6 $router_asn"; for ip in $worker_ip6s; do echo "$ip $rr_asn"; done; } | sort)
eq "RR: neighbors are the router (eBGP) and every worker (iBGP)" \
  "$(frr_neighbors "$rr_conf" | tr '\n' ' ' | sed 's/ $//')" "$(printf '%s' "$expected_rr" | tr '\n' ' ')"
eq "Cilium BGP: workers peer with the RR on control-plane-1" \
  "$(yq 'select(.kind == "CiliumBGPClusterConfig") | [.spec.bgpInstances[].peers[].peerAddress] | join(" ")' "$bgp")" \
  "$cp_ip6"
eq "Cilium BGP: local and peer ASN are the RR's AS" \
  "$(yq 'select(.kind == "CiliumBGPClusterConfig") | [.spec.bgpInstances[] | .localASN, .peers[].peerASN] | unique | join(" ")' "$bgp")" \
  "$rr_asn"
if [ "$rr_asn" != "$router_asn" ]; then
  pass "RR and upstream router are in different ASes (eBGP: $rr_asn, $router_asn)"
else
  fail "RR and upstream router share AS $rr_asn"
fi

log "Talos control-plane patch"
eq "API server SANs: mgmt IP, internal IPv6, loopback" \
  "$(yq 'select(.kind == "KubeAPIServerConfig") | .certExtraSANs | join(" ")' "$cp_patch")" \
  "$cp_mgmt $cp_ip6 127.0.0.1"

summary check-addresses
