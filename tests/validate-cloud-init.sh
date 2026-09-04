#!/usr/bin/env bash
# Schema-check the upstream router's cloud-init seed data.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"
need yq
d=cloud-init/upstream-router

check "seed files parse as YAML" yq . "$d/user-data" "$d/network-config" "$d/meta-data"
check "user-data starts with the #cloud-config header" test "$(head -1 "$d/user-data")" = "#cloud-config"
check "network-config uses routes, not the deprecated gateway4" \
  yq -e '.ethernets.mgmt.routes[0].to == "default" and (.ethernets.mgmt | has("gateway4") | not)' "$d/network-config"
# yq evaluates chained comparisons unreliably after select(); compare one joined string.
frr_conf_entry() {
  yq -e '([.write_files[] | select(.path == "/etc/frr/frr.conf") | (.defer | tostring) + " " + .owner + " " + .permissions] | join(",")) == "true frr:frr 0640"' "$1"
}
check "frr.conf is written after the frr package is installed (defer: true, owned by frr, 0640)" \
  frr_conf_entry "$d/user-data"

if have cloud-init; then
  check "user-data matches the cloud-config schema" \
    cloud-init schema --config-file "$d/user-data" --annotate
  check "network-config matches the network-config v2 schema" \
    cloud-init schema --config-file "$d/network-config" --schema-type network-config --annotate
else
  skip "cloud-init not installed (schema validation)"
fi

summary validate-cloud-init
