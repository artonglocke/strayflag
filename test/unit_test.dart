import 'dart:convert';
import 'dart:typed_data';

import 'package:strayflag/strayflag.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart' show dartString;
import 'package:yaml/yaml.dart';
import 'dart:io';

void main() {
  group('tokenize', () {
    test('camelCase, PascalCase, snake, kebab, acronyms, digits', () {
      expect(tokenize('enableUnlockedMockPurchases'), ['enable', 'unlocked', 'mock', 'purchases']);
      expect(tokenize('screenshots-mode'), ['screenshots', 'mode']);
      expect(tokenize('IAPBypass_v2'), ['iap', 'bypass', 'v', '2']);
      expect(tokenize('DEV_MENU_ENABLED'), ['dev', 'menu', 'enabled']);
      expect(tokenize('kDebugMenu'), ['k', 'debug', 'menu']);
      expect(tokenize('app.flags.testMode'), ['app', 'flags', 'test', 'mode']);
      expect(tokenize('Testni način: otključaj'), ['testni', 'način', 'otključaj']);
    });
  });

  group('matching', () {
    Rule r(String t) => Rule(t, Severity.medium, 'x');
    test('inflections', () {
      expect(wordMatches('purchases', 'purchase'), isTrue);
      expect(wordMatches('mocked', 'mock'), isTrue);
      expect(wordMatches('purchasing', 'purchase'), isTrue);
      expect(wordMatches('mockingbird', 'mock'), isFalse);
    });
    test('word boundaries keep noise down', () {
      expect(ruleMatches(r('test mode'), tokenize('isTestMode')), isTrue);
      expect(ruleMatches(r('test mode'), tokenize('contestmode')), isFalse);
      expect(ruleMatches(r('cheat'), tokenize('cheatsheet')), isFalse);
      expect(ruleMatches(r('staging'), tokenize('https://staging.api.example.com')), isTrue);
      expect(ruleMatches(r('dev menu'), tokenize('devmenu')), isTrue, reason: 'glued compound');
      expect(ruleMatches(r('dev menu'), tokenize('SHOW_DEVMENU')), isTrue);
      expect(ruleMatches(r('dev menu'), tokenize('device menu')), isFalse);
      expect(ruleMatches(r('unlock all'), tokenize('UnlockAllLevels')), isTrue);
    });
    test('real rejection-case flags hit the built-in denylist', () {
      final s = Scanner(Config());
      expect(s.match('enableUnlockedMockPurchases').first.severity, Severity.high);
      expect(s.match('screenshots-mode').map((x) => x.term), contains('screenshot mode'));
      expect(s.match('slow-entitlement').map((x) => x.term), contains('slow entitlement'));
      expect(s.match('Plan your week'), isEmpty);
    });
    test('non-production URLs, but not GPU staging buffers', () {
      final s = Scanner(Config());
      expect(s.match('https://staging.api.example.com/v1').map((r) => r.term), contains('non-production URL'));
      expect(s.match('https://api-dev.example.com').map((r) => r.term), contains('non-production URL'));
      expect(s.match('https://abc123.ngrok-free.app/hook').map((r) => r.term), contains('ngrok tunnel'));
      expect(s.match('https://api.example.com/v1/devices').where((r) => r.severity != Severity.low), isEmpty);
      expect(s.match('Could not create staging buffer.').where((r) => r.severity != Severity.low), isEmpty);
      expect(s.match('useStagingApi').first.term, 'staging api');
    });
    test('custom non-ASCII deny terms', () {
      final s = Scanner(Config.parse('deny: [otključaj sve]'));
      expect(s.match('Testni način: otključaj sve premium značajke').map((r) => r.term), contains('otključaj sve'));
      expect(s.match('otključajte'), isEmpty);
    });
    test('disable removes a built-in term; deny adds one', () {
      final c = Config.parse('disable: [staging api]\ndeny: [{term: free coins, severity: high}]');
      final s = Scanner(c);
      expect(s.match('useStagingApi').map((r) => r.term), isNot(contains('staging api')));
      expect(Scanner(Config()).match('useStagingApi').map((r) => r.term), contains('staging api'));
      expect(s.match('grantFreeCoins').single.severity, Severity.high);
    });
  });

  group('strings', () {
    test('ascii runs like strings(1)', () {
      final b = Uint8List.fromList([0, 0x41, 0x42, 0x43, 0x44, 0, 0x41, 0x42, 0, 0x78, 0x79, 0x7a, 0x7a, 0x7a]);
      expect(asciiStrings(b).map((e) => '${e.offset}:${e.value}'), ['1:ABCD', '9:xyzzz']);
    });
    test('UTF-8 text stays whole (Croatian letters, em dash)', () {
      final b = Uint8List.fromList([
        0, 1, ...utf8.encode('Testni način: otključaj sve premium značajke'), 0, //
        ...utf8.encode('enableUnlockedMockPurchases'), 0, 0xFF,
        ...utf8.encode('yet — upgrading'), 0, 0xC4, 0x41, 0x42, 0x43, 0x44, // broken UTF-8 lead byte
      ]);
      expect(textStrings(b).map((e) => e.value), [
        'Testni način: otključaj sve premium značajke',
        'enableUnlockedMockPurchases',
        'yet — upgrading',
        'ABCD',
      ]);
    });
    test('random high bytes are not text', () {
      final b = Uint8List.fromList([for (var i = 0; i < 4096; i++) (i * 7919 + 13) % 256]);
      expect(textStrings(b).where((e) => e.value.runes.any((r) => r > 0x7F)), isEmpty);
    });
    test('Dart snapshot string table: one-byte, two-byte, long prefixes', () {
      const strings = [
        'enableUnlockedMockPurchases',
        'Testni način: otključaj sve premium značajke',
        "Billing isn't wired up in this build yet — upgrading simply unlocks Premium for testing.",
        'Müller café', // Latin-1 one-byte string
        'Plan 🍝 tonight',
      ];
      final bytes = Uint8List.fromList([0x00, 0x13, 0x07, for (final s in strings) ...dartString(s), 0x02, 0x00]);
      final covered = Uint8List(bytes.length);
      final got = dartSnapshotStrings(bytes, covered: covered);
      expect(got.map((e) => e.value), strings);
      // No stray length byte glued to the front.
      expect(got.first.offset, 4);
      expect(textStrings(bytes, skip: covered), isEmpty);
    });
    test('DEX string table without the ULEB128 length byte', () {
      final strs = ['Test purchase failure', 'Načín — test', 'ok'];
      final data = <int>[];
      final offs = <int>[];
      const base = 0x70 + 4 * 3;
      for (final s in strs) {
        offs.add(base + data.length);
        final enc = utf8.encode(s);
        data
          ..add(s.length)
          ..addAll(enc)
          ..add(0);
      }
      final b = Uint8List(base + data.length);
      b.setAll(0, [0x64, 0x65, 0x78, 0x0A, 0x30, 0x33, 0x35, 0x00]);
      final bd = ByteData.sublistView(b)
        ..setUint32(0x38, strs.length, Endian.little)
        ..setUint32(0x3C, 0x70, Endian.little);
      for (var i = 0; i < offs.length; i++) {
        bd.setUint32(0x70 + 4 * i, offs[i], Endian.little);
      }
      b.setAll(base, data);
      expect(dexStrings(b)!.map((e) => e.value), ['Test purchase failure', 'Načín — test']);
      expect(dexStrings(Uint8List.fromList([1, 2, 3])), isNull);
    });
    test('utf16le', () {
      final b = Uint8List.fromList([
        for (final c in 'hello-mock'.codeUnits) ...[c, 0],
        0,
        0
      ]);
      expect(utf16leStrings(b).map((e) => e.value), contains('hello-mock'));
    });
  });

  group('il2cpp', () {
    test('parses literal table and identifiers', () {
      final m = readIl2CppMetadata(buildFakeIl2CppMetadata(['abc', 'UnlockAll'], ['Cls', 'DevMenu']));
      expect(m.parsed, isTrue);
      expect(m.version, 29);
      expect(m.literals.map((e) => e.value), ['abc', 'UnlockAll']);
      expect(m.identifiers.map((e) => e.value), ['Cls', 'DevMenu']);
    });
    test('literals stay separate (no gluing of neighbours)', () {
      final m = readIl2CppMetadata(buildFakeIl2CppMetadata(['test', 'mode'], []));
      expect(m.literals.map((e) => e.value), ['test', 'mode']);
    });
    test('unknown layout falls back to generic scan', () {
      final bytes = buildFakeIl2CppMetadata(['secretDevMenu'], ['X']);
      ByteData.sublistView(bytes).setUint32(8, 0x7fffffff, Endian.little); // corrupt
      final m = readIl2CppMetadata(bytes);
      expect(m.parsed, isFalse);
      // Without the table, neighbouring strings can be glued together.
      expect(m.identifiers.map((e) => e.value), anyElement(contains('secretDevMenu')));
    });
  });

  group('config', () {
    const yaml = '''
fail_on: high
allow: ["Debug output", "re:^vm:"]
features:
  - name: Screenshot mode
    flags: [screenshots-mode]
    description: Sample data for store screenshots.
    how_to_enable: Launch with -screenshots-mode (UI tests only).
  - name: Coach marks
    flag: coach-marks
expect: [pro_monthly]
fail_on_missing_expected: true
notes_intro: Demo account in App Review Information.
''';
    test('parses all keys', () {
      final c = Config.parse(yaml);
      expect(c.failOn, Severity.high);
      expect(c.allow.first.matches('Some DEBUG OUTPUT here'), isTrue);
      expect(c.allow.last.matches('vm:testing'), isTrue);
      expect(c.allow.last.matches('x vm:testing'), isFalse);
      expect(c.features.map((f) => f.name), ['Screenshot mode', 'Coach marks']);
      expect(c.features.last.flags, ['coach-marks']);
      expect(c.failOnMissingExpected, isTrue);
    });
    test('notes for review', () {
      final n = notesForReview(Config.parse(yaml));
      expect(n, contains('## Notes for Review'));
      expect(n, contains('Demo account in App Review Information.'));
      expect(n, contains('1. **Screenshot mode**'));
      expect(n, contains('How to enable it: Launch with -screenshots-mode (UI tests only).'));
      expect(n, contains('(describe how a reviewer can reach this feature)'));
    });
    test('empty config notes say nothing is hidden', () {
      expect(notesForReview(Config()), contains('no features that are hidden'));
    });
    test('bad severity is a FormatException', () {
      expect(() => Config.parse('fail_on: urgent'), throwsFormatException);
      expect(() => Config.parse('- just a list'), throwsFormatException);
    });
  });

  test('action.yml is valid and wires every input into the script', () {
    final a = loadYaml(File('action.yml').readAsStringSync()) as YamlMap;
    expect(a['runs']['using'], 'composite');
    final inputs = (a['inputs'] as YamlMap).keys.cast<String>();
    expect(inputs, containsAll(['path', 'config', 'baseline', 'fail-on', 'notes-out']));
    final env = (a['runs']['steps'] as YamlList).last['env'] as YamlMap;
    for (final i in inputs.where((i) => i != 'setup-dart')) {
      expect(env.values.join(' '), contains('inputs.$i'), reason: i);
    }
  });
}
