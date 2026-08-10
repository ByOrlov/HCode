#!/usr/bin/env bash
# Build the miniaudio C bridge (vendor/miniaudio) and print the linker flags
# required to link it into the Crystal binary.
#
#   ./scripts/build_miniaudio.sh [crystal-target-triplet]
#
# The bridge sources are committed to the repo, but the compiled .o/.a are
# gitignored, so CI must rebuild them. This mirrors the logic in the Rakefile
# so local `rake` builds and CI produce the same link configuration.
#
# Honors $CC (set by CI cross-compile wrappers, e.g. the macOS x86_64 wrapper
# that injects `-arch x86_64`) and $CFLAGS. When no target triplet is given the
# host OS is used to pick frameworks/libraries. The full `--link-flags` string
# is printed on the last line.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MA_DIR="$ROOT/vendor/miniaudio"
CC="${CC:-cc}"
CFLAGS="${CFLAGS:--O2}"

"$CC" -c $CFLAGS -I"$MA_DIR" "$MA_DIR/miniaudio_bridge.c" -o "$MA_DIR/miniaudio_bridge.o"
ar rcs "$MA_DIR/libminiaudio_bridge.a" "$MA_DIR/miniaudio_bridge.o"

target="${1:-}"
if [ -z "$target" ]; then
  case "$(uname -s)" in
    Darwin)              target="x86_64-darwin" ;;
    Linux)               target="x86_64-linux" ;;
    MINGW*|MSYS*|CYGWIN*) target="x86_64-windows" ;;
  esac
fi

case "$target" in
  *-darwin*)
    # CoreAudio backend — dlopens nothing, frameworks only.
    echo "-L$MA_DIR -lminiaudio_bridge -framework CoreAudio -framework AudioToolbox -framework CoreFoundation" ;;
  *-windows*|*-win32*|*-mingw*)
    # WASAPI/WinMM backend. Crystal drives MSVC's link.exe on Windows, which
    # does not understand GCC-style -L/-l flags (they get mangled into
    # invalid /L / /l options and the archive is silently dropped). Pass the
    # archive by full path and the Win32 import libraries as *.lib names so
    # link.exe resolves them through the Windows SDK LIBPATH.
    echo "$MA_DIR/libminiaudio_bridge.a winmm.lib ole32.lib ksuser.lib" ;;
  *)
    # Linux: PulseAudio/ALSA are dlopened at runtime, only the base libs are needed.
    echo "-L$MA_DIR -lminiaudio_bridge -ldl -lpthread -lm" ;;
esac
