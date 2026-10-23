import 'dart:typed_data';

import 'strings.dart';

/// Magic number at the start of Unity IL2CPP `global-metadata.dat`.
const int il2cppMetadataMagic = 0xFAB11BAF;

bool isIl2CppMetadata(Uint8List head) =>
    head.length >= 4 && ByteData.sublistView(head).getUint32(0, Endian.little) == il2cppMetadataMagic;

/// Result of reading a `global-metadata.dat` file.
class Il2CppStrings {
  Il2CppStrings(this.version, this.literals, this.identifiers, {required this.parsed});

  /// Metadata version from the header (e.g. 24, 27, 29, 31).
  final int version;

  /// C# string literals (`"..."` in user code), with clean boundaries.
  final List<ExtractedString> literals;

  /// Type, method, field and namespace names.
  final List<ExtractedString> identifiers;

  /// Whether the literal table was understood. If false, [identifiers] holds
  /// a generic strings scan of the whole file instead.
  final bool parsed;
}

/// Reads string literals and identifier names out of IL2CPP metadata.
///
/// Supports the classic header layout used by metadata versions 24–31
/// (Unity 2018–2023 and Unity 6.0). For anything it does not recognise it
/// falls back to a generic `strings`-style scan of the whole file, so a new
/// Unity version degrades to noisier output instead of missing strings.
Il2CppStrings readIl2CppMetadata(Uint8List bytes) {
  if (!isIl2CppMetadata(bytes) || bytes.length < 64) {
    return Il2CppStrings(0, const [], asciiStrings(bytes).toList(), parsed: false);
  }
  final bd = ByteData.sublistView(bytes);
  final version = bd.getInt32(4, Endian.little);

  // Try the classic layout: pairs of (offset, size) right after the header.
  final classic =
      _tryLayout(bytes, bd, version, litOff: 8, litSize: 12, dataOff: 16, dataSize: 20, strOff: 24, strSize: 28);
  if (classic != null) return classic;

  // Newer metadata (v35+) uses (offset, size, count) triples per section.
  final triples =
      _tryLayout(bytes, bd, version, litOff: 8, litSize: 12, dataOff: 20, dataSize: 24, strOff: 32, strSize: 36);
  if (triples != null) return triples;

  return Il2CppStrings(version, const [], asciiStrings(bytes).toList(), parsed: false);
}

Il2CppStrings? _tryLayout(Uint8List bytes, ByteData bd, int version,
    {required int litOff,
    required int litSize,
    required int dataOff,
    required int dataSize,
    required int strOff,
    required int strSize}) {
  int u(int at) => bd.getUint32(at, Endian.little);
  final lo = u(litOff), ls = u(litSize), dO = u(dataOff), dS = u(dataSize), so = u(strOff), ss = u(strSize);
  bool inside(int off, int size) => off >= 8 && size >= 0 && off + size <= bytes.length;
  if (!inside(lo, ls) || !inside(dO, dS) || !inside(so, ss) || ls % 8 != 0) return null;

  final literals = <ExtractedString>[];
  for (var at = lo; at + 8 <= lo + ls; at += 8) {
    final length = u(at);
    final index = u(at + 4);
    if (index + length > dS) return null; // layout guess was wrong
    final start = dO + index;
    if (length == 0) continue;
    literals.add(ExtractedString(decodeUtf8(bytes, start, start + length), start));
  }
  final identifiers = asciiStrings(bytes, start: so, end: so + ss, minLength: 3).toList();
  return Il2CppStrings(version, literals, identifiers, parsed: true);
}

/// Builds a synthetic `global-metadata.dat` (classic v29 layout) holding the
/// given literals and identifiers. Used by tests and fixture generation.
Uint8List buildFakeIl2CppMetadata(List<String> literals, List<String> identifiers, {int version = 29}) {
  const headerSize = 256;
  final data = BytesBuilder();
  final table = BytesBuilder();
  for (final s in literals) {
    final enc = s.codeUnits; // fixtures are ASCII
    final entry = ByteData(8)
      ..setUint32(0, enc.length, Endian.little)
      ..setUint32(4, data.length, Endian.little);
    table.add(entry.buffer.asUint8List());
    data.add(enc);
  }
  final idents = BytesBuilder();
  for (final s in identifiers) {
    idents
      ..add(s.codeUnits)
      ..addByte(0);
  }
  final t = table.toBytes(), d = data.toBytes(), id = idents.toBytes();
  final out = Uint8List(headerSize + t.length + d.length + id.length);
  final bd = ByteData.sublistView(out)
    ..setUint32(0, il2cppMetadataMagic, Endian.little)
    ..setInt32(4, version, Endian.little)
    ..setUint32(8, headerSize, Endian.little)
    ..setUint32(12, t.length, Endian.little)
    ..setUint32(16, headerSize + t.length, Endian.little)
    ..setUint32(20, d.length, Endian.little)
    ..setUint32(24, headerSize + t.length + d.length, Endian.little)
    ..setUint32(28, id.length, Endian.little);
  assert(bd.lengthInBytes == out.length);
  out.setRange(headerSize, headerSize + t.length, t);
  out.setRange(headerSize + t.length, headerSize + t.length + d.length, d);
  out.setRange(headerSize + t.length + d.length, out.length, id);
  return out;
}
