#!/usr/bin/env bash
# Capability-aware GitHub transport for handheld launchers.
#
# Registry rows are: id<TAB>formatter<TAB>capabilities<TAB>base URL.
# Callers may provide GITHUB_PROXY_REGISTRY_OVERRIDE for tests or downstream
# additions. This module owns the bundled default registry, capability
# filtering, URL formatting, bounded probing, retry, resume, and validation.

# Proxy-list maintenance source (consult only when refreshing the bundled list):
# https://github.com/NapNeko/NapCat-Mac-Installer/blob/c30e49595d7ce1887edc9e8eb5d020b6846ef137/NapCatInstaller/Utils.swift#L174

# Bundled default registry. Maintain proxy data here, not in individual apps.
# Custom rows read as: formatter|label|base URL. Full rows contain one
# prefix-style base URL per line.
GITHUB_PROXY_CUSTOM_ROUTES="7632298ac516bdb10737bfa1ee78d898c330af15e42eedb35f14059b3e259caf692976dc440f46a379d00aa26d36c584c80fbded0329f6adca0392cb9b76fb5bfa6de2921a1152db3c38d2a86c515e834a0a4ae229c064b11009c6dd8e58b0b4013ea84ccd00c185cc3cfb5180219393571951dd293185bf48d406d50d104be338d9608d1753d48cd8"
GITHUB_PROXY_FULL_ROUTES="7435399fda45e4ec1c2da0b5b43f9fc6d57fae55f02894af47195b82776ed6b1612f6d964d0346a274d264a03621d4de8b1daaab7529f6adca0392cb9b69f410ea27f698191d48855b3589bb742802d909015ebd6ace63bd1d57da95c67dbbaf073df51f915bc784c63cff5aa7379490431c0d86273efba34cd34c89184d05f172d76d960e189784d546a7a51831c30fdd0ac7f6c462e0460541cddc58094f9f362d8c9955d73a964a0a5eeb289bdb9a0505d58adb41b9bc205c9040d919b690d46ee0794850c1904b504b933229b09d5eca40e8520e56ec1db2dfde0f1d8f91d410b0413554dc4e8404dd82ae76987a0e00d0c4081e5fcb0cc2a3d35bd90685591b2cc81ef88c864e468a91d014974c2a499856cd6edc842c529b38555891865f1d46fb4bdda3de4cc2029e5d02d0cc12f4889a4a428695e46982502655c61fce10c3b838088b7401619a975b017ca7468aa2ce58db558c602bbac60df2859e5219d47583779f572b569412890ba4ae39468534050a9b8c76ff7ff0028fadcc50b54ca63e3aa19651b78789084bfa6ee976965e3e0fc156375aa0b0205e8f24414c9df339ea6fff18d3bc8147d4b5dc2e32a2c009a6c3ca2371e57ff8399b4c3a43dc6b3731aeee3c5d88180213b2ef68bf2ca616ddbf853bf5bda92a2fa99a15ff85132869ed73ee31d8183040ae2f2b21aca462419d785cf3b6e76ff225a256d2bce32cf1bfa62770a3ca1afeac332f7f9777ed7b8b40913af16a3e2caeb73843de092af4bee56cb36fee0dbb41e724ffa7f87575a5d46090a87e277aaf78f309977bdb61a133656fbfbd3056b90c70ffa3e668eb62ec73f844b137e4a5cc3e22b23039d6f33a3361ab7ef566fa6ed133b57a234ebca40cb2bb5875b8b1e725f97fd26ea742f842ffb8be2221c06b6987b0273e75e77c1a15f368d713a2653638a39653e9a30e68f1a5fa21fe81d803ed51f33ce0fae141499638308bbc74726ce241025af271da7ce0732338e6c004beb00978a0f1e01b8393c934b40bb46efcaa38025e863c2dc2ef2e3f6d974a1647a16bd071c8710ec498d74ee1f30929e6ae951bc8eddd65e94dfc7eb4d75e0d089138778cbe6adc40db481350"

github_proxy_read() {
  local hex="$1" key=(91 37 204 113 18 167 62 209 84 9 231)
  local i=0 pair value oct ch out=""
  while [ -n "$hex" ]; do
    pair="${hex:0:2}"; hex="${hex:2}"
    value=$((16#$pair ^ key[i % ${#key[@]}] ^ ((i * 29 + 71) & 255)))
    printf -v oct '%03o' "$value"; printf -v ch "\\$oct"; out+="$ch"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

github_proxy_has_capability() {
  case " ${1//,/ } " in *" $2 "*) return 0 ;; esac
  return 1
}

github_proxy_registry() {
  local rows format name base index=0 caps formatter
  if [ -n "${GITHUB_PROXY_REGISTRY_OVERRIDE:-}" ]; then
    printf '%s\n' "$GITHUB_PROXY_REGISTRY_OVERRIDE"
    return
  fi

  if [ "${GITHUB_PROXY_CUSTOM_PROXIES+x}" = "x" ]; then
    rows="$GITHUB_PROXY_CUSTOM_PROXIES"
  elif [ "${PAM_RUNTIME_CUSTOM_PROXIES+x}" = "x" ]; then
    rows="$PAM_RUNTIME_CUSTOM_PROXIES"
  else
    rows=$(github_proxy_read "$GITHUB_PROXY_CUSTOM_ROUTES") || return 1
  fi
  while IFS='|' read -r format name base; do
    [ -n "$format" ] && [ -n "$base" ] || continue
    index=$((index + 1))
    case "$format" in
      jsdelivr) formatter="jsdelivr"; caps="raw" ;;
      custom) formatter="mirror"; caps="release,raw,archive" ;;
      full|github) formatter="full"; caps="release,raw,archive,clone,gist" ;;
      *) continue ;;
    esac
    printf 'c%s\t%s\t%s\t%s\n' "$index" "$formatter" "$caps" "${base%/}"
  done <<< "$rows"

  index=0
  if [ "${GITHUB_PROXY_FULL_PROXIES+x}" = "x" ]; then
    rows="$GITHUB_PROXY_FULL_PROXIES"
  elif [ "${PAM_RUNTIME_PROXIES+x}" = "x" ]; then
    rows="$PAM_RUNTIME_PROXIES"
  else
    rows=$(github_proxy_read "$GITHUB_PROXY_FULL_ROUTES") || return 1
  fi
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    index=$((index + 1))
    printf 'g%s\tfull\trelease,raw,archive,clone,gist\t%s\n' "$index" "${base%/}"
  done <<< "$rows"

  # Downstream additions use the same TSV schema and do not require editing
  # the transport logic or replacing the built-in registry.
  [ -z "${GITHUB_PROXY_REGISTRY_EXTRA:-}" ] || printf '%s\n' "$GITHUB_PROXY_REGISTRY_EXTRA"

  # API and Gist use different hosts, so only origin is enabled by default.
  # Git LFS and Packages are separate authenticated protocols and are not
  # represented as ordinary file-download capabilities.
  printf 'origin\tdirect\trelease,raw,archive,clone,api,gist\t\n'
}

github_proxy_validate_source() {
  local capability="$1" source="$2" clean owner repo
  case "$source" in *$'\t'*|*$'\r'*|*$'\n'*|*' '*) return 1 ;; esac
  if [ "$capability" = clone ]; then
    case "$source" in https://github.com/*/*) ;; *) return 1 ;; esac
    clean=${source#https://github.com/}; owner=${clean%%/*}; repo=${clean#*/}; repo=${repo%.git}
    [ -n "$owner" ] && [ -n "$repo" ] && [ "$repo" != "$clean" ] || return 1
    case "$owner:$repo" in *'/'*|*'?'*|*'#'*|:*|*:|*..*) return 1 ;; esac
    return 0
  fi
  case "$capability:$source" in
    release:https://github.com/*/*/releases/download/*|\
    release:https://github.com/*/*/releases/latest/download/*|\
    raw:https://raw.githubusercontent.com/*/*/*/*|\
    raw:https://github.com/*/*/raw/*|\
    archive:https://github.com/*/*/archive/*|\
    archive:https://codeload.github.com/*/*/*|\
    api:https://api.github.com/*|\
    gist:https://gist.githubusercontent.com/*|\
    gist:https://gist.github.com/*) return 0 ;;
  esac
  return 1
}

github_proxy_raw_github_path() {
  local source="$1" clean owner repo rest
  case "$source" in
    https://github.com/*)
      printf '%s\n' "${source#https://github.com/}"
      ;;
    https://raw.githubusercontent.com/*)
      clean=${source#https://raw.githubusercontent.com/}
      owner=${clean%%/*}; rest=${clean#*/}; repo=${rest%%/*}; rest=${rest#*/}
      [ -n "$owner" ] && [ -n "$repo" ] && [ "$rest" != "$clean" ] || return 1
      printf '%s/%s/raw/%s\n' "$owner" "$repo" "$rest"
      ;;
    *) return 1 ;;
  esac
}

github_proxy_raw_jsdelivr_path() {
  local source="$1" clean owner repo rest
  case "$source" in
    https://raw.githubusercontent.com/*)
      clean=${source#https://raw.githubusercontent.com/}
      owner=${clean%%/*}; rest=${clean#*/}; repo=${rest%%/*}; rest=${rest#*/}
      ;;
    https://github.com/*/raw/*)
      clean=${source#https://github.com/}; owner=${clean%%/*}; rest=${clean#*/}
      repo=${rest%%/*}; rest=${rest#*/raw/}
      ;;
    *) return 1 ;;
  esac
  [ -n "$owner" ] && [ -n "$repo" ] && [ -n "$rest" ] || return 1
  printf '%s/%s@%s\n' "$owner" "$repo" "$rest"
}

github_proxy_format_url() {
  local capability="$1" formatter="$2" base="$3" source="$4" path
  github_proxy_validate_source "$capability" "$source" || return 1
  case "$formatter" in
    direct) printf '%s\n' "$source" ;;
    full) [ -n "$base" ] && printf '%s/%s\n' "${base%/}" "$source" ;;
    mirror)
      [ -n "$base" ] || return 1
      if [ "$capability" = "raw" ]; then path=$(github_proxy_raw_github_path "$source") || return 1
      else path=${source#https://github.com/}; [ "$path" != "$source" ] || return 1; fi
      printf '%s/%s\n' "${base%/}" "$path"
      ;;
    jsdelivr)
      [ "$capability" = "raw" ] && [ -n "$base" ] || return 1
      path=$(github_proxy_raw_jsdelivr_path "$source") || return 1
      printf '%s/%s\n' "${base%/}" "$path"
      ;;
    gitclone)
      [ "$capability" = "clone" ] && [ -n "$base" ] || return 1
      path=${source#https://}; [ "$path" != "$source" ] || return 1
      printf '%s/%s\n' "${base%/}" "$path"
      ;;
    *) return 1 ;;
  esac
}

github_proxy_candidates() {
  local capability="$1" source="$2" id formatter caps base url seen=","
  github_proxy_validate_source "$capability" "$source" || return 1
  while IFS=$'\t' read -r id formatter caps base; do
    case "$id" in ""|*[!A-Za-z0-9._-]*|.|..) continue ;; esac
    case "$seen" in *",$id,"*) continue ;; esac
    case "$formatter:$base" in direct:) ;; *:https://*) ;; *) continue ;; esac
    github_proxy_has_capability "$caps" "$capability" || continue
    url=$(github_proxy_format_url "$capability" "$formatter" "$base" "$source") || continue
    case "$id:$url" in *$'\t'*|*$'\r'*|*$'\n'*) continue ;; esac
    printf '%s\t%s\n' "$id" "$url"
    seen="$seen$id,"
  done < <(github_proxy_registry)
}

github_proxy_prepare_curl() {
  [ -n "${GITHUB_PROXY_CURL:-}" ] && [ -x "$GITHUB_PROXY_CURL" ] &&
    "$GITHUB_PROXY_CURL" --version >/dev/null 2>&1
}

github_proxy_batch_size() {
  local requested="${GITHUB_PROXY_BATCH_SIZE:-5}" size=5
  case "$requested" in ''|*[!0-9]*) ;; *) size=$requested ;; esac
  [ "$size" -ge 1 ] || size=1
  [ "$size" -le 10 ] || size=10
  printf '%s\n' "$size"
}

# Stable, non-reversible identity for resumable bytes. The route list's g1/c1
# labels are deliberately excluded: reordering that list must never make an
# old partial look as if it belongs to a different formatted URL.
github_proxy_route_fingerprint() {
  local url="$1" crc bytes
  case "$url" in ""|*$'\t'*|*$'\r'*|*$'\n'*) return 1 ;; esac
  command -v cksum >/dev/null 2>&1 || return 1
  read -r crc bytes _ < <(printf '%s' "$url" | LC_ALL=C cksum) || return 1
  case "$crc:$bytes" in *[!0-9:]*) return 1 ;; esac
  printf 'v1-%s-%s\n' "$crc" "$bytes"
}

# Process-local route memory. Nothing is written to disk or exported; all
# preferences disappear when the current launcher/helper process exits.
github_proxy_preferred_read() {
  case "$1" in
    release) printf '%s\n' "${GITHUB_PROXY_LAST_RELEASE:-}" ;;
    raw) printf '%s\n' "${GITHUB_PROXY_LAST_RAW:-}" ;;
    archive) printf '%s\n' "${GITHUB_PROXY_LAST_ARCHIVE:-}" ;;
    clone) printf '%s\n' "${GITHUB_PROXY_LAST_CLONE:-}" ;;
    api) printf '%s\n' "${GITHUB_PROXY_LAST_API:-}" ;;
    gist) printf '%s\n' "${GITHUB_PROXY_LAST_GIST:-}" ;;
    *) return 1 ;;
  esac
}

github_proxy_preferred_write() {
  local capability="$1" value="$2"
  case "$value" in ""|*[!A-Za-z0-9._-]*|.|..) return 1 ;; esac
  case "$capability" in
    release) GITHUB_PROXY_LAST_RELEASE="$value" ;;
    raw) GITHUB_PROXY_LAST_RAW="$value" ;;
    archive) GITHUB_PROXY_LAST_ARCHIVE="$value" ;;
    clone) GITHUB_PROXY_LAST_CLONE="$value" ;;
    api) GITHUB_PROXY_LAST_API="$value" ;;
    gist) GITHUB_PROXY_LAST_GIST="$value" ;;
    *) return 1 ;;
  esac
}

github_proxy_preferred_clear() {
  local capability="$1" expected="$2" current
  current=$(github_proxy_preferred_read "$capability" 2>/dev/null || true)
  [ -z "$expected" ] || [ "$current" = "$expected" ] || return 0
  case "$capability" in
    release) GITHUB_PROXY_LAST_RELEASE="" ;;
    raw) GITHUB_PROXY_LAST_RAW="" ;;
    archive) GITHUB_PROXY_LAST_ARCHIVE="" ;;
    clone) GITHUB_PROXY_LAST_CLONE="" ;;
    api) GITHUB_PROXY_LAST_API="" ;;
    gist) GITHUB_PROXY_LAST_GIST="" ;;
    *) return 1 ;;
  esac
}

github_proxy_probe_one() {
  local id="$1" url="$2" root="$3" out="$root/probe.$id"
  : > "$out" || return 1
  if declare -F github_proxy_probe_hook >/dev/null 2>&1; then
    github_proxy_probe_hook "$url" "$out" || return 1
  else
    github_proxy_prepare_curl || return 1
    "$GITHUB_PROXY_CURL" -fsSL --connect-timeout "${GITHUB_PROXY_PROBE_CONNECT_TIMEOUT:-3}" \
      --max-time "${GITHUB_PROXY_PROBE_TIMEOUT:-5}" --range 0-15 "$url" 2>/dev/null |
      head -c 16 > "$out"
    [ -s "$out" ] || return 1
  fi
  : > "$root/ok.$id"
  if mkdir "$root/winner.lock" 2>/dev/null; then printf '%s\n' "$id" > "$root/winner"; fi
}

github_proxy_transfer_one() {
  local id="$1" url="$2" out="$3" validator="$4" part route fingerprint rc=0
  part="$out.part"; route="$out.part.route"
  fingerprint=$(github_proxy_route_fingerprint "$url") || return 1
  if [ -s "$route" ] && [ "$(sed -n '1p' "$route" 2>/dev/null)" = "$fingerprint" ]; then :
  else rm -f -- "$part" "$route"; fi
  printf '%s\n' "$fingerprint" > "$route" || return 1

  if declare -F github_proxy_transfer_hook >/dev/null 2>&1; then
    github_proxy_transfer_hook "$url" "$part" || rc=$?
  else
    if ! github_proxy_prepare_curl; then
      [ -s "$part" ] || rm -f -- "$part" "$route"
      return 1
    fi
    if [ -s "$part" ]; then
      "$GITHUB_PROXY_CURL" -fsSL --connect-timeout "${GITHUB_PROXY_CONNECT_TIMEOUT:-8}" \
        --retry 2 --retry-delay 1 -C - -o "$part" "$url" 2>/dev/null || rc=$?
    else
      "$GITHUB_PROXY_CURL" -fsSL --connect-timeout "${GITHUB_PROXY_CONNECT_TIMEOUT:-8}" \
        --retry 2 --retry-delay 1 -o "$part" "$url" 2>/dev/null || rc=$?
    fi
  fi
  if [ "$rc" = "33" ]; then
    rm -f -- "$part"; rc=0
    if declare -F github_proxy_transfer_hook >/dev/null 2>&1; then
      github_proxy_transfer_hook "$url" "$part" || rc=$?
    else
      "$GITHUB_PROXY_CURL" -fsSL --connect-timeout "${GITHUB_PROXY_CONNECT_TIMEOUT:-8}" \
        --retry 2 --retry-delay 1 -o "$part" "$url" 2>/dev/null || rc=$?
    fi
  fi
  if [ "$rc" != "0" ]; then
    [ -s "$part" ] || rm -f -- "$part" "$route"
    return "$rc"
  fi
  "$validator" "$part" || { rm -f -- "$part" "$route"; return 65; }
  mv -f -- "$part" "$out" || return 1
  rm -f -- "$route"
}

github_proxy_order_batch() {
  local root="$1" batch_file="$2" ordered_file="$3" preferred="$4" winner current url
  : > "$ordered_file"
  winner=$(sed -n '1p' "$root/winner" 2>/dev/null || true)
  [ -z "$preferred" ] || [ ! -e "$root/ok.$preferred" ] || winner="$preferred"
  [ -z "$winner" ] || awk -F '\t' -v id="$winner" '$1 == id' "$batch_file" >> "$ordered_file"
  while IFS=$'\t' read -r current url; do
    [ -e "$root/ok.$current" ] || continue
    [ "$current" = "$winner" ] && continue
    printf '%s\t%s\n' "$current" "$url" >> "$ordered_file"
  done < "$batch_file"
}

github_proxy_fetch() {
  local capability="$1" source="$2" out="$3" validator="$4"
  local temp_root root candidates preferred preferred_line batch_size index=0 batch_start=1 id url current rc content_failed=0
  local batch_file ordered_file
  github_proxy_validate_source "$capability" "$source" || return 64
  declare -F "$validator" >/dev/null 2>&1 || return 64
  batch_size=$(github_proxy_batch_size)
  temp_root="${GITHUB_PROXY_TEMP_DIR:-${TMPDIR:-/tmp}}"
  root="$temp_root/github-proxy-probe.$$"; mkdir -p "$root" || return 1
  candidates=$(github_proxy_candidates "$capability" "$source") || { rm -rf -- "$root"; return 1; }
  # Only the process-local winner is preferred. The .part.route URL
  # fingerprint protects resumable bytes from being mixed across endpoints;
  # it never changes candidate order.
  preferred=$(github_proxy_preferred_read "$capability" 2>/dev/null || true)
  preferred_line=""
  [ -z "$preferred" ] || preferred_line=$(awk -F '\t' -v id="$preferred" '$1 == id {print; exit}' <<< "$candidates")
  if [ -n "$preferred_line" ]; then
    candidates="$preferred_line"$'\n'"$(awk -F '\t' -v id="$preferred" '$1 != id' <<< "$candidates")"
  else
    github_proxy_preferred_clear "$capability" "$preferred" || true
    preferred=""
  fi
  batch_file="$root/batch.tsv"; ordered_file="$root/ordered.tsv"; : > "$batch_file"

  while IFS=$'\t' read -r id url; do
    [ -n "$id" ] && [ -n "$url" ] || continue
    index=$((index + 1)); printf '%s\t%s\n' "$id" "$url" >> "$batch_file"
    github_proxy_probe_one "$id" "$url" "$root" &
    if [ $((index - batch_start + 1)) -lt "$batch_size" ]; then continue; fi
    wait || true
    if [ -n "$preferred" ] && [ ! -e "$root/ok.$preferred" ]; then
      github_proxy_preferred_clear "$capability" "$preferred" || true; preferred=""
    fi
    github_proxy_order_batch "$root" "$batch_file" "$ordered_file" "$preferred"
    while IFS=$'\t' read -r current url; do
      if github_proxy_transfer_one "$current" "$url" "$out" "$validator"; then
        github_proxy_preferred_write "$capability" "$current" || true
        rm -rf -- "$root"; return 0
      else rc=$?; fi
      if [ "$rc" = "70" ]; then rm -rf -- "$root"; return 70; fi
      if [ "$current" = "$preferred" ]; then
        github_proxy_preferred_clear "$capability" "$preferred" || true; preferred=""
      fi
      [ "$rc" != "65" ] || content_failed=1
    done < "$ordered_file"
    rm -rf -- "$root/winner.lock"; rm -f -- "$root/winner" "$root"/ok.* "$root"/probe.*
    : > "$batch_file"; batch_start=$((index + 1))
  done <<< "$candidates"

  if [ -s "$batch_file" ]; then
    wait || true
    if [ -n "$preferred" ] && [ ! -e "$root/ok.$preferred" ]; then
      github_proxy_preferred_clear "$capability" "$preferred" || true; preferred=""
    fi
    github_proxy_order_batch "$root" "$batch_file" "$ordered_file" "$preferred"
    while IFS=$'\t' read -r current url; do
      if github_proxy_transfer_one "$current" "$url" "$out" "$validator"; then
        github_proxy_preferred_write "$capability" "$current" || true
        rm -rf -- "$root"; return 0
      else rc=$?; fi
      if [ "$rc" = "70" ]; then rm -rf -- "$root"; return 70; fi
      if [ "$current" = "$preferred" ]; then
        github_proxy_preferred_clear "$capability" "$preferred" || true; preferred=""
      fi
      [ "$rc" != "65" ] || content_failed=1
    done < "$ordered_file"
  fi
  rm -rf -- "$root"
  [ "$content_failed" = "0" ] || return 65
  return 1
}

github_proxy_clone_probe_one() {
  local id="$1" url="$2" root="$3" probe_url out="$root/probe.$id"
  probe_url="${url%/}/info/refs?service=git-upload-pack"
  : > "$out" || return 1
  if declare -F github_proxy_clone_probe_hook >/dev/null 2>&1; then
    github_proxy_clone_probe_hook "$url" "$out" || return 1
  else
    github_proxy_prepare_curl || return 1
    "$GITHUB_PROXY_CURL" -fsSL --connect-timeout "${GITHUB_PROXY_PROBE_CONNECT_TIMEOUT:-3}" \
      --max-time "${GITHUB_PROXY_PROBE_TIMEOUT:-5}" --range 0-63 "$probe_url" 2>/dev/null |
      head -c 64 > "$out"
    [ -s "$out" ] || return 1
  fi
  : > "$root/ok.$id"
  if mkdir "$root/winner.lock" 2>/dev/null; then printf '%s\n' "$id" > "$root/winner"; fi
}

github_proxy_clone_one() {
  local url="$1" destination="$2" staged="$destination.clone.$$" git_cmd rc=0
  rm -rf -- "$staged"
  if declare -F github_proxy_clone_hook >/dev/null 2>&1; then
    github_proxy_clone_hook "$url" "$staged" || rc=$?
  else
    git_cmd="${GITHUB_PROXY_GIT:-$(command -v git 2>/dev/null || true)}"
    [ -n "$git_cmd" ] && [ -x "$git_cmd" ] || return 1
    "$git_cmd" clone -- "$url" "$staged" >/dev/null 2>&1 || rc=$?
  fi
  [ "$rc" = 0 ] || { rm -rf -- "$staged"; return "$rc"; }
  if declare -F github_proxy_clone_validate_hook >/dev/null 2>&1; then
    github_proxy_clone_validate_hook "$staged" || { rm -rf -- "$staged"; return 65; }
  else
    [ -d "$staged/.git" ] || { rm -rf -- "$staged"; return 65; }
  fi
  mv -- "$staged" "$destination" || { rm -rf -- "$staged"; return 1; }
}

# Clone is a distinct Git smart-HTTP operation, not a file download. It uses
# the same capability registry and bounded first-response race, then gives
# each responsive route one clean clone attempt.
github_proxy_clone() {
  local source="$1" destination="$2" temp_root root candidates batch_size index=0 batch_start=1
  local id url current rc batch_file ordered_file preferred preferred_line
  github_proxy_validate_source clone "$source" || return 64
  [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 64
  batch_size=$(github_proxy_batch_size)
  temp_root="${GITHUB_PROXY_TEMP_DIR:-${TMPDIR:-/tmp}}"
  root="$temp_root/github-proxy-clone.$$"; mkdir -p "$root" || return 1
  candidates=$(github_proxy_candidates clone "$source") || { rm -rf -- "$root"; return 1; }
  preferred=$(github_proxy_preferred_read clone 2>/dev/null || true)
  preferred_line=""
  [ -z "$preferred" ] || preferred_line=$(awk -F '\t' -v id="$preferred" '$1 == id {print; exit}' <<< "$candidates")
  if [ -n "$preferred_line" ]; then
    candidates="$preferred_line"$'\n'"$(awk -F '\t' -v id="$preferred" '$1 != id' <<< "$candidates")"
  else
    github_proxy_preferred_clear clone "$preferred" || true
    preferred=""
  fi
  batch_file="$root/batch.tsv"; ordered_file="$root/ordered.tsv"; : > "$batch_file"

  while IFS=$'\t' read -r id url; do
    [ -n "$id" ] && [ -n "$url" ] || continue
    index=$((index + 1)); printf '%s\t%s\n' "$id" "$url" >> "$batch_file"
    github_proxy_clone_probe_one "$id" "$url" "$root" &
    if [ $((index - batch_start + 1)) -lt "$batch_size" ]; then continue; fi
    wait || true
    if [ -n "$preferred" ] && [ ! -e "$root/ok.$preferred" ]; then
      github_proxy_preferred_clear clone "$preferred" || true; preferred=""
    fi
    github_proxy_order_batch "$root" "$batch_file" "$ordered_file" "$preferred"
    while IFS=$'\t' read -r current url; do
      if github_proxy_clone_one "$url" "$destination"; then
        github_proxy_preferred_write clone "$current" || true
        rm -rf -- "$root"; return 0
      else rc=$?; fi
      [ "$rc" != 70 ] || { rm -rf -- "$root"; return 70; }
      if [ "$current" = "$preferred" ]; then
        github_proxy_preferred_clear clone "$preferred" || true; preferred=""
      fi
    done < "$ordered_file"
    rm -rf -- "$root/winner.lock"; rm -f -- "$root/winner" "$root"/ok.* "$root"/probe.*
    : > "$batch_file"; batch_start=$((index + 1))
  done <<< "$candidates"

  if [ -s "$batch_file" ]; then
    wait || true
    if [ -n "$preferred" ] && [ ! -e "$root/ok.$preferred" ]; then
      github_proxy_preferred_clear clone "$preferred" || true; preferred=""
    fi
    github_proxy_order_batch "$root" "$batch_file" "$ordered_file" "$preferred"
    while IFS=$'\t' read -r current url; do
      if github_proxy_clone_one "$url" "$destination"; then
        github_proxy_preferred_write clone "$current" || true
        rm -rf -- "$root"; return 0
      else rc=$?; fi
      [ "$rc" != 70 ] || { rm -rf -- "$root"; return 70; }
      if [ "$current" = "$preferred" ]; then
        github_proxy_preferred_clear clone "$preferred" || true; preferred=""
      fi
    done < "$ordered_file"
  fi
  rm -rf -- "$root"
  return 1
}
