#!/usr/bin/env bash
# Offline lint: YAML, Markdown, shell scripts and GitHub workflows.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"
need yamllint rumdl shellcheck

log "yamllint"
# yamllint only picks up *.yaml/*.yml when given a directory; the cloud-init seed files
# have no extension, so they are listed explicitly. Rules: .yamllint.yaml.
yamllint . cloud-init/upstream-router/user-data cloud-init/upstream-router/network-config \
  cloud-init/upstream-router/meta-data

log "rumdl"
rumdl check .

log "shellcheck"
shellcheck -x tests/*.sh

if have actionlint; then
  log "actionlint"
  actionlint
else
  skip "actionlint not installed (GitHub workflow lint)"
fi

log "lint: OK"
