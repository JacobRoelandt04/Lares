#!/usr/bin/env bash
# build.sh -- build lares-ime (the dictation's input method) from lares-ime.c and the two vendored protocol XMLs (MIT, Purism / Collabora).
#
#   tools/stt/ime/build.sh [OUT]     default OUT: ~/.cache/lares-stt/bin/lares-ime
#
# Needs gcc, wayland-scanner, wayland-client and xkbcommon (all on this machine; no download). The binary never goes into the repo:
# the deployed snapshot moves on every deploy, and the shell finds the binary in the cache (DictationService `imePath`).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-${LARES_STT_HOME:-$HOME/.cache/lares-stt}/bin/lares-ime}"
gen="$(mktemp -d)"
trap 'rm -rf "$gen"' EXIT
for p in input-method-unstable-v2 virtual-keyboard-unstable-v1; do
    wayland-scanner client-header "$here/protocols/$p.xml" "$gen/$p-client-protocol.h"
    wayland-scanner private-code "$here/protocols/$p.xml" "$gen/$p-protocol.c"
done
mkdir -p "$(dirname "$out")"
# shellcheck disable=SC2046
gcc -O2 -Wall -Wextra -o "$out.tmp" -I "$gen" "$here/lares-ime.c" "$gen"/*-protocol.c $(pkg-config --cflags --libs wayland-client xkbcommon)
mv "$out.tmp" "$out"
echo "ok lares-ime -> $out"
