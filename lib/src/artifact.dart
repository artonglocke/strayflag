import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// Thrown when an artifact cannot be opened or read.
class ArtifactException implements Exception {
  ArtifactException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One file inside an artifact (zip member or file on disk).
abstract class ArtifactEntry {
  /// Path relative to the artifact root, always using `/` separators.
  String get path;

  /// Uncompressed size in bytes (may be 0 if unknown).
  int get size;

  /// Reads the full contents. Callers should avoid holding on to many of these.
  Uint8List read();

  /// Reads up to [n] leading bytes (for magic-number sniffing).
  Uint8List head(int n);
}

class _ZipEntry extends ArtifactEntry {
  _ZipEntry(this._file);
  final ArchiveFile _file;
  @override
  String get path => _file.name;
  @override
  int get size => _file.size;
  @override
  Uint8List read() {
    final bytes = _file.readBytes();
    if (bytes == null) {
      throw ArtifactException('Could not decompress $path');
    }
    return bytes;
  }

  @override
  Uint8List head(int n) {
    final b = read();
    return b.length <= n ? b : Uint8List.sublistView(b, 0, n);
  }
}

class _DiskEntry extends ArtifactEntry {
  _DiskEntry(this.path, this._file);
  @override
  final String path;
  final File _file;
  @override
  int get size => _file.lengthSync();
  @override
  Uint8List read() => _file.readAsBytesSync();
  @override
  Uint8List head(int n) {
    final raf = _file.openSync();
    try {
      return raf.readSync(n);
    } finally {
      raf.closeSync();
    }
  }
}

/// The kind of artifact, mostly derived from the extension.
enum ArtifactKind { ipa, xcarchive, app, apk, aab, zip, directory, file }

/// A built artifact opened for reading.
class Artifact {
  Artifact._(this.source, this.kind, this.entries, [this._stream]);

  final String source;
  final ArtifactKind kind;
  final List<ArtifactEntry> entries;
  final InputFileStream? _stream;

  ArtifactEntry? find(String path) {
    for (final e in entries) {
      if (e.path == path) return e;
    }
    return null;
  }

  void close() => _stream?.closeSync();

  /// Opens an `.ipa`, `.apk`, `.aab`, `.xcarchive`, `.app`, any zip, any
  /// directory, or a single raw binary file.
  static Artifact open(String path) {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) {
      throw ArtifactException('No such file or directory: $path');
    }
    if (type == FileSystemEntityType.directory) {
      final ext = p.extension(path).toLowerCase();
      final kind = switch (ext) {
        '.xcarchive' => ArtifactKind.xcarchive,
        '.app' => ArtifactKind.app,
        _ => ArtifactKind.directory,
      };
      final root = Directory(path);
      // For a bare .app directory, keep the bundle name as the path prefix so
      // the same detection rules apply as for .ipa / .xcarchive.
      final base = kind == ArtifactKind.app ? p.dirname(root.absolute.path) : root.absolute.path;
      final entries = <ArtifactEntry>[];
      for (final f in root.listSync(recursive: true, followLinks: false)) {
        if (f is File) {
          final rel = p.relative(f.absolute.path, from: base).replaceAll(r'\', '/');
          entries.add(_DiskEntry(rel, f));
        }
      }
      entries.sort((a, b) => a.path.compareTo(b.path));
      return Artifact._(path, kind, entries);
    }

    final file = File(path);
    final magic = _readMagic(file);
    final isZip = magic.length >= 4 && magic[0] == 0x50 && magic[1] == 0x4B && magic[2] == 0x03 && magic[3] == 0x04;
    if (isZip) {
      final ext = p.extension(path).toLowerCase();
      final kind = switch (ext) {
        '.ipa' => ArtifactKind.ipa,
        '.apk' => ArtifactKind.apk,
        '.aab' => ArtifactKind.aab,
        _ => ArtifactKind.zip,
      };
      final stream = InputFileStream(path);
      try {
        final archive = ZipDecoder().decodeStream(stream);
        final entries = <ArtifactEntry>[
          for (final f in archive.files)
            if (f.isFile) _ZipEntry(f),
        ];
        return Artifact._(path, kind, entries, stream);
      } catch (e) {
        stream.closeSync();
        throw ArtifactException('Could not read $path as a zip archive: $e');
      }
    }
    return Artifact._(path, ArtifactKind.file, [_DiskEntry(p.basename(path), file)]);
  }

  static Uint8List _readMagic(File f) {
    final raf = f.openSync();
    try {
      return raf.readSync(4);
    } finally {
      raf.closeSync();
    }
  }
}
