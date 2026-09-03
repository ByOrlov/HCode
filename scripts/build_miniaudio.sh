#!/usr/bin/env bash
# Build the miniaudio C bridge (vendor/miniaudio) and print the linker flags
# required to link it into the Crystal binary.
#
#   ./scripts/build_miniaudio.sh [crystal-target-triplet]
#
# The bridge sources are committed to the repo, but the compiled objects are
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

target="${1:-}"
if [ -z "$target" ]; then
  case "$(uname -s)" in
    Darwin)              target="x86_64-darwin" ;;
    Linux)               target="x86_64-linux" ;;
    MINGW*|MSYS*|CYGWIN*) target="x86_64-windows" ;;
  esac
fi

# Try to locate an MSVC cl.exe on Windows. Crystal uses MSVC as its native
# toolchain on Windows, so mixing a MinGW-compiled bridge archive with the MSVC
# link step causes C-runtime symbol mismatches (duplicate NtCurrentTeb,
# unresolved ___chkstk_ms / sincos / MapViewOfFileNuma2, etc.).
find_msvc_cl() {
  # Already on PATH (check both names because MSYS bash sometimes needs .exe).
  for name in cl cl.exe; do
    if command -v "$name" >/dev/null 2>&1; then
      command -v "$name"
      return 0
    fi
  done

  local vswhere=""
  for p in \
    "/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe" \
    "/c/Program Files/Microsoft Visual Studio/Installer/vswhere.exe"
  do
    if [ -x "$p" ]; then
      vswhere="$p"
      break
    fi
  done
  [ -n "$vswhere" ] || return 1

  local install_path
  install_path=$("$vswhere" -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>/dev/null | head -n1 | tr -d '\r')
  [ -n "$install_path" ] || return 1

  # Convert the Windows installation path to POSIX so bash can glob.
  local posix_path
  if command -v cygpath >/dev/null 2>&1; then
    posix_path=$(cygpath -u "$install_path")
  else
    posix_path=$(echo "$install_path" | sed 's|\\|/|g; s|^\([A-Za-z]\):|/\L\1|')
  fi

  local cl_exe
  cl_exe=$(ls -d "$posix_path/VC/Tools/MSVC"/*/bin/Hostx64/x64/cl.exe 2>/dev/null | sort -V | tail -n1)
  [ -n "$cl_exe" ] && [ -x "$cl_exe" ] || return 1
  echo "$cl_exe"
}

build_unix() {
  "$CC" -c $CFLAGS -I"$MA_DIR" "$MA_DIR/miniaudio_bridge.c" -o "$MA_DIR/miniaudio_bridge.o"
  ar rcs "$MA_DIR/libminiaudio_bridge.a" "$MA_DIR/miniaudio_bridge.o"
}

build_windows_msvc() {
  local cl_exe="$1"
  local obj="$MA_DIR/miniaudio_bridge.obj"
  # Remove stale artifacts from any previous MinGW build so we don't accidentally
  # pick up the wrong object during packaging.
  rm -f "$MA_DIR/miniaudio_bridge.o" "$MA_DIR/libminiaudio_bridge.a" "$obj" "$MA_DIR/miniaudio_bridge.lib"
  # cl.exe prints diagnostics (including compile errors) to stdout, not stderr.
  # CI captures this script's stdout via $(...) to get the link flags, so mirror
  # cl's chatter to stderr or a compile failure is completely silent.
  "$cl_exe" -nologo -O2 -c -I"$MA_DIR" "$MA_DIR/miniaudio_bridge.c" -Fo"$obj" 1>&2
  # Pass the object by full path; Crystal forwards it to cl.exe/link.exe, which
  # treats *.obj as a native object file.
  echo "$obj winmm.lib ole32.lib ksuser.lib"
}

build_windows_mingw() {
  # Used for cross-compiles from Unix or as a fallback when MSVC is missing.
  "$CC" -c $CFLAGS -I"$MA_DIR" "$MA_DIR/miniaudio_bridge.c" -o "$MA_DIR/miniaudio_bridge.o"
  ar rcs "$MA_DIR/libminiaudio_bridge.a" "$MA_DIR/miniaudio_bridge.o"
  echo "$MA_DIR/libminiaudio_bridge.a winmm.lib ole32.lib ksuser.lib"
}

case "$target" in
  *-darwin*)
    build_unix
    # CoreAudio backend — dlopens nothing, frameworks only.
    echo "-L$MA_DIR -lminiaudio_bridge -framework CoreAudio -framework AudioToolbox -framework CoreFoundation" ;;
  *-windows*|*-win32*|*-mingw*)
    cl_exe=$(find_msvc_cl || true)
    if [ -n "$cl_exe" ]; then
      build_windows_msvc "$cl_exe"
    else
      build_windows_mingw
    fi ;;
  *)
    build_unix
    # Linux: PulseAudio/ALSA are dlopened at runtime, only the base libs are needed.
    echo "-L$MA_DIR -lminiaudio_bridge -ldl -lpthread -lm" ;;
esac
