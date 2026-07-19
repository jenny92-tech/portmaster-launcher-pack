#!/usr/bin/env bash
# Capability-aware GitHub transport for handheld launchers.
#
# Registry rows are: id<TAB>formatter<TAB>capabilities<TAB>base URL.
# Callers may provide GITHUB_PROXY_REGISTRY_OVERRIDE for tests or downstream
# additions. Built-in endpoints remain encoded by the owning application; this
# module owns capability filtering, URL formatting, bounded probing, retry,
# resume and content-aware fallback.

GITHUB_PROXY_SOURCE="https://github.com/NapNeko/NapCat-Mac-Installer/blob/c30e49595d7ce1887edc9e8eb5d020b6846ef137/NapCatInstaller/Utils.swift#L174"

github_proxy_decode() {
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

  if [ "${PAM_RUNTIME_CUSTOM_PROXIES+x}" = "x" ]; then
    rows="$PAM_RUNTIME_CUSTOM_PROXIES"
  else
    rows=$(github_proxy_decode "${RUNTIME_CUSTOM_ROUTES:-}") || return 1
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
  if [ "${PAM_RUNTIME_PROXIES+x}" = "x" ]; then
    rows="$PAM_RUNTIME_PROXIES"
  else
    rows=$(github_proxy_decode "${RUNTIME_GITHUB_ROUTES:-}") || return 1
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
  local id="$1" url="$2" out="$3" validator="$4" part route rc=0
  part="$out.part"; route="$out.part.route"
  if [ -s "$route" ] && [ "$(sed -n '1p' "$route" 2>/dev/null)" = "$id" ]; then :
  else rm -f -- "$part" "$route"; fi
  printf '%s\n' "$id" > "$route" || return 1

  if declare -F github_proxy_transfer_hook >/dev/null 2>&1; then
    github_proxy_transfer_hook "$url" "$part" || rc=$?
  else
    github_proxy_prepare_curl || return 1
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
  [ "$rc" = "0" ] || return "$rc"
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
  local state_root root candidates preferred preferred_line batch_size index=0 batch_start=1 id url current rc content_failed=0
  local batch_file ordered_file
  github_proxy_validate_source "$capability" "$source" || return 64
  declare -F "$validator" >/dev/null 2>&1 || return 64
  batch_size=$(github_proxy_batch_size)
  state_root="${GITHUB_PROXY_STATE_DIR:-${TMPDIR:-/tmp}}"
  root="$state_root/github-proxy-probe.$$"; mkdir -p "$root" || return 1
  candidates=$(github_proxy_candidates "$capability" "$source") || { rm -rf -- "$root"; return 1; }
  # Resume the same endpoint first on the next launch. Bytes are still never
  # combined across routes; an unavailable preferred route falls back to the
  # normal capability-filtered order.
  preferred=$(sed -n '1p' "$out.part.route" 2>/dev/null || true)
  if [ -n "$preferred" ]; then
    preferred_line=$(awk -F '\t' -v id="$preferred" '$1 == id {print; exit}' <<< "$candidates")
    if [ -n "$preferred_line" ]; then
      candidates="$preferred_line"$'\n'"$(awk -F '\t' -v id="$preferred" '$1 != id' <<< "$candidates")"
    fi
  fi
  batch_file="$root/batch.tsv"; ordered_file="$root/ordered.tsv"; : > "$batch_file"

  while IFS=$'\t' read -r id url; do
    [ -n "$id" ] && [ -n "$url" ] || continue
    index=$((index + 1)); printf '%s\t%s\n' "$id" "$url" >> "$batch_file"
    github_proxy_probe_one "$id" "$url" "$root" &
    if [ $((index - batch_start + 1)) -lt "$batch_size" ]; then continue; fi
    wait || true
    github_proxy_order_batch "$root" "$batch_file" "$ordered_file" "$preferred"
    while IFS=$'\t' read -r current url; do
      if github_proxy_transfer_one "$current" "$url" "$out" "$validator"; then
        rm -rf -- "$root"; return 0
      else rc=$?; fi
      if [ "$rc" = "70" ]; then rm -rf -- "$root"; return 70; fi
      [ "$rc" != "65" ] || content_failed=1
    done < "$ordered_file"
    rm -rf -- "$root/winner.lock"; rm -f -- "$root/winner" "$root"/ok.* "$root"/probe.*
    : > "$batch_file"; batch_start=$((index + 1))
  done <<< "$candidates"

  if [ -s "$batch_file" ]; then
    wait || true
    github_proxy_order_batch "$root" "$batch_file" "$ordered_file" "$preferred"
    while IFS=$'\t' read -r current url; do
      if github_proxy_transfer_one "$current" "$url" "$out" "$validator"; then
        rm -rf -- "$root"; return 0
      else rc=$?; fi
      if [ "$rc" = "70" ]; then rm -rf -- "$root"; return 70; fi
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
  local source="$1" destination="$2" state_root root candidates batch_size index=0 batch_start=1
  local id url current rc batch_file ordered_file
  github_proxy_validate_source clone "$source" || return 64
  [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 64
  batch_size=$(github_proxy_batch_size)
  state_root="${GITHUB_PROXY_STATE_DIR:-${TMPDIR:-/tmp}}"
  root="$state_root/github-proxy-clone.$$"; mkdir -p "$root" || return 1
  candidates=$(github_proxy_candidates clone "$source") || { rm -rf -- "$root"; return 1; }
  batch_file="$root/batch.tsv"; ordered_file="$root/ordered.tsv"; : > "$batch_file"

  while IFS=$'\t' read -r id url; do
    [ -n "$id" ] && [ -n "$url" ] || continue
    index=$((index + 1)); printf '%s\t%s\n' "$id" "$url" >> "$batch_file"
    github_proxy_clone_probe_one "$id" "$url" "$root" &
    if [ $((index - batch_start + 1)) -lt "$batch_size" ]; then continue; fi
    wait || true
    github_proxy_order_batch "$root" "$batch_file" "$ordered_file" ""
    while IFS=$'\t' read -r current url; do
      if github_proxy_clone_one "$url" "$destination"; then rm -rf -- "$root"; return 0
      else rc=$?; fi
      [ "$rc" != 70 ] || { rm -rf -- "$root"; return 70; }
    done < "$ordered_file"
    rm -rf -- "$root/winner.lock"; rm -f -- "$root/winner" "$root"/ok.* "$root"/probe.*
    : > "$batch_file"; batch_start=$((index + 1))
  done <<< "$candidates"

  if [ -s "$batch_file" ]; then
    wait || true
    github_proxy_order_batch "$root" "$batch_file" "$ordered_file" ""
    while IFS=$'\t' read -r current url; do
      if github_proxy_clone_one "$url" "$destination"; then rm -rf -- "$root"; return 0
      else rc=$?; fi
      [ "$rc" != 70 ] || { rm -rf -- "$root"; return 70; }
    done < "$ordered_file"
  fi
  rm -rf -- "$root"
  return 1
}
