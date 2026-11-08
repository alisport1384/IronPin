#!/usr/bin/env bash
# Restores the pinned toolchain (Flutter 3.24.5, Temurin JDK 17, Android SDK
# platform 35 + build-tools 35.0.0) after the sandbox snapshot dropped it.
set -euo pipefail
ROOT=/home/user/sdk
DL=/home/user/dl
mkdir -p "$ROOT" "$DL"

if [ ! -x "$ROOT/flutter/bin/flutter" ]; then
  echo "== flutter"
  curl -sSL -o "$DL/flutter.tar.xz" \
    https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.24.5-stable.tar.xz
  mkdir -p "$ROOT/flutter"
  tar -xf "$DL/flutter.tar.xz" -C "$ROOT/flutter" --strip-components=1
  rm -f "$DL/flutter.tar.xz"
fi

if [ ! -x "$ROOT/jdk17/bin/java" ]; then
  echo "== jdk17"
  curl -sSL -o "$DL/jdk17.tar.gz" \
    "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.13%2B11/OpenJDK17U-jdk_x64_linux_hotspot_17.0.13_11.tar.gz"
  mkdir -p "$ROOT/jdk17"
  tar -xzf "$DL/jdk17.tar.gz" -C "$ROOT/jdk17" --strip-components=1
  rm -f "$DL/jdk17.tar.gz"
fi

if [ ! -x "$ROOT/android-sdk/build-tools/35.0.0/aapt" ]; then
  echo "== android sdk"
  mkdir -p "$ROOT/android-sdk/cmdline-tools"
  curl -sSL -o "$DL/cmdline.zip" \
    https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
  unzip -q -o "$DL/cmdline.zip" -d "$DL/cmdline"
  rm -rf "$ROOT/android-sdk/cmdline-tools/latest"
  mv "$DL/cmdline/cmdline-tools" "$ROOT/android-sdk/cmdline-tools/latest"
  rm -rf "$DL/cmdline" "$DL/cmdline.zip"
  export JAVA_HOME="$ROOT/jdk17"
  export ANDROID_SDK_ROOT="$ROOT/android-sdk"
  yes | "$ROOT/android-sdk/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null 2>&1 || true
  "$ROOT/android-sdk/cmdline-tools/latest/bin/sdkmanager" \
    "platform-tools" "platforms;android-35" "build-tools;35.0.0" >/dev/null
fi

export PATH="$ROOT/flutter/bin:$PATH"
export JAVA_HOME="$ROOT/jdk17"
export ANDROID_SDK_ROOT="$ROOT/android-sdk"
cd /home/user/IronPin
git config --global --add safe.directory /home/user/IronPin || true
flutter --version
flutter pub get
echo TOOLCHAIN_READY
