import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:strayflag/strayflag.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

class _Capture implements StreamConsumer<List<int>> {
  final bytes = <int>[];
  @override
  Future<void> addStream(Stream<List<int>> s) => s.forEach(bytes.addAll);
  @override
  Future<void> close() async {}
}

class Run {
  Run(this.code, this.out, this.err);
  final int code;
  final String out;
  final String err;
  @override
  String toString() => 'exit $code\n$out\n$err';
}

Future<Run> cli(List<String> args) async {
  final o = _Capture(), e = _Capture();
  final os = IOSink(o), es = IOSink(e);
  final code = await run([...args, if (args.isNotEmpty && args.first == 'scan') '--no-color'], out: os, err: es);
  await os.close();
  await es.close();
  return Run(code, utf8.decode(o.bytes), utf8.decode(e.bytes));
}

void main() {
  late Directory tmp;
  String t(String name) => p.join(tmp.path, name);

  setUp(() => tmp = Directory.systemTemp.createTempSync('strayflag_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('Flutter .ipa with the rejection-case flags fails with exit 1', () async {
    flutterIpa(t('app.ipa'), [...normalAppStrings, ...plantedFlags]);
    final r = await cli(['scan', t('app.ipa')]);
    expect(r.code, exitFindings, reason: '$r');
    expect(r.out, contains('Framework: Flutter'));
    expect(r.out, contains('Payload/Runner.app/Frameworks/App.framework/App'));
    for (final f in plantedFlags) {
      expect(r.out, contains('"$f"'));
    }
    expect(r.out, contains('HIGH    "enableUnlockedMockPurchases"'));
    expect(r.out, isNot(contains('dev.flutter/channel-buffers')), reason: 'framework noise is low severity');
    expect(r.out, isNot(contains('Debug mode only')), reason: 'Flutter engine is not scanned');
    expect(r.out, contains('✗ FAIL'));
  });

  test('non-ASCII strings come out whole (Croatian, em dash) in Dart, native and Unity code', () async {
    flutterIpa(t('hr.ipa'), [...normalAppStrings, croatianFlag, 'enableUnlockedMockPurchases', emDashStub],
        runnerStrings: ['Način rada — DEBUG_MENU_OTKLJUČAN']);
    final r = await cli(['scan', t('hr.ipa'), '--json', '--min-severity', 'low']);
    expect(r.code, exitFindings, reason: '$r');
    final found = {for (final f in (jsonDecode(r.out) as Map)['findings'] as List) f['string']: f};
    expect(found[emDashStub]?['severity'], 'high', reason: '${found.keys}');
    expect(found[emDashStub]?['source'], 'dart');
    expect(found['enableUnlockedMockPurchases']?['severity'], 'high');
    expect(found[croatianFlag]?['severity'], 'low', reason: 'matched on "premium", kept whole');
    expect(found['Način rada — DEBUG_MENU_OTKLJUČAN']?['severity'], 'medium');
    expect(found.keys.where((k) => k.contains('način') && k != croatianFlag), isEmpty);

    unityIpa(t('u.ipa'), literals: ['Otključaj sve razine — unlockAll'], identifiers: ['GameManager']);
    final u = await cli(['scan', t('u.ipa'), '--json']);
    expect([for (final f in (jsonDecode(u.out) as Map)['findings'] as List) f['string']],
        ['Otključaj sve razine — unlockAll']);
  });

  test('clean Flutter .ipa passes with exit 0', () async {
    flutterIpa(t('clean.ipa'), normalAppStrings);
    final r = await cli(['scan', t('clean.ipa')]);
    expect(r.code, exitClean, reason: '$r');
    expect(r.out, contains('✓ PASS'));
  });

  test('flag strings in the native Runner binary are found too', () async {
    flutterIpa(t('a.ipa'), normalAppStrings, runnerStrings: ['FLEXDebugMenuManager']);
    final r = await cli(['scan', t('a.ipa')]);
    expect(r.code, exitFindings);
    expect(r.out, contains('FLEXDebugMenuManager'));
  });

  test('Unity IL2CPP .ipa: literals and identifiers from global-metadata.dat', () async {
    unityIpa(t('game.ipa'));
    final r = await cli(['scan', t('game.ipa'), '--json']);
    expect(r.code, exitFindings, reason: '$r');
    final j = jsonDecode(r.out) as Map;
    expect(j['frameworks'], ['unity']);
    final found = {for (final f in j['findings'] as List) f['string']: f};
    expect(found.keys, containsAll(['CheatMenuController', 'UnlockAllLevels', 'ENABLE_CHEATS']));
    expect(found['CheatMenuController']['source'], 'identifier');
    expect(found['ENABLE_CHEATS']['source'], 'literal');
    expect(found['UnlockAllLevels']['severity'], 'high');
    expect(found.keys, isNot(contains('get_isDebugBuild')), reason: 'low severity hidden by default');
    expect((j['targets'] as List).first['note'], contains('metadata v29'));
  });

  test('Flutter .apk and .aab scan one ABI only', () async {
    for (final aab in [false, true]) {
      final path = t(aab ? 'x.aab' : 'x.apk');
      flutterApk(path, [...normalAppStrings, 'showDevMenu'], aab: aab);
      final r = await cli(['scan', path, '--json']);
      expect(r.code, exitFindings, reason: '$r');
      final j = jsonDecode(r.out) as Map;
      expect(j['platform'], 'android');
      expect((j['targets'] as List).map((x) => x['path']),
          [aab ? 'base/lib/arm64-v8a/libapp.so' : 'lib/arm64-v8a/libapp.so']);
      expect((j['findings'] as List).single['count'], 1);
    }
  });

  test('React Native bundle', () async {
    reactNativeApk(t('rn.apk'), ['__DEV_SETTINGS__', 'bypassPaywall']);
    final r = await cli(['scan', t('rn.apk')]);
    expect(r.code, exitFindings, reason: '$r');
    expect(r.out, contains('React Native'));
    expect(r.out, contains('bypassPaywall'));
  });

  test('.xcarchive directory, dSYMs ignored', () async {
    flutterXcarchive(t('Runner.xcarchive'), ['QA_PANEL_ENABLED']);
    final r = await cli(['scan', t('Runner.xcarchive')]);
    expect(r.code, exitFindings, reason: '$r');
    expect(r.out, contains('QA_PANEL_ENABLED'));
    expect(r.out, isNot(contains('mockPurchaseDebugSymbol')));
  });

  test('config: allowlist, declared features, notes, expect', () async {
    flutterIpa(t('app.ipa'), [...normalAppStrings, ...plantedFlags]);
    File(t('c.yaml')).writeAsStringSync('''
allow: [slow-entitlement]
features:
  - name: Screenshot mode
    flags: [screenshots-mode]
    description: Fills the app with sample recipes for App Store screenshots.
    how_to_enable: Not user-reachable; only our UI test runner sets it.
  - name: Mock purchases
    flags: [UnlockedMockPurchases]
    description: Simulated purchases for automated tests.
    how_to_enable: Disabled in release; never enabled for users.
  - name: Legacy beta
    flags: [legacy-beta]
    how_to_enable: n/a
expect: [com.amaranth.tablefull.pro_monthly, com.amaranth.tablefull.pro_yearly]
''');
    final r =
        await cli(['scan', t('app.ipa'), '-c', t('c.yaml'), '--notes-out', t('notes.md'), '--json-out', t('r.json')]);
    expect(r.code, exitClean, reason: 'everything declared or allowed\n$r');
    expect(r.out, contains('✓ Screenshot mode: "screenshots-mode"'));
    expect(r.out, contains('(1 allowlisted)'));
    expect(r.out, contains('- com.amaranth.tablefull.pro_yearly'));
    expect(r.out, contains('- Legacy beta'));
    final notes = File(t('notes.md')).readAsStringSync();
    expect(notes, contains('**Screenshot mode**'));
    expect(notes, contains('Status: not active in this build.'));
    final j = jsonDecode(File(t('r.json')).readAsStringSync()) as Map;
    expect(j['missing_expected'], ['com.amaranth.tablefull.pro_yearly']);
    expect((j['declared'] as List).length, 2);

    File(t('c2.yaml')).writeAsStringSync(
        'expect: [com.amaranth.tablefull.pro_yearly]\nfail_on_missing_expected: true\nfail_on: high\n');
    flutterIpa(t('clean.ipa'), normalAppStrings);
    final r2 = await cli(['scan', t('clean.ipa'), '-c', t('c2.yaml')]);
    expect(r2.code, exitFindings, reason: '$r2');
  });

  test('baseline diff: JSON report and previous build', () async {
    flutterIpa(t('v1.ipa'), [...normalAppStrings, 'slow-entitlement']);
    flutterIpa(t('v2.ipa'), [...normalAppStrings, 'slow-entitlement', 'forcePremiumOverride']);
    await cli(['scan', t('v1.ipa'), '--json-out', t('base.json')]);
    for (final base in [t('base.json'), t('v1.ipa')]) {
      final r = await cli(['scan', t('v2.ipa'), '--baseline', base, '--json']);
      expect(r.code, exitFindings, reason: '$r');
      final j = jsonDecode(r.out) as Map;
      expect([for (final f in j['findings'] as List) f['string']], ['forcePremiumOverride']);
      expect(j['baseline_suppressed'], 1);
    }
    final same = await cli(['scan', t('v1.ipa'), '--baseline', t('base.json')]);
    expect(same.code, exitClean, reason: '$same');
  });

  test('--fail-on and --min-severity', () async {
    flutterIpa(t('a.ipa'), [...normalAppStrings, 'slow-entitlement']);
    expect((await cli(['scan', t('a.ipa'), '--fail-on', 'high'])).code, exitClean);
    expect((await cli(['scan', t('a.ipa'), '--fail-on', 'never'])).code, exitClean);
    flutterIpa(t('b.ipa'), normalAppStrings);
    final low = await cli(['scan', t('b.ipa'), '--min-severity', 'low', '--fail-on', 'low']);
    expect(low.code, exitFindings);
    expect(low.out, contains('LOW'));
  });

  test('--markdown-out appends a job summary', () async {
    flutterIpa(t('a.ipa'), [...normalAppStrings, ...plantedFlags]);
    File(t('summary.md')).writeAsStringSync('# Earlier step\n');
    await cli(['scan', t('a.ipa'), '--markdown-out', t('summary.md')]);
    final md = File(t('summary.md')).readAsStringSync();
    expect(md, startsWith('# Earlier step'));
    expect(md, contains('### ❌ strayflag: 3 suspicious strings'));
    expect(md, contains('| high | `enableUnlockedMockPurchases` |'));
  });

  test('--deep scans extra native binaries', () async {
    flutterIpa(t('a.ipa'), normalAppStrings);
    final r = await cli(['scan', t('a.ipa'), '--deep', '--json']);
    final paths = [for (final x in (jsonDecode(r.out) as Map)['targets'] as List) x['path']];
    expect(paths, contains('Payload/Runner.app/Frameworks/Flutter.framework/Flutter'));
  });

  test('raw binary file and raw global-metadata.dat', () async {
    File(t('libapp.so')).writeAsBytesSync(fakeDartAotElf(['isTestMode']));
    final r = await cli(['scan', t('libapp.so')]);
    expect(r.code, exitFindings, reason: '$r');
    expect(r.out, contains('isTestMode'));
    File(t('global-metadata.dat')).writeAsBytesSync(buildFakeIl2CppMetadata(['x'], ['GodModeToggle']));
    final m = await cli(['scan', t('global-metadata.dat')]);
    expect(m.out, contains('Unity'));
    expect(m.out, contains('GodModeToggle'));
  });

  test('errors exit 2', () async {
    expect((await cli(['scan', t('missing.ipa')])).code, exitError);
    expect((await cli(['scan'])).code, exitError);
    expect((await cli(['frobnicate'])).code, exitError);
    flutterIpa(t('a.ipa'), normalAppStrings);
    File(t('bad.yaml')).writeAsStringSync('fail_on: sometimes');
    final r = await cli(['scan', t('a.ipa'), '-c', t('bad.yaml')]);
    expect(r.code, exitError);
    expect(r.err, contains('Unknown severity'));
    File(t('empty.zip')).writeAsBytesSync([0x50, 0x4B, 0x03, 0x04, 0, 0]);
    expect((await cli(['scan', t('empty.zip')])).code, exitError);
  });

  test('notes and rules subcommands', () async {
    File(t('c.yaml'))
        .writeAsStringSync('features: [{name: Dev menu, flags: [devMenu], how_to_enable: Tap version 7 times}]');
    final n = await cli(['notes', '-c', t('c.yaml')]);
    expect(n.code, exitClean);
    expect(n.out, contains('How to enable it: Tap version 7 times'));
    final rules = await cli(['rules']);
    expect(rules.out, contains('mock purchase'));
  });

  // Strongest check: a real `flutter build apk --release --obfuscate` output.
  // Built by tool/build_real_flutter_fixture.sh; skipped if not present.
  final realApk = Platform.environment['STRAYFLAG_REAL_APK'] ??
      '/home/box/flutterfixture/planted_app/build/app/outputs/flutter-apk/app-release.apk';
  test('real obfuscated Flutter release APK', () async {
    final r = await cli(['scan', realApk, '--json']);
    final j = jsonDecode(r.out) as Map;
    final found = [for (final f in j['findings'] as List) f['string']];
    expect(found, containsAll([...plantedFlags, 'Internal dev menu: unlock all premium']));
    expect(found.length, 4, reason: 'no framework noise at default severity: $found');
    expect({for (final f in j['findings'] as List) f['source']}, {'dart'});
    expect(r.code, exitFindings);
  }, skip: File(realApk).existsSync() ? false : 'real APK not built (see tool/build_real_flutter_fixture.sh)');
}
