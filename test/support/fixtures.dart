// Builds synthetic release artifacts with the real directory layouts of
// Flutter / Unity / React Native / native iOS and Android builds.
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:strayflag/strayflag.dart';

final _machO64 = [0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01]; // MH_MAGIC_64 LE, arm64
final _elf = [0x7F, 0x45, 0x4C, 0x46, 0x02, 0x01, 0x01, 0x00];

/// A fake binary: header, noise, then each string written the way the Dart
/// AOT snapshot does (length byte with the high bit set, then the bytes).
Uint8List fakeBinary(List<int> magic, List<String> strings, {int seed = 1}) {
  final b = BytesBuilder()..add(magic);
  var x = seed;
  int rnd() => x = (x * 1103515245 + 12345) & 0x7fffffff;
  for (var i = 0; i < 256; i++) {
    b.addByte(rnd() & 0x1F); // non-printable filler
  }
  for (final s in strings) {
    b.addByte(0x80 | (s.length & 0x7F));
    b.add(s.codeUnits);
    b.addByte(0x00);
    for (var i = 0; i < 8; i++) {
      b.addByte(rnd() & 0x0F);
    }
  }
  return b.toBytes();
}

/// Strings that ship in every Flutter release build (from a real build) and
/// must not be reported at the default severity.
const flutterFrameworkNoise = [
  'dev.flutter/channel-buffers',
  'AppLifecycleState.hidden',
  'class _FakeAsync',
  'letterSpacingOverride',
  'vm:testing:print-flow-graph',
  'while dispatching a non-hit-tested pointer event',
  'RfBypass',
  'localhost',
  'production applications or plugins published to pub.dev.',
  'MaterialApp',
  'package:flutter/src/widgets/framework.dart',
];

Uint8List fakeDartAotMachO(List<String> appStrings) =>
    fakeBinary(_machO64, [...flutterFrameworkNoise, ...appStrings], seed: 7);

Uint8List fakeDartAotElf(List<String> appStrings) =>
    fakeBinary(_elf, [...flutterFrameworkNoise, ...appStrings], seed: 9);

void _addFile(Archive a, String path, List<int> bytes) => a.addFile(ArchiveFile(path, bytes.length, bytes));

const _infoPlist = '''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Runner</string></dict></plist>''';

File writeZip(String path, Archive a) {
  final f = File(path)..parent.createSync(recursive: true);
  f.writeAsBytesSync(ZipEncoder().encode(a));
  return f;
}

/// Flutter iOS .ipa with the given app-level strings in App.framework/App.
File flutterIpa(String path, List<String> appStrings, {List<String> runnerStrings = const []}) {
  final a = Archive();
  const root = 'Payload/Runner.app';
  _addFile(a, '$root/Info.plist', _infoPlist.codeUnits);
  _addFile(a, '$root/Runner',
      fakeBinary(_machO64, ['_OBJC_CLASS_\$_FlutterAppDelegate', 'GeneratedPluginRegistrant', ...runnerStrings]));
  _addFile(a, '$root/Frameworks/App.framework/App', fakeDartAotMachO(appStrings));
  _addFile(a, '$root/Frameworks/App.framework/Info.plist', _infoPlist.codeUnits);
  _addFile(a, '$root/Frameworks/Flutter.framework/Flutter',
      fakeBinary(_machO64, ['Debug mode only', 'debug_drawer_overlay_engine'])); // engine: not scanned
  _addFile(a, '$root/Assets.car', List.filled(64, 1));
  return writeZip(path, a);
}

const unityLiterals = [
  'Loading level {0}',
  'com.amaranth.game.coins_100',
  'ENABLE_CHEATS',
  'Give 9999 gems (QA)',
];
const unityIdentifiers = [
  'Assembly-CSharp',
  'UnityEngine.CoreModule',
  'GameManager',
  'CheatMenuController',
  'UnlockAllLevels',
  'MonoBehaviour',
  'get_isDebugBuild',
];

/// Unity IL2CPP iOS .ipa.
File unityIpa(String path, {List<String> literals = unityLiterals, List<String> identifiers = unityIdentifiers}) {
  final a = Archive();
  const root = 'Payload/MyGame.app';
  _addFile(a, '$root/Info.plist', _infoPlist.codeUnits);
  _addFile(a, '$root/MyGame', fakeBinary(_machO64, ['UnityAppController', 'main']));
  _addFile(a, '$root/Frameworks/UnityFramework.framework/UnityFramework',
      fakeBinary(_machO64, ['il2cpp_init', 'UnityFramework', 'il2cpp_string_new']));
  _addFile(a, '$root/Data/Managed/Metadata/global-metadata.dat', buildFakeIl2CppMetadata(literals, identifiers));
  _addFile(a, '$root/Data/data.unity3d', List.filled(128, 0));
  return writeZip(path, a);
}

/// Flutter Android .apk (or .aab when [aab] is true).
File flutterApk(String path, List<String> appStrings, {bool aab = false}) {
  final a = Archive();
  final pre = aab ? 'base/' : '';
  _addFile(a, aab ? 'base/manifest/AndroidManifest.xml' : 'AndroidManifest.xml', [0x03, 0x00, 0x08, 0x00]);
  _addFile(a, aab ? 'base/dex/classes.dex' : 'classes.dex',
      [0x64, 0x65, 0x78, 0x0A, ...'io.flutter.embedding.android.FlutterActivity'.codeUnits]);
  for (final abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']) {
    _addFile(a, '${pre}lib/$abi/libapp.so', fakeDartAotElf(appStrings));
    _addFile(a, '${pre}lib/$abi/libflutter.so', fakeBinary(_elf, ['debug engine string']));
  }
  return writeZip(path, a);
}

/// React Native Android .apk with a JS bundle.
File reactNativeApk(String path, List<String> jsStrings) {
  final a = Archive();
  _addFile(a, 'AndroidManifest.xml', [0x03, 0x00, 0x08, 0x00]);
  _addFile(a, 'classes.dex', [0x64, 0x65, 0x78, 0x0A, ...'com.facebook.react.ReactActivity'.codeUnits]);
  _addFile(a, 'assets/index.android.bundle', '__d(function(){${jsStrings.map((s) => '"$s"').join(';')}});'.codeUnits);
  return writeZip(path, a);
}

/// Flutter .xcarchive directory.
Directory flutterXcarchive(String path, List<String> appStrings) {
  final root = p.join(path, 'Products', 'Applications', 'Runner.app');
  void w(String rel, List<int> bytes) {
    final f = File(p.join(root, rel))..parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes);
  }

  w('Info.plist', _infoPlist.codeUnits);
  w('Runner', fakeBinary(_machO64, ['GeneratedPluginRegistrant']));
  w('Frameworks/App.framework/App', fakeDartAotMachO(appStrings));
  File(p.join(path, 'Info.plist')).writeAsStringSync(_infoPlist);
  final dsym = File(p.join(path, 'dSYMs', 'App.framework.dSYM', 'Contents', 'Resources', 'DWARF', 'App'))
    ..parent.createSync(recursive: true);
  dsym.writeAsBytesSync(fakeBinary(_machO64, ['mockPurchaseDebugSymbol']));
  return Directory(path);
}

/// The strings from the real App Review rejection case.
const plantedFlags = [
  'screenshots-mode',
  'slow-entitlement',
  'enableUnlockedMockPurchases',
];

const normalAppStrings = [
  'com.amaranth.tablefull.pro_monthly',
  'Welcome back!',
  'Plan your week',
  'https://api.example.com/v1/recipes',
];
