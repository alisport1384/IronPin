#!/usr/bin/env bash
# Hardened toolchain bootstrap: verifies the pinned toolchain (Flutter 3.24.5,
# Temurin JDK 17, Android SDK 35 + build-tools 35.0.0) and re-downloads any part
# that a sandbox snapshot truncated. Safe to re-run.
set -uo pipefail
ROOT=/home/user/sdk
DL=/home/user/dl
mkdir -p "$ROOT" "$DL"

log() { echo "[bootstrap] $*"; }

# --- Flutter -----------------------------------------------------------------
flutter_ok() {
  [ -x "$ROOT/flutter/bin/cache/dart-sdk/bin/dart" ] &&
  "$ROOT/flutter/bin/cache/dart-sdk/bin/dart" --version >/dev/null 2>&1 &&
  [ -f "$ROOT/flutter/version" ] &&
  [ -d "$ROOT/flutter/packages/flutter_tools" ]
}
if ! flutter_ok; then
  log "flutter: downloading 3.24.5"
  rm -rf "$ROOT/flutter"
  curl -sSL --retry 3 -o "$DL/flutter.tar.xz" \
    https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.24.5-stable.tar.xz
  mkdir -p "$ROOT/flutter"
  tar -xf "$DL/flutter.tar.xz" -C "$ROOT/flutter" --strip-components=1 || exit 1
  rm -f "$DL/flutter.tar.xz"
  chmod +x "$ROOT"/flutter/bin/* 2>/dev/null
  rm -rf "$ROOT/flutter/bin/cache/artifacts" "$ROOT/flutter/bin/cache/flutter_web_sdk"
fi
export PATH="$ROOT/flutter/bin:$PATH"

# --- JDK 17 ------------------------------------------------------------------
if [ ! -x "$ROOT/jdk17/bin/java" ] || ! "$ROOT/jdk17/bin/java" -version >/dev/null 2>&1; then
  log "jdk17: downloading temurin 17"
  rm -rf "$ROOT/jdk17"; mkdir -p "$ROOT/jdk17"
  curl -sSL --retry 3 -o "$DL/jdk17.tar.gz" \
    "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.13%2B11/OpenJDK17U-jdk_x64_linux_hotspot_17.0.13_11.tar.gz"
  tar -xzf "$DL/jdk17.tar.gz" -C "$ROOT/jdk17" --strip-components=1 || exit 1
  rm -f "$DL/jdk17.tar.gz"
fi
export JAVA_HOME="$ROOT/jdk17"
export PATH="$JAVA_HOME/bin:$PATH"

# --- Android SDK -------------------------------------------------------------
export ANDROID_SDK_ROOT="$ROOT/android-sdk"
if [ ! -x "$ROOT/android-sdk/build-tools/35.0.0/aapt" ]; then
  log "android-sdk: downloading cmdline-tools + platform 35"
  mkdir -p "$ROOT/android-sdk/cmdline-tools"
  if [ ! -x "$ROOT/android-sdk/cmdline-tools/latest/bin/sdkmanager" ]; then
    curl -sSL --retry 3 -o "$DL/cmdline.zip" \
      https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
    unzip -q -o "$DL/cmdline.zip" -d "$DL/cmdline"
    rm -rf "$ROOT/android-sdk/cmdline-tools/latest"
    mv "$DL/cmdline/cmdline-tools" "$ROOT/android-sdk/cmdline-tools/latest"
    rm -rf "$DL/cmdline" "$DL/cmdline.zip"
  fi
  yes | "$ROOT/android-sdk/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null 2>&1 || true
  "$ROOT/android-sdk/cmdline-tools/latest/bin/sdkmanager" \
    "platform-tools" "platforms;android-35" "build-tools;35.0.0" >/dev/null 2>&1 || exit 1
fi

# --- Flutter engine artifacts + pub packages ---------------------------------
cd /home/user/IronPin || exit 1
log "flutter: precache android artifacts"
flutter --version || exit 1
flutter config --no-analytics >/dev/null 2>&1 || true
flutter pub get || exit 1
log "TOOLCHAIN_READY"
