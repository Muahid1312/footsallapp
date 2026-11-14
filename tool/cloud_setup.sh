#!/usr/bin/env bash
# Bootstrap/refresh the cloud toolchain. Requires the package-manager network
# preset plus storage.googleapis.com. Uses existing application checkout.
set -euo pipefail

export ANDROID_HOME=/workspace/toolchains/android
export ANDROID_USER_HOME=/workspace/toolchains/android-user
export PUB_CACHE=/workspace/toolchains/pub-cache
export GRADLE_USER_HOME=/workspace/toolchains/gradle-cache
export PATH="/workspace/toolchains/flutter/bin:$ANDROID_HOME/platform-tools:$PATH"

mkdir -p /workspace/toolchains
if [ ! -d /workspace/toolchains/flutter ]; then
  git clone --depth 1 --branch 3.35.7 https://github.com/flutter/flutter.git /workspace/toolchains/flutter
fi
flutter_commit=$(git -C /workspace/toolchains/flutter rev-parse HEAD)
if [ "$flutter_commit" != adc901062556672b4138e18a4dc62a4be8f4b3c2 ]; then
  echo 'Expected Flutter 3.35.7. Preserve any toolchain changes before replacing it.' >&2
  exit 1
fi

if [ ! -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]; then
  sdk_archive=$(mktemp /tmp/futsal-android-sdk.XXXXXX.zip)
  sdk_extract=$(mktemp -d /tmp/futsal-android-sdk.XXXXXX)
  trap 'rm -f "$sdk_archive"; rm -rf "$sdk_extract"' EXIT
  curl --fail --location https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip -o "$sdk_archive"
  unzip -q "$sdk_archive" -d "$sdk_extract"
  mkdir -p "$ANDROID_HOME/cmdline-tools"
  mv "$sdk_extract/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
fi

# Avoid masking SDK manager failures with `yes | ...` SIGPIPE handling.
python3 - <<'PY'
import os, subprocess
sdk = os.environ['ANDROID_HOME']
command = [sdk + '/cmdline-tools/latest/bin/sdkmanager', '--sdk_root=' + sdk]
subprocess.run(command + ['--licenses'], input='y\n' * 100, text=True, check=True)
subprocess.run(command + ['platform-tools', 'platforms;android-36',
    'build-tools;35.0.0', 'ndk;27.0.12077973'], check=True)
PY

flutter --version
flutter precache --android
cd /workspace/footsallapp
flutter pub get
echo 'Dependencies prepared. Run flutter analyze and flutter test before claiming readiness.'
