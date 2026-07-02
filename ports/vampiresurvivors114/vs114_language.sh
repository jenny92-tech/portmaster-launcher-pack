#!/bin/sh

vs114_apply_language() {
  toml=$1
  confdir=$2
  case "${3:-zh-CN}" in
    en|en-US)
      pref_lang=en
      locale_tag=en-US
      device_lang=en
      device_country=US
      ;;
    *)
      pref_lang=zh-CN
      locale_tag=zh-CN
      device_lang=zh
      device_country=CN
      ;;
  esac

  prefs="$confdir/shared_prefs/com.poncle.vampiresurvivors.v2.playerprefs.json"
  mkdir -p "$(dirname "$prefs")"
  if [ -f "$prefs" ] && grep -q '"I2 Language"' "$prefs"; then
    sed "s/\"I2 Language\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"I2 Language\": \"$pref_lang\"/" "$prefs" > "$prefs.tmp" &&
      mv "$prefs.tmp" "$prefs"
  elif [ -f "$prefs" ] && grep -q '"strings"[[:space:]]*:[[:space:]]*{' "$prefs"; then
    awk -v lang="$pref_lang" '
      !done && /"strings"[[:space:]]*:[[:space:]]*{/ {
        print
        print "    \"I2 Language\": \"" lang "\","
        done=1
        next
      }
      { print }
    ' "$prefs" > "$prefs.tmp" && mv "$prefs.tmp" "$prefs"
  else
    printf '{"bools":{},"floats":{},"ints":{},"longs":{},"strings":{"I2 Language":"%s"},"version":1}\n' "$pref_lang" > "$prefs"
  fi

  for save in "$confdir/SaveDataUnity.sav" "$confdir/SaveDataUnity.bak.sav"; do
    [ -f "$save" ] || continue
    command -v sha256sum >/dev/null 2>&1 || continue
    sed \
      -e "s/\"Language\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"Language\":\"$pref_lang\"/" \
      -e 's/"checksum"[[:space:]]*:[[:space:]]*"[^"]*"/"checksum":""/' \
      "$save" > "$save.tmp"
    checksum=$(sha256sum "$save.tmp" | awk '{print $1}')
    sed "s/\"checksum\"[[:space:]]*:[[:space:]]*\"\"/\"checksum\":\"$checksum\"/" \
      "$save.tmp" > "$save.new" &&
      mv "$save.new" "$save"
    rm -f "$save.tmp" "$save.new"
  done

  awk -v locale_tag="$locale_tag" -v device_lang="$device_lang" -v device_country="$device_country" '
    function close_device() {
      if (in_device) {
        if (!saw_language) print "language=\"" device_lang "\""
        if (!saw_country) print "country=\"" device_country "\""
        in_device=0
        wrote_device=1
      }
    }
    function close_locale() {
      if (in_locale) {
        if (!saw_tag) print "tag=\"" locale_tag "\""
        in_locale=0
        wrote_locale=1
      }
    }
    /^\[/ {
      close_device()
      close_locale()
      if ($0 == "[device]") {
        print
        in_device=1
        saw_language=0
        saw_country=0
        next
      }
      if ($0 == "[locale]") {
        print
        in_locale=1
        saw_tag=0
        next
      }
    }
    in_device && /^language[[:space:]]*=/ {
      print "language=\"" device_lang "\""
      saw_language=1
      next
    }
    in_device && /^country[[:space:]]*=/ {
      print "country=\"" device_country "\""
      saw_country=1
      next
    }
    in_locale && /^tag[[:space:]]*=/ {
      print "tag=\"" locale_tag "\""
      saw_tag=1
      next
    }
    { print }
    END {
      close_device()
      close_locale()
      if (!wrote_locale) {
        print ""
        print "[locale]"
        print "tag=\"" locale_tag "\""
      }
    }
  ' "$toml" > "$toml.tmp" && mv "$toml.tmp" "$toml"
}
