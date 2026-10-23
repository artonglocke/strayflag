/// Scans built release artifacts for leftover debug, mock and unlock switches.
library;

export 'src/artifact.dart' show Artifact, ArtifactEntry, ArtifactException, ArtifactKind;
export 'src/cli.dart' show run, exitClean, exitError, exitFindings;
export 'src/config.dart';
export 'src/detect.dart';
export 'src/il2cpp.dart' show readIl2CppMetadata, buildFakeIl2CppMetadata, isIl2CppMetadata, Il2CppStrings;
export 'src/report.dart';
export 'src/rules.dart';
export 'src/scanner.dart';
export 'src/strings.dart';
