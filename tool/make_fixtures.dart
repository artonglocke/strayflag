// Writes demo artifacts to example/fixtures/ (synthetic, no real app code).
// Usage: dart run tool/make_fixtures.dart
import 'dart:io';

import '../test/support/fixtures.dart';

void main() {
  const out = 'example/fixtures';
  Directory(out).createSync(recursive: true);
  flutterIpa('$out/flutter_flags.ipa', [...normalAppStrings, ...plantedFlags, 'Internal dev menu']);
  flutterIpa('$out/flutter_clean.ipa', normalAppStrings);
  unityIpa('$out/unity_cheats.ipa');
  flutterApk('$out/flutter_flags.aab', [...normalAppStrings, ...plantedFlags], aab: true);
  stdout.writeln('Wrote fixtures to $out/');
}
