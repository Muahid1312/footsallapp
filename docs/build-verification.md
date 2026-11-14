# Verified personal testing build

- Application source: [`2c2cb54`](https://github.com/Muahid1312/footsallapp/commit/2c2cb546e7a0d1f93cd007f69ad209fe96c18e6b).
- [GitHub Actions run 43621338876](https://github.com/Muahid1312/footsallapp/actions/runs/43621338876).
- [Testing prerelease with all APKs and reports](https://github.com/Muahid1312/footsallapp/releases/tag/debug-2c2cb54).
- Flutter 3.35.7, committed dependency lock, JDK 17, Android target/compile API 36.
- `flutter analyze`: **No issues found**.
- `flutter test --reporter expanded`: **145 tests passed**.
- `flutter build apk --debug --split-per-abi`: **success**, three APKs.
- Local supplementary SQL contracts: **27 passed**.

## Downloads

- [ARM64 — most modern Android phones](https://github.com/Muahid1312/footsallapp/releases/download/debug-2c2cb54/app-arm64-v8a-debug.apk).
- [32-bit ARM](https://github.com/Muahid1312/footsallapp/releases/download/debug-2c2cb54/app-armeabi-v7a-debug.apk).
- [x86_64 — matching devices/emulators](https://github.com/Muahid1312/footsallapp/releases/download/debug-2c2cb54/app-x86_64-debug.apk).

The ARM64 file was downloaded into the cloud workspace at
`build/deliverables/saturday-futsal-arm64-debug.apk` (ignored, not committed).
It is 78,741,344 bytes; SHA-256:

```text
627bec5df9b4b5a52639c3dc8b9fc3d8f01a5a920bf57bd8aedb6c6cf80ec129
```

Android `apksigner verify --verbose --print-certs` verifies its v2 signature with
certificate subject `C=US, O=Android, CN=Android Debug`. Android `aapt dump badging`
confirms package `com.saturdayfutsal.app`, label **Saturday Futsal**, version name
`1.0.0`, ARM64 native code, minimum API **24 / Android 7**, and target API 36.
Split APK version codes include Flutter's architecture offset; ARM64 is 2001.

These are debuggable personal-testing builds. Physical device acceptance,
camera/gallery/document-provider/sharing behavior, and Android process/lifecycle
smoke tests remain unverified. Production signing credentials are absent; the
production release verdict remains **NO-GO**. Debug builds use development signing
and Internet permission for Flutter's development services. Ordinary app features
remain offline; no user profiles/photos/database are bundled in these APKs.

Download the matching APK to a phone and open it through Android's installer,
allowing installation from the chosen source when prompted. Alternatively use
`adb install -r <downloaded-apk>`. Updates require the same signing key; hosted
development builds may use a different debug key. Preserve/export data before
changing signing rather than erasing it to bypass an installation mismatch.

The cloud's local Flutter SDK bootstrap and ADB-home restrictions are unchanged;
the actual Flutter checks and builds above ran on GitHub's runner. The exact run's
`status.md`, `analyze.log`, `tests.log`, and `build.log` are attached to the prerelease.
