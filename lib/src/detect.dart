import 'dart:typed_data';

import 'artifact.dart';
import 'il2cpp.dart';

enum Framework { flutter, unity, reactNative, native }

enum TargetPlatform { ios, android, unknown }

/// How a target file is read.
enum TargetKind {
  /// Dart AOT snapshot (`App.framework/App`, `libapp.so`).
  dartAot,

  /// Unity `global-metadata.dat`.
  il2cppMetadata,

  /// Any native binary (Mach-O, ELF, DEX), read like `strings(1)`.
  binary,

  /// React Native JS / Hermes bundle.
  jsBundle,
}

class ScanTarget {
  ScanTarget(this.entry, this.kind, this.reason);
  final ArtifactEntry entry;
  final TargetKind kind;
  final String reason;
  String get path => entry.path;
}

class Detection {
  Detection(this.platform, this.frameworks, this.targets, {this.appRoot});
  final TargetPlatform platform;
  final List<Framework> frameworks;
  final List<ScanTarget> targets;
  final String? appRoot;
}

bool isMachO(Uint8List h) {
  if (h.length < 4) return false;
  final m = ByteData.sublistView(h).getUint32(0, Endian.big);
  return const {0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE, 0xCAFEBABE, 0xCAFEBABF}.contains(m);
}

bool isElf(Uint8List h) => h.length >= 4 && h[0] == 0x7F && h[1] == 0x45 && h[2] == 0x4C && h[3] == 0x46;

bool isDex(Uint8List h) => h.length >= 4 && h[0] == 0x64 && h[1] == 0x65 && h[2] == 0x78 && h[3] == 0x0A;

const _abiPreference = ['arm64-v8a', 'armeabi-v7a', 'x86_64', 'x86'];

/// Works out the platform and framework of [a] and which files to scan.
///
/// With [deep], every native binary in the bundle is scanned as well
/// (plugins, app extensions, all `.so` files of the chosen ABI, all DEX).
Detection detect(Artifact a, {bool deep = false}) {
  // iOS: find the outermost *.app/ directory.
  String? appRoot;
  for (final e in a.entries) {
    final m = RegExp(r'^(.*?[^/]+\.app)/').firstMatch(e.path);
    if (m != null && (appRoot == null || m[1]!.length < appRoot.length)) appRoot = m[1];
  }
  if (appRoot != null) return _detectIos(a, appRoot, deep);

  final isAndroid = a.entries.any((e) =>
      e.path == 'AndroidManifest.xml' || e.path == 'base/manifest/AndroidManifest.xml' || e.path.endsWith('.dex'));
  if (isAndroid) return _detectAndroid(a, deep);

  // A raw file or unknown directory: classify each file by its magic number.
  final targets = <ScanTarget>[];
  final frameworks = <Framework>{};
  for (final e in a.entries) {
    final h = e.head(8);
    final name = e.path.split('/').last;
    if (isIl2CppMetadata(h)) {
      targets.add(ScanTarget(e, TargetKind.il2cppMetadata, 'IL2CPP metadata'));
      frameworks.add(Framework.unity);
    } else if (name == 'libapp.so' || (name == 'App' && isMachO(h))) {
      targets.add(ScanTarget(e, TargetKind.dartAot, 'Dart AOT snapshot'));
      frameworks.add(Framework.flutter);
    } else if (isMachO(h) || isElf(h) || isDex(h) || a.kind == ArtifactKind.file) {
      targets.add(ScanTarget(e, TargetKind.binary, 'binary'));
    }
  }
  if (frameworks.isEmpty) frameworks.add(Framework.native);
  return Detection(TargetPlatform.unknown, frameworks.toList(), targets);
}

Detection _detectIos(Artifact a, String root, bool deep) {
  final targets = <ScanTarget>[];
  final frameworks = <Framework>[];
  final seen = <String>{};
  void add(ArtifactEntry? e, TargetKind k, String why) {
    if (e != null && seen.add(e.path)) targets.add(ScanTarget(e, k, why));
  }

  final dart = a.find('$root/Frameworks/App.framework/App');
  if (dart != null) {
    frameworks.add(Framework.flutter);
    add(dart, TargetKind.dartAot, 'Flutter app code (Dart AOT snapshot)');
  }
  final meta = a.find('$root/Data/Managed/Metadata/global-metadata.dat');
  if (meta != null) {
    frameworks.add(Framework.unity);
    add(meta, TargetKind.il2cppMetadata, 'Unity IL2CPP string literals and names');
    add(a.find('$root/Frameworks/UnityFramework.framework/UnityFramework'), TargetKind.binary,
        'Unity IL2CPP native code');
  }
  final js = a.find('$root/main.jsbundle');
  if (js != null) {
    frameworks.add(Framework.reactNative);
    add(js, TargetKind.jsBundle, 'React Native bundle');
  }
  if (frameworks.isEmpty) frameworks.add(Framework.native);

  // Main executable: largest Mach-O directly inside the .app root.
  ArtifactEntry? main;
  for (final e in a.entries) {
    if (!e.path.startsWith('$root/')) continue;
    final rest = e.path.substring(root.length + 1);
    if (rest.contains('/') || rest.contains('.')) continue; // executables have no extension
    if (!isMachO(e.head(4))) continue;
    if (main == null || e.size > main.size) main = e;
  }
  add(main, TargetKind.binary, 'main executable');

  if (deep) {
    for (final e in a.entries) {
      if (!e.path.startsWith('$root/') || seen.contains(e.path)) continue;
      if (e.path.contains('.dSYM/')) continue;
      final name = e.path.split('/').last;
      if (name.contains('.') && !name.endsWith('.dylib')) continue;
      final h = e.head(8);
      if (isMachO(h)) add(e, TargetKind.binary, 'native binary (--deep)');
    }
  }
  return Detection(TargetPlatform.ios, frameworks, targets, appRoot: root);
}

Detection _detectAndroid(Artifact a, bool deep) {
  final prefix = a.entries.any((e) => e.path.startsWith('base/')) ? 'base/' : '';
  // Pick one ABI so arm64/arm32/x86 copies are not reported three times.
  String? abi;
  for (final want in _abiPreference) {
    if (a.entries.any((e) => e.path.startsWith('${prefix}lib/$want/'))) {
      abi = want;
      break;
    }
  }
  final targets = <ScanTarget>[];
  final frameworks = <Framework>[];
  final seen = <String>{};
  void add(ArtifactEntry? e, TargetKind k, String why) {
    if (e != null && seen.add(e.path)) targets.add(ScanTarget(e, k, why));
  }

  if (abi != null) {
    final dart = a.find('${prefix}lib/$abi/libapp.so');
    if (dart != null) {
      frameworks.add(Framework.flutter);
      add(dart, TargetKind.dartAot, 'Flutter app code (Dart AOT snapshot, $abi)');
    }
  }
  final meta = a.find('${prefix}assets/bin/Data/Managed/Metadata/global-metadata.dat');
  if (meta != null) {
    frameworks.add(Framework.unity);
    add(meta, TargetKind.il2cppMetadata, 'Unity IL2CPP string literals and names');
    if (abi != null) {
      add(a.find('${prefix}lib/$abi/libil2cpp.so'), TargetKind.binary, 'Unity IL2CPP native code ($abi)');
    }
  }
  final js = a.find('${prefix}assets/index.android.bundle');
  if (js != null) {
    frameworks.add(Framework.reactNative);
    add(js, TargetKind.jsBundle, 'React Native bundle');
  }
  final nativeOnly = frameworks.isEmpty;
  if (nativeOnly) frameworks.add(Framework.native);

  for (final e in a.entries) {
    final name = e.path.split('/').last;
    final isDexFile = RegExp(r'^classes\d*\.dex$').hasMatch(name);
    final isSo = abi != null && e.path.startsWith('${prefix}lib/$abi/') && name.endsWith('.so');
    // Java/Kotlin code is always worth a look for native apps; for Flutter and
    // Unity it is mostly library code, so only with --deep.
    if (isDexFile && (nativeOnly || deep)) add(e, TargetKind.binary, 'Java/Kotlin code (DEX)');
    if (isSo && deep) add(e, TargetKind.binary, 'native library (--deep)');
  }
  return Detection(TargetPlatform.android, frameworks, targets);
}
