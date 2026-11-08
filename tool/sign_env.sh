#!/usr/bin/env bash
# Stable release signing for sideways installs.
#
# Each fresh sandbox used to create a new debug keystore, so every APK had a new
# certificate and had to be uninstalled before installing — which deletes the
# local archive the app is supposed to keep. This keeps one keystore outside the
# source tree and passes it to Gradle through the environment; when the variables
# are absent Gradle still falls back to the debug key, so nothing in the source
# becomes machine-specific.
set -euo pipefail
export JAVA_HOME=${JAVA_HOME:-/home/user/sdk/jdk17}
KEYTOOL="$JAVA_HOME/bin/keytool"
KEYS=${IRONPIN_KEYS_DIR:-/home/user/keys}
KEYSTORE="$KEYS/ironpin-release.jks"
if [ ! -f "$KEYSTORE" ]; then
  mkdir -p "$KEYS"
  "$KEYTOOL" -genkeypair -v -keystore "$KEYSTORE" -storetype PKCS12 \
    -alias ironpin-release -keyalg RSA -keysize 4096 -validity 10950 \
    -storepass ironpin-local-only -keypass ironpin-local-only \
    -dname "CN=IronPin Local Sideload, OU=IronPin, O=IronPin, L=Tehran, C=IR"
fi
export IRONPIN_KEYSTORE="$KEYSTORE"
export IRONPIN_STORE_PASSWORD=ironpin-local-only
export IRONPIN_KEY_ALIAS=ironpin-release
export IRONPIN_KEY_PASSWORD=ironpin-local-only
