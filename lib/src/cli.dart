import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

import 'artifact.dart';
import 'config.dart';
import 'report.dart';
import 'rules.dart';
import 'scanner.dart';

const exitClean = 0;
const exitFindings = 1;
const exitError = 2;

const _usage = '''
strayflag — find leftover debug, mock and unlock switches in release builds.

Usage:
  strayflag scan <artifact> [options]   Scan an .ipa, .xcarchive, .app, .apk, .aab or binary
  strayflag notes [--config FILE]       Print the Notes for Review section from your config
  strayflag init                        Write a commented .strayflag.yaml
  strayflag rules                       List built-in denylist terms

Exit codes: 0 clean, 1 findings (or missing expected strings), 2 error.
''';

ArgParser _scanParser() => ArgParser()
  ..addOption('config', abbr: 'c', help: 'Config file (default: ./.strayflag.yaml if present)')
  ..addFlag('json', negatable: false, help: 'Print the JSON report to stdout instead of text')
  ..addOption('json-out', help: 'Also write the JSON report to this file')
  ..addOption('markdown-out', help: 'Append a markdown summary to this file (e.g. \$GITHUB_STEP_SUMMARY)')
  ..addOption('notes-out', help: 'Write the Notes for Review markdown to this file')
  ..addOption('baseline', abbr: 'b', help: 'Previous JSON report or previous build; only report NEW strings')
  ..addOption('fail-on',
      allowed: ['low', 'medium', 'high', 'never'], help: 'Lowest severity that fails the scan (default: medium)')
  ..addOption('min-severity', allowed: ['low', 'medium', 'high'], help: 'Lowest severity shown (default: medium)')
  ..addFlag('deep', negatable: false, help: 'Also scan every native library, extension and DEX file')
  ..addFlag('color', defaultsTo: null, help: 'Force colour on/off (default: auto)')
  ..addFlag('help', abbr: 'h', negatable: false);

Future<int> run(List<String> args, {IOSink? out, IOSink? err}) async {
  final o = out ?? stdout;
  final e = err ?? stderr;
  try {
    if (args.isEmpty || args.first == '-h' || args.first == '--help' || args.first == 'help') {
      o.write(_usage);
      o.writeln('\nscan options:\n${_scanParser().usage}');
      return args.isEmpty ? exitError : exitClean;
    }
    if (args.first == '--version' || args.first == 'version') {
      o.writeln('strayflag $toolVersion');
      return exitClean;
    }
    final cmd = args.first;
    final rest = args.sublist(1);
    switch (cmd) {
      case 'scan':
        return _scan(rest, o, e);
      case 'notes':
        final p = ArgParser()..addOption('config', abbr: 'c');
        final r = p.parse(rest);
        final config = Config.load(r['config'] as String?);
        o.write(notesForReview(config));
        return exitClean;
      case 'init':
        final f = File('.strayflag.yaml');
        if (f.existsSync()) {
          e.writeln('.strayflag.yaml already exists; not overwriting.');
          return exitError;
        }
        f.writeAsStringSync(sampleConfig);
        o.writeln('Wrote .strayflag.yaml');
        return exitClean;
      case 'rules':
        for (final s in Severity.values.reversed) {
          o.writeln('${s.name.toUpperCase()}:');
          o.writeln(
              '  ${builtInRules.where((r) => r.severity == s).map((r) => r.pattern == null ? r.term : '${r.term} /${r.pattern!.pattern}/').join(', ')}');
        }
        return exitClean;
      default:
        // Allow `strayflag <artifact>` as a shortcut for `scan`.
        if (!cmd.startsWith('-') && FileSystemEntity.typeSync(cmd) != FileSystemEntityType.notFound) {
          return _scan(args, o, e);
        }
        e.writeln('Unknown command "$cmd".\n');
        e.write(_usage);
        return exitError;
    }
  } on FormatException catch (x) {
    e.writeln('strayflag: ${x.message}');
    return exitError;
  } on ArtifactException catch (x) {
    e.writeln('strayflag: $x');
    return exitError;
  } on FileSystemException catch (x) {
    e.writeln('strayflag: ${x.message}: ${x.path}');
    return exitError;
  }
}

int _scan(List<String> args, IOSink o, IOSink e) {
  final r = _scanParser().parse(args);
  if (r['help'] == true) {
    o.writeln('Usage: strayflag scan <artifact> [options]\n${_scanParser().usage}');
    return exitClean;
  }
  if (r.rest.length != 1) {
    e.writeln('strayflag scan: expected exactly one artifact path, got ${r.rest.length}.');
    return exitError;
  }
  final config = Config.load(r['config'] as String?);
  final failOnArg = r['fail-on'] as String?;
  final failOn = failOnArg == 'never'
      ? null
      : failOnArg != null
          ? Severity.parse(failOnArg)
          : (config.failOn ?? Severity.medium);
  final minSev =
      r['min-severity'] != null ? Severity.parse(r['min-severity'] as String) : (config.minSeverity ?? Severity.medium);
  final opts = ReportOptions(
    minSeverity: minSev,
    failOn: failOn,
    failOnMissingExpected: config.failOnMissingExpected,
    color: (r['color'] as bool?) ??
        (stdout.hasTerminal && stdout.supportsAnsiEscapes && Platform.environment['NO_COLOR'] == null),
  );
  final scanner = Scanner(config);
  final deep = r['deep'] == true;

  Set<String>? baseline;
  final bPath = r['baseline'] as String?;
  if (bPath != null) baseline = _loadBaseline(bPath, scanner, deep);

  final result = scanner.scanPath(r.rest.single, deep: deep, baseline: baseline);

  if (r['json'] == true) {
    o.writeln(jsonText(result, opts));
  } else {
    o.write(textReport(result, opts));
  }
  if (r['json-out'] != null) writeFile(r['json-out'] as String, jsonText(result, opts));
  if (r['markdown-out'] != null) writeFile(r['markdown-out'] as String, markdownSummary(result, opts), append: true);
  if (r['notes-out'] != null) writeFile(r['notes-out'] as String, notesForReview(config, result: result));
  return failed(result, opts) ? exitFindings : exitClean;
}

Set<String> _loadBaseline(String path, Scanner scanner, bool deep) {
  final f = File(path);
  if (f.existsSync() && path.toLowerCase().endsWith('.json')) {
    final Object? data;
    try {
      data = jsonDecode(f.readAsStringSync());
    } on FormatException catch (x) {
      throw FormatException('Baseline $path is not valid JSON: ${x.message}');
    }
    if (data is Map && data['baseline'] is List) {
      return {for (final s in data['baseline'] as List) s.toString()};
    }
    if (data is Map && data['findings'] is List) {
      return {for (final x in data['findings'] as List) (x as Map)['string'].toString()};
    }
    throw FormatException('Baseline $path has no "baseline" or "findings" list');
  }
  // Otherwise treat it as a previous build and scan it with the same rules.
  return scanner.scanPath(path, deep: deep).allStrings;
}
