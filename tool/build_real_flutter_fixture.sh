#!/usr/bin/env bash
# Builds a real, obfuscated Flutter Android release with planted test switches
# and scans it. Needs Flutter + Android SDK on PATH. Takes ~3 minutes.
set -euo pipefail
dir="${1:-/tmp/strayflag-real}"
rm -rf "$dir" && mkdir -p "$dir" && cd "$dir"
flutter create --platforms=android --project-name planted_app planted_app >/dev/null
cd planted_app
cat > lib/main.dart <<'DART'
import 'package:flutter/material.dart';

const bool kScreenshotsMode = bool.fromEnvironment('screenshots-mode');
final Map<String, bool> remoteFlags = {
  'screenshots-mode': false,
  'slow-entitlement': false,
  'enableUnlockedMockPurchases': false,
};

class DevMenu extends StatelessWidget {
  const DevMenu({super.key});
  @override
  Widget build(BuildContext context) => const Text('Internal dev menu: unlock all premium');
}

void main() {
  final mock = remoteFlags['enableUnlockedMockPurchases'] ?? false;
  runApp(MaterialApp(
    home: Scaffold(
      body: Center(
        child: mock ? const DevMenu() : Text('Hello ${remoteFlags.keys.join(",")} $kScreenshotsMode'),
      ),
    ),
  ));
}
DART
flutter build apk --release --obfuscate --split-debug-info=build/symbols --target-platform android-arm64
echo "APK: $PWD/build/app/outputs/flutter-apk/app-release.apk"
echo "Run: STRAYFLAG_REAL_APK=$PWD/build/app/outputs/flutter-apk/app-release.apk dart test"
