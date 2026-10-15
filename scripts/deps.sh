#!/usr/bin/env bash
# Mechanical dependency maintenance for the pins listed in scripts/deps.yaml.
#
#   deps.sh outdated [--json|--markdown] [NAME...]   newer upstream releases per pin
#   deps.sh bump [--level patch|minor|major] [--dry-run] [NAME...]
#                                                    move pins to the newest allowed release,
#                                                    then sync the derived copies
#   deps.sh sync [--check]                           copy pinned values into derived files;
#                                                    --check only reports drift (exit 1)
#
# Whether Talos, Kubernetes and Cilium still fit together is a review decision, recorded as a
# 'constraint' in deps.yaml; this script only enforces it (see .claude/skills/bump-deps).
# Portable like tests/: bash 3.2 and the GNU/BSD userland on macOS and ubuntu-latest.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../tests/lib.sh
. "$(dirname "$0")/../tests/lib.sh"
cd "$REPO_ROOT"

REGISTRY=scripts/deps.yaml
# A pinned value: what follows an entry's match on the same line.
TOKEN='[A-Za-z0-9._+-]+'
# sed delimiter. Matches contain '/', '|' and '#', so use a control character.
D=$(printf '\001')

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" >&2
  exit 2
}

# --- Pins ---

# pin_read FILE MATCH: print the value after MATCH; fail unless exactly one distinct value.
pin_read() {
  local vals
  vals=$(sed -nE "s${D}^($2)($TOKEN).*\$${D}\\2${D}p" "$1" | sort -u)
  if [ -z "$vals" ]; then
    printf 'deps: no line in %s matches /%s/\n' "$1" "$2" >&2
    return 1
  fi
  case $vals in
    *$'\n'*)
      printf 'deps: lines in %s matching /%s/ disagree: %s\n' "$1" "$2" "$(printf '%s' "$vals" | tr '\n' ' ')" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$vals"
}

# pin_write FILE MATCH VALUE: replace the value after MATCH on every matching line. Rewrites the
# file in place through cat so its mode and inode are kept.
pin_write() {
  local tmp
  tmp=$(mktemp)
  sed -E "s${D}^($2)$TOKEN${D}\\1$3${D}" "$1" >"$tmp"
  cat "$tmp" >"$1"
  rm -f "$tmp"
}

# --- Registry ---

ENTRIES=()
load_entries() { # [NAME...]: fill ENTRIES with the selected entries, one compact JSON each
  local line name n known=" "
  ENTRIES=()
  while IFS= read -r line; do
    name=$(jq -r .name <<<"$line")
    known="$known$name "
    if [ $# -gt 0 ]; then
      case " $* " in *" $name "*) ;; *) continue ;; esac
    fi
    ENTRIES[${#ENTRIES[@]}]=$line
  done < <(yq -o=json -I=0 '.[]' "$REGISTRY")
  for n in "$@"; do
    case $known in
      *" $n "*) ;;
      *) printf 'deps: unknown dependency %s (known:%s)\n' "$n" "$known" >&2; exit 2 ;;
    esac
  done
}

# field JSON PATH: print a field of an entry, empty when absent.
field() { jq -r "$2 // empty" <<<"$1"; }

# --- Versions ---

# vcmp A B: print -1, 0 or 1. Numeric, field by field on '.'; missing fields count as 0.
vcmp() {
  local a=$1 b=$2 x y
  while [ -n "$a" ] || [ -n "$b" ]; do
    x=${a%%.*} y=${b%%.*}
    x=${x:-0} y=${y:-0}
    if [ "$x" -lt "$y" ]; then echo -1; return; fi
    if [ "$x" -gt "$y" ]; then echo 1; return; fi
    case $a in *.*) a=${a#*.} ;; *) a= ;; esac
    case $b in *.*) b=${b#*.} ;; *) b= ;; esac
  done
  echo 0
}

# vkey VALUE: comparable form - no 'v' prefix, Debian build '20261015-2632' as '20261015.2632'.
# Prints nothing for pre-releases and anything else that is not plain dotted numbers.
vkey() {
  local v=${1#v}
  case $v in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9]*) v=${v/-/.} ;; esac
  if printf '%s\n' "$v" | grep -Eq '^[0-9]+(\.[0-9]+)*$'; then printf '%s\n' "$v"; fi
}

# shellcheck disable=SC2086 # splitting on IFS=. is the point
nfields() { local IFS=.; set -- $1; echo $#; }

# level CURRENT_KEY NEW_KEY: major, minor or patch - the first field that differs. A two-field
# version (agnhost 2.61) has no patch level; a build number change counts as a patch.
level() {
  local a=$1 b=$2 i=0
  while [ "${a%%.*}" = "${b%%.*}" ]; do
    a=${a#*.} b=${b#*.} i=$((i + 1))
  done
  case $i in 0) echo major ;; 1) echo minor ;; *) echo patch ;; esac
}

# satisfies KEY CONSTRAINT: true when KEY is inside '<X.Y' / '<=X.Y.Z' (or no constraint).
satisfies() {
  local c=$2
  case $c in
    '') return 0 ;;
    '<='*) [ "$(vcmp "$1" "${c#<=}")" != 1 ] ;;
    '<'*) [ "$(vcmp "$1" "${c#<}")" = -1 ] ;;
    *) printf 'deps: unsupported constraint %s\n' "$c" >&2; return 1 ;;
  esac
}

# restyle RAW CURRENT: RAW with the 'v' prefix convention of CURRENT.
restyle() {
  local n=${1#v}
  case $2 in v*) printf 'v%s\n' "$n" ;; *) printf '%s\n' "$n" ;; esac
}

# --- Upstream lookups: print release identifiers, one per line ---

lookup() { # ENTRY_JSON
  local e=$1 type
  type=$(field "$e" .source.type)
  case $type in
    git-tags)
      git ls-remote --tags --refs "https://github.com/$(field "$e" .source.repo).git" \
        | sed 's#.*refs/tags/##'
      ;;
    helm)
      curl -fsSL --retry 3 "$(field "$e" .source.url)/index.yaml" \
        | yq ".entries.\"$(field "$e" .source.chart)\"[].version"
      ;;
    oci)
      skopeo list-tags "docker://$(field "$e" .source.image)" | jq -r '.Tags[]'
      ;;
    pypi)
      curl -fsSL --retry 3 "https://pypi.org/pypi/$(field "$e" .source.package)/json" \
        | jq -r '.releases | keys[]'
      ;;
    frr-deb)
      # Debian packages FRR as e.g. 10.3-3+deb13u1 (upstream 10.3 + Debian patches); the newest
      # upstream 10.3.x image is the closest match for dry-running the router config.
      local suite minors m
      suite=$(mkvar "$(field "$e" .source.suite_var)")
      minors=$(curl -fsSL --retry 3 \
        "https://api.ftp-master.debian.org/madison?package=frr&s=$suite,$suite-updates,$suite-security&f=json" \
        | jq -r '.[0].frr[]? | keys[]' | sed -E 's/^[0-9]+://; s/-.*$//' \
        | awk -F. '{ print $1 "." $2 }' | sort -u)
      [ -n "$minors" ] || { echo "deps: no frr package in Debian $suite" >&2; return 1; }
      for m in $minors; do
        skopeo list-tags "docker://$(field "$e" .source.image)" | jq -r '.Tags[]' \
          | grep -E "^${m//./\\.}\.[0-9]+$" || true
      done
      ;;
    debian-cloud)
      curl -fsSL --retry 3 "https://cloud.debian.org/images/cloud/$(mkvar "$(field "$e" .source.release_var)")/" \
        | grep -oE 'href="[0-9]{8}-[0-9]+/"' | sed -E 's/^href="//; s#/"$##' | sort -u
      ;;
    debian-stable)
      curl -fsSL --retry 3 https://deb.debian.org/debian/dists/stable/Release | sed -n 's/^Codename: //p'
      ;;
    *)
      printf 'deps: unknown source type %s\n' "$type" >&2
      return 1
      ;;
  esac
}

# evaluate ENTRY_JSON TAGS_FILE ERR_FILE: print the entry's status as one JSON line:
# current, the newest release per update level (patch/minor/major, each within the constraint),
# the newest release overall (latest) and whether the constraint holds it back (blocked).
evaluate() {
  local e=$1 tags=$2 errf=$3 cur ckey constraint t k lvl
  local patch="" minor="" major="" latest="" pk="" mk="" jk="" lk="" n
  cur=$(pin_read "$(field "$e" .pin.file)" "$(field "$e" .pin.match)" 2>>"$errf") || cur=""
  constraint=$(field "$e" .constraint)
  if [ "$(field "$e" .manual)" != true ] && [ -n "$cur" ] && [ -z "$(vkey "$cur")" ]; then
    echo "deps: pinned value $cur is not a plain version" >>"$errf"
  fi
  if [ -s "$errf" ] || [ ! -s "$tags" ]; then
    jq -nc --argjson e "$e" --arg cur "$cur" --arg err "$(head -n 3 "$errf" 2>/dev/null)" \
      '$e + {current: $cur, error: (if $err == "" then "no releases found" else $err end)}'
    return
  fi
  if [ "$(field "$e" .manual)" = true ]; then
    latest=$(head -n 1 "$tags")
    [ "$latest" != "$cur" ] || latest=""
    jq -nc --argjson e "$e" --arg cur "$cur" --arg latest "$latest" \
      '$e + {current: $cur, latest: $latest, major: $latest}'
    return
  fi
  ckey=$(vkey "$cur")
  n=$(nfields "$ckey")
  while IFS= read -r t; do
    k=$(vkey "$t")
    if [ -z "$k" ] || [ "$(nfields "$k")" != "$n" ] || [ "$(vcmp "$k" "$ckey")" != 1 ]; then
      continue
    fi
    if [ -z "$lk" ] || [ "$(vcmp "$k" "$lk")" = 1 ]; then lk=$k latest=$t; fi
    satisfies "$k" "$constraint" || continue
    lvl=$(level "$ckey" "$k")
    if [ "$(field "$e" .source.type)" = debian-cloud ]; then lvl='patch'; fi
    if [ -z "$jk" ] || [ "$(vcmp "$k" "$jk")" = 1 ]; then jk=$k major=$t; fi
    if [ "$lvl" != major ] && { [ -z "$mk" ] || [ "$(vcmp "$k" "$mk")" = 1 ]; }; then mk=$k minor=$t; fi
    if [ "$lvl" = patch ] && { [ -z "$pk" ] || [ "$(vcmp "$k" "$pk")" = 1 ]; }; then pk=$k patch=$t; fi
  done < <(grep -E '^v?[0-9]+(\.[0-9]+)*$|^[0-9]{8}-[0-9]+$' "$tags" || true)
  [ -z "$patch" ] || patch=$(restyle "$patch" "$cur")
  [ -z "$minor" ] || minor=$(restyle "$minor" "$cur")
  [ -z "$major" ] || major=$(restyle "$major" "$cur")
  [ -z "$latest" ] || latest=$(restyle "$latest" "$cur")
  jq -nc --argjson e "$e" --arg cur "$cur" --arg patch "$patch" --arg minor "$minor" \
    --arg major "$major" --arg latest "$latest" \
    '$e + {current: $cur, patch: $patch, minor: $minor, major: $major, latest: $latest,
           blocked: ($latest != "" and $latest != $major)}'
}

# status: evaluate every entry in ENTRIES, lookups in parallel; one JSON line per entry.
status() {
  local tmp i
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064 # expand now: tmp is local
  trap "rm -rf '$tmp'" EXIT
  for i in "${!ENTRIES[@]}"; do
    (lookup "${ENTRIES[$i]}" >"$tmp/$i.tags" 2>"$tmp/$i.err" || echo "lookup failed" >>"$tmp/$i.err") &
  done
  wait
  for i in "${!ENTRIES[@]}"; do
    # Lookup stderr is diagnostic only when the lookup produced nothing (git/skopeo chatter).
    [ ! -s "$tmp/$i.tags" ] || : >"$tmp/$i.err"
    evaluate "${ENTRIES[$i]}" "$tmp/$i.tags" "$tmp/$i.err"
  done
}

# --- Commands ---

cmd_outdated() {
  local format=text
  while [ $# -gt 0 ]; do
    case $1 in
      --json) format=json ;;
      --markdown) format=markdown ;;
      -*) usage ;;
      *) break ;;
    esac
    shift
  done
  need yq jq curl git skopeo
  load_entries "$@"
  local rows
  rows=$(status | jq -s .)
  case $format in
    json) printf '%s\n' "$rows" ;;
    markdown)
      jq -r '
        def c: if . == null or . == "" then "-" else . end;
        "| Dependency | Group | Current | Patch | Minor | Major | Note |",
        "|---|---|---|---|---|---|---|",
        (.[] | "| \(.name) | \(.group) | \(.current) | \(.patch|c) | \(.minor|c) | \(.major|c) | " +
          ([ (if .error then "lookup failed: \(.error)" else empty end),
             (if .blocked then "\(.latest) held back by \(.constraint)" else empty end),
             (if .manual and (.latest // "") != "" then "manual bump" else empty end),
             (if (.patch // "") != "" or (.minor // "") != "" or (.major // "") != "" then .note else empty end)
           ] | map(select(. != null)) | join("; ")) + " |")' <<<"$rows"
      ;;
    text)
      {
        printf 'NAME\tCURRENT\tPATCH\tMINOR\tMAJOR\tHELD BACK\n'
        jq -r '
          def c: if . == null or . == "" then "-" else . end;
          .[] | [.name, .current,
                 (if .error then "lookup failed: \(.error)" else (.patch|c) end),
                 (.minor|c), (.major|c),
                 (if .blocked then "\(.latest) (\(.constraint))" else "-" end)] | @tsv' <<<"$rows"
      } | column -t -s "$(printf '\t')"
      ;;
  esac
}

cmd_bump() {
  local cli_level="" dry=false
  while [ $# -gt 0 ]; do
    case $1 in
      --level) cli_level=${2:-}; shift ;;
      --level=*) cli_level=${1#--level=} ;;
      --dry-run) dry=true ;;
      -*) usage ;;
      *) break ;;
    esac
    shift
  done
  case $cli_level in '' | patch | minor | major) ;; *) usage ;; esac
  need yq jq curl git skopeo
  load_entries "$@"
  local s name cur lvl target file match changed=0 failed=0 url sums sha
  while IFS= read -r s; do
    name=$(field "$s" .name)
    cur=$(field "$s" .current)
    if [ -n "$(field "$s" .error)" ]; then
      warn "$name: lookup failed, not bumped: $(field "$s" .error)"
      failed=$((failed + 1))
      continue
    fi
    if [ "$(field "$s" .manual)" = true ]; then
      [ -z "$(field "$s" .latest)" ] || warn "$name: $cur -> $(field "$s" .latest) is a manual bump ($(field "$s" .note))"
      continue
    fi
    lvl=${cli_level:-$(field "$s" .default_level)}
    lvl=${lvl:-patch}
    target=$(field "$s" ".$lvl")
    [ -n "$(field "$s" .latest)" ] && [ "$(field "$s" .latest)" != "$target" ] \
      && log "$name: $(field "$s" .latest) available, not applied (level $lvl$([ -z "$(field "$s" .constraint)" ] || printf ', constraint %s' "$(field "$s" .constraint)"))"
    [ -n "$target" ] || continue
    changed=$((changed + 1))
    if $dry; then
      printf '%s: %s -> %s\n' "$name" "$cur" "$target"
      continue
    fi
    file=$(field "$s" .pin.file)
    match=$(field "$s" .pin.match)
    pin_write "$file" "$match" "$target"
    printf '%s: %s -> %s (%s)\n' "$name" "$cur" "$target" "$file"
    if [ -n "$(field "$s" .checksum.match)" ]; then
      # The digest comes from the SHA512SUMS next to the artifact the Makefile now points at.
      url=$(mkvar DEBIAN_IMAGE_URL)
      sums=$(curl -fsSL --retry 3 "${url%/*}/SHA512SUMS")
      sha=$(printf '%s\n' "$sums" | awk -v f="${url##*/}" '$2 == f { print $1 }')
      [ -n "$sha" ] || { fail "$name: ${url##*/} not listed in ${url%/*}/SHA512SUMS"; continue; }
      pin_write "$file" "$(field "$s" .checksum.match)" "$sha"
    fi
  done < <(status)
  if ! $dry && [ "$changed" -gt 0 ]; then cmd_sync; fi
  [ "$changed" -gt 0 ] || log "nothing to bump"
  [ "$failed" -eq 0 ] && [ "$FAILURES" -eq 0 ]
}

cmd_sync() {
  local check=false e value d file match fmt want have
  case ${1:-} in --check) check=true ;; '') ;; *) usage ;; esac
  need yq jq
  load_entries
  for e in "${ENTRIES[@]}"; do
    [ "$(jq '.derived | length' <<<"$e")" -gt 0 ] || continue
    value=$(pin_read "$(field "$e" .pin.file)" "$(field "$e" .pin.match)")
    while IFS= read -r d; do
      file=$(field "$d" .file) match=$(field "$d" .match) fmt=$(field "$d" .format)
      want=$value
      [ "$fmt" != minor ] || want=$(printf '%s\n' "$value" | cut -d. -f1-2)
      have=$(pin_read "$file" "$match") || { fail "$(field "$e" .name): $file"; continue; }
      [ "$have" != "$want" ] || continue
      if $check; then
        fail "$file has $(field "$e" .name) $have, the pin is $want (run 'make sync-versions')"
      else
        pin_write "$file" "$match" "$want"
        printf 'sync: %s: %s -> %s\n' "$file" "$have" "$want"
      fi
    done < <(jq -c '.derived[]' <<<"$e")
  done
  if $check; then summary "sync --check"; fi
  [ "$FAILURES" -eq 0 ]
}

case ${1:-} in
  outdated) shift; cmd_outdated "$@" ;;
  bump) shift; cmd_bump "$@" ;;
  sync) shift; cmd_sync "$@" ;;
  *) usage ;;
esac
