#!/usr/bin/env bash
# LastWave — build an x86_64 AppImage by hand, without linuxdeploy.
#
# ---------------------------------------------------------------------------
# HONESTY NOTICE — THIS IS NOT A SELF-CONTAINED APPIMAGE.
#
# Only the Flutter bundle (the Dart AOT library, the engine, and the app's own
# plugin .so files) is embedded. The system graphics/audio stack is NOT bundled
# and must already exist on the host:
#
#   gtk3              -> libgtk-3.so.0       (hard build dep: linux/CMakeLists.txt:55)
#   webkit2gtk-4.1    -> libwebkit2gtk-4.1.so.0  (desktop_webview_window)
#   libayatana-appindicator      -> tray_menu.so (tray_manager)
#   alsa-lib          -> libasound.so.2      (default media_kit output path)
#   mpv               -> libmpv.so.2         (media_kit_* plugins; see nfpm.yaml
#                                            archlinux depends for the
#                                            per-package name mapping)
#
# Bundling webkit2gtk is infeasible (huge, and it needs a matching GTK), which
# is exactly why linuxdeploy + its GTK/WebKit plugins is NOT used here. On Arch
# all of the above are in the official repos and already installed on a normal
# desktop, so this AppImage is intended for Arch/KDE/GNOME hosts that meet
# those requirements. The artifact is deliberately NAMED
# `LastWave-Arch-x86_64.AppImage` so nobody mistakes it for a fully
# self-contained image.
# ---------------------------------------------------------------------------
#
# Why no linuxdeploy: it would drag in linuxdeploy-plugin-gtk / -Qt plus a
# WebKit plugin, hundreds of MB, and a fragile runtime dependency chain. The
# Flutter bundle already has the right relative layout, so the only thing the
# AppImage runtime must supply is the AppDir metadata below.
#
# Layout produced (APPDIR/):
#   AppRun                      POSIX sh launcher (sets LD_LIBRARY_PATH, execs)
#   lastwave.desktop            root desktop entry (appimagetool requires this)
#   lastwave.png                256px icon (referenced by Icon=)
#   .DirIcon                    symlink -> lastwave.png
#   usr/bin/lastwave_desktop    entry point on the AppImage-internal PATH
#   usr/lib/lastwave/           the whole Flutter bundle tree, verbatim
#
# Usage: tool/build_appimage.sh [BUNDLE_DIR] [OUT_DIR]
# Defaults: build/linux/x64/release/bundle and dist/

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_DIR="${1:-$REPO_ROOT/build/linux/x64/release/bundle}"
OUT_DIR="${2:-$REPO_ROOT/dist}"

# Binary name is fixed by linux/CMakeLists.txt:7 (BINARY_NAME "lastwave_desktop").
# Matches nfpm.yaml and StartupWMClass in linux/packaging/lastwave.desktop.
BIN_NAME="lastwave_desktop"
APP_NAME="lastwave"

# Pinned appimagetool release. NOT the probonopd/AppImageKit repo: that project
# is obsolete and its v13 assets are literally named `obsolete-appimagetool-*`.
# The maintained tool is AppImage/appimagetool; 1.9.1 is its newest non-prerelease.
#   https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage
APPIMAGETOOL_VERSION="1.9.1"
APPIMAGETOOL_URL="https://github.com/AppImage/appimagetool/releases/download/${APPIMAGETOOL_VERSION}/appimagetool-x86_64.AppImage"

# Artifact name says "Arch" on purpose -> not a self-contained image (see above).
APPIMAGE_OUT="LastWave-Arch-x86_64.AppImage"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# appimagetool refuses to run as root ("Do not run appimagetool as root").
# The GitHub runner is a non-root user, so never sudo here — cd into the
# workspace instead. Fail loudly rather than silently producing something odd.
if [ "$(id -u)" -eq 0 ]; then
  die "refusing to run as root: appimagetool rejects root. Run as a normal user (do NOT use sudo)."
fi

# --------------------------------------------------------------------------
# 0. Validate the Flutter bundle exists before doing any work.
# --------------------------------------------------------------------------
[ -d "$BUNDLE_DIR" ] || die "bundle not found: $BUNDLE_DIR (run 'flutter build linux --release' first)"
[ -x "$BUNDLE_DIR/$BIN_NAME" ] || die "bundle binary missing: $BUNDLE_DIR/$BIN_NAME"
[ -d "$BUNDLE_DIR/data" ] || die "bundle data/ missing: $BUNDLE_DIR/data"
[ -d "$BUNDLE_DIR/lib" ] || die "bundle lib/ missing: $BUNDLE_DIR/lib"
[ -f "$BUNDLE_DIR/lib/libflutter_linux_gtk.so" ] || die "libflutter_linux_gtk.so missing from bundle lib/"

# The bundle binary must run from INSIDE the bundle tree. Flutter's runner
# resolves both `data/flutter_assets` and the AOT snapshot `lib/libapp.so`
# relative to dirname(/proc/self/exe). linux/CMakeLists.txt:63-66 says so
# explicitly ("resources must in the right relative locations").
#
# So usr/bin/$BIN_NAME is a SYMLINK into the bundle, not a copy: exec'ing it
# makes /proc/self/exe resolve to .../usr/lib/lastwave/$BIN_NAME, and every
# relative lookup (data/, lib/libapp.so, plugin dlopens, $ORIGIN/lib rpath)
# lands back in the bundle correctly. A copy here would launch a runner that
# cannot find its own assets, and LD_LIBRARY_PATH cannot rescue that because
# libapp.so is dlopen'd by absolute path, not by soname.

# --------------------------------------------------------------------------
# 1. Assemble the AppDir.
# --------------------------------------------------------------------------
APPDIR="$OUT_DIR/AppDir"
TOOLS_DIR="$OUT_DIR/.appimagetool"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$TOOLS_DIR"

# The whole bundle tree, verbatim: data/, lib/libflutter_linux_gtk.so,
# lib/libapp.so, lib/libmpv.so.2 (after patchelf normalization) and the
# media_kit / window_manager plugin .so files all come along.
log "Copying bundle tree -> $APPDIR/usr/lib/lastwave"
cp -a "$BUNDLE_DIR" "$APPDIR/usr/lib/lastwave"

# Note the "../../": the link lives in AppDir/usr/bin/, so ../../ is AppDir/.
ln -sf "../../usr/lib/lastwave/$BIN_NAME" "$APPDIR/usr/bin/$BIN_NAME"

# Fail loudly here rather than shipping an AppImage whose entry point dangles.
[ -e "$APPDIR/usr/bin/$BIN_NAME" ] || die "entry point symlink does not resolve: $APPDIR/usr/bin/$BIN_NAME"

# --------------------------------------------------------------------------
# 2. Icon (256px PNG). appimagetool wants a square >=256px icon at the AppDir
#    root. The repo asset is 1024x1024. Prefer an already-present image tool;
#    do NOT add an apt package just to resize. The GitHub ubuntu-22.04 runner
#    image ships ImageMagick, but if neither `convert` nor `magick` is present
#    the PNG is copied as-is — appimagetool accepts an oversized icon, it just
#    makes the image a bit heavier.
# --------------------------------------------------------------------------
ICON_SRC="$REPO_ROOT/lastwave-logo.png"
[ -f "$ICON_SRC" ] || die "icon source missing: $ICON_SRC"
log "Writing icon ($APP_NAME.png)"
if command -v magick >/dev/null 2>&1; then
  magick "$ICON_SRC" -background none -resize 256x256 "$APPDIR/$APP_NAME.png"
elif command -v convert >/dev/null 2>&1; then
  convert "$ICON_SRC" -background none -resize 256x256 "$APPDIR/$APP_NAME.png"
else
  echo "note: no 'convert'/'magick' in PATH; copying $(basename "$ICON_SRC") as-is ($(wc -c < "$ICON_SRC") bytes, 1024x1024)" >&2
  cp "$ICON_SRC" "$APPDIR/$APP_NAME.png"
fi
ln -sf "$APP_NAME.png" "$APPDIR/.DirIcon"

# --------------------------------------------------------------------------
# 3. Root desktop entry. appimagetool requires one .desktop file at the AppDir
#    root, and its Icon= must resolve to the root icon.
# --------------------------------------------------------------------------
cat > "$APPDIR/$APP_NAME.desktop" <<EOF
[Desktop Entry]
Name=LastWave
Comment=Desktop music player — YouTube Music, lossless audio, Last.fm scrobbling
Exec=$BIN_NAME
Icon=$APP_NAME
Terminal=false
Type=Application
Categories=AudioVideo;Audio;Player;
StartupWMClass=$BIN_NAME
EOF

# --------------------------------------------------------------------------
# 4. AppRun. POSIX sh only (no bashisms) — it runs under dash/ash on some
#    systems, and it is the process the runtime execs.
# --------------------------------------------------------------------------
cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
# Launcher for the LastWave AppImage. POSIX sh, no bashisms.
set -eu
HERE=$(dirname "$(readlink -f "$0")")
export LD_LIBRARY_PATH="$HERE/usr/lib/lastwave/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$HERE/usr/bin/lastwave_desktop" "$@"
EOF
chmod 755 "$APPDIR/AppRun"

# --------------------------------------------------------------------------
# 5. Fetch appimagetool (pinned). curl -fL so a 404/HTML error page fails the
#    build loudly instead of being chmod +x'd into a mystery. Note that
#    appimagetool 1.9.x additionally downloads the type2 runtime from
#    github.com/AppImage/type2-runtime at run time; --runtime-file can pin
#    that too if reproducibility ever matters.
# --------------------------------------------------------------------------
TOOL="$TOOLS_DIR/appimagetool-x86_64.AppImage"
if [ ! -x "$TOOL" ]; then
  log "Downloading appimagetool $APPIMAGETOOL_VERSION"
  curl -fL --retry 3 --retry-connrefused -o "$TOOL" "$APPIMAGETOOL_URL"
  chmod +x "$TOOL"
fi
# Guard against an HTML error page saved under an .AppImage name.
[ "$(wc -c < "$TOOL")" -gt 1000000 ] || die "appimagetool download looks wrong (too small)"

# --------------------------------------------------------------------------
# 6. Build the image.
#    - ARCH=x86_64        : explicit, so tool/runtime arch selection never guesses
#    - APPIMAGE_EXTRACT_AND_RUN=1 : GitHub runners have no FUSE; the documented
#                           escape hatch so the tool itself can start.
#    -n/--no-appstream    : appstreamcli is not installed here and we ship no
#                           AppStream metadata; without this appimagetool tries
#                           to validate metadata and fails.
#    No sudo, ever — appimagetool rejects root.
# --------------------------------------------------------------------------
log "Running appimagetool (needs host gtk3 / webkit2gtk-4.1 / alsa-lib / mpv at RUNTIME)"
( cd "$OUT_DIR" && \
  ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 \
    "$TOOL" --no-appstream "$APPDIR" "$OUT_DIR/$APPIMAGE_OUT" )

[ -f "$OUT_DIR/$APPIMAGE_OUT" ] || die "appimagetool did not produce $APPIMAGE_OUT"

log "Built $OUT_DIR/$APPIMAGE_OUT ($(du -h "$OUT_DIR/$APPIMAGE_OUT" | cut -f1))"
cat <<EOF

REMINDER: this AppImage embeds only the Flutter bundle. The HOST must provide
gtk3, webkit2gtk-4.1, libayatana-appindicator, alsa-lib and mpv (all standard
on Arch). It is not a self-contained image.
EOF