
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

final Uint32List _crcTable = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
    }
    t[n] = c;
  }
  return t;
}();

int crc32Update(int crc, Uint8List data) {
  var c = crc ^ 0xFFFFFFFF;
  for (var i = 0; i < data.length; i++) {
    c = _crcTable[(c ^ data[i]) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

Uint8List _asBytes(List<int> d) => d is Uint8List ? d : Uint8List.fromList(d);

class _Out {
  final BytesBuilder _b = BytesBuilder(copy: false);
  void u16(int v) => _b.add([v & 0xFF, (v >> 8) & 0xFF]);
  void u32(int v) => _b.add(
      [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  void u64(int v) {
    u32(v & 0xFFFFFFFF);
    u32((v >> 32) & 0xFFFFFFFF);
  }

  void bytes(List<int> v) => _b.add(v);
  Uint8List take() => _b.takeBytes();
}

int _dosTime(DateTime t) => (t.hour << 11) | (t.minute << 5) | (t.second ~/ 2);
int _dosDate(DateTime t) {
  final y = t.year < 1980 ? 1980 : t.year;
  return ((y - 1980) << 9) | (t.month << 5) | t.day;
}

class _WEntry {
  final String name;
  final int offset, crc, size, time, date;
  _WEntry(this.name, this.offset, this.crc, this.size, this.time, this.date);
}

class ZipWriter {
  final RandomAccessFile _raf;
  final List<_WEntry> _entries = [];
  int _pos = 0;

  ZipWriter._(this._raf);

  static Future<ZipWriter> create(String path) async =>
      ZipWriter._(await File(path).open(mode: FileMode.write));

  Future<void> _write(Uint8List d) async {
    await _raf.writeFrom(d);
    _pos += d.length;
  }

  Future<void> addBytes(String name, List<int> data, {DateTime? time}) async {
    final t = time ?? DateTime.now();
    final nb = utf8.encode(name);
    final d = _asBytes(data);
    final crc = crc32Update(0, d);
    final offset = _pos;
    final h = _Out()
      ..u32(0x04034b50)
      ..u16(20)
      ..u16(0x0800)
      ..u16(0)
      ..u16(_dosTime(t))
      ..u16(_dosDate(t))
      ..u32(crc)
      ..u32(d.length)
      ..u32(d.length)
      ..u16(nb.length)
      ..u16(0)
      ..bytes(nb);
    await _write(h.take());
    await _write(d);
    _entries.add(
        _WEntry(name, offset, crc, d.length, _dosTime(t), _dosDate(t)));
  }

  Future<void> addFile(String name, File file,
      {void Function(int bytes)? onBytes}) async {
    final nb = utf8.encode(name);
    DateTime t;
    try {
      t = await file.lastModified();
    } catch (_) {
      t = DateTime.now();
    }
    final offset = _pos;
    final h = _Out()
      ..u32(0x04034b50)
      ..u16(20)
      ..u16(0x0800)
      ..u16(0)
      ..u16(_dosTime(t))
      ..u16(_dosDate(t))
      ..u32(0)
      ..u32(0)
      ..u32(0)
      ..u16(nb.length)
      ..u16(0)
      ..bytes(nb);
    try {
      await _write(h.take());
      var crc = 0;
      var size = 0;
      await for (final chunk in file.openRead()) {
        final d = _asBytes(chunk);
        size += d.length;
        if (size >= 0xFFFFFFFF) {
          throw const FormatException('A single file is too big (4 GB or more)');
        }
        crc = crc32Update(crc, d);
        await _write(d);
        onBytes?.call(d.length);
      }
      final end = _pos;
      final p = _Out()
        ..u32(crc)
        ..u32(size)
        ..u32(size);
      await _raf.setPosition(offset + 14);
      await _raf.writeFrom(p.take());
      await _raf.setPosition(end);
      _entries
          .add(_WEntry(name, offset, crc, size, _dosTime(t), _dosDate(t)));
    } catch (_) {
      try {
        await _raf.truncate(offset);
        await _raf.setPosition(offset);
        _pos = offset;
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> close() async {
    try {
      final cdStart = _pos;
      final cd = _Out();
      for (final e in _entries) {
        final big = e.offset >= 0xFFFFFFFF;
        final nb = utf8.encode(e.name);
        cd
          ..u32(0x02014b50)
          ..u16(big ? 45 : 20)
          ..u16(big ? 45 : 20)
          ..u16(0x0800)
          ..u16(0)
          ..u16(e.time)
          ..u16(e.date)
          ..u32(e.crc)
          ..u32(e.size)
          ..u32(e.size)
          ..u16(nb.length)
          ..u16(big ? 12 : 0)
          ..u16(0)
          ..u16(0)
          ..u16(0)
          ..u32(0)
          ..u32(big ? 0xFFFFFFFF : e.offset)
          ..bytes(nb);
        if (big) {
          cd
            ..u16(1)
            ..u16(8)
            ..u64(e.offset);
        }
      }
      final cdBytes = cd.take();
      await _write(cdBytes);
      final n = _entries.length;
      final needZip64 =
          n >= 0xFFFF || cdStart >= 0xFFFFFFFF || cdBytes.length >= 0xFFFFFFFF;
      final end = _Out();
      if (needZip64) {
        final z64Pos = _pos;
        end
          ..u32(0x06064b50)
          ..u64(44)
          ..u16(45)
          ..u16(45)
          ..u32(0)
          ..u32(0)
          ..u64(n)
          ..u64(n)
          ..u64(cdBytes.length)
          ..u64(cdStart)
          ..u32(0x07064b50)
          ..u32(0)
          ..u64(z64Pos)
          ..u32(1);
      }
      end
        ..u32(0x06054b50)
        ..u16(0)
        ..u16(0)
        ..u16(n >= 0xFFFF ? 0xFFFF : n)
        ..u16(n >= 0xFFFF ? 0xFFFF : n)
        ..u32(cdBytes.length >= 0xFFFFFFFF ? 0xFFFFFFFF : cdBytes.length)
        ..u32(cdStart >= 0xFFFFFFFF ? 0xFFFFFFFF : cdStart)
        ..u16(0);
      await _write(end.take());
      await _raf.flush();
    } finally {
      await _raf.close();
    }
  }

  Future<void> abort() async {
    try {
      await _raf.close();
    } catch (_) {}
  }
}

class ZipEntryInfo {
  final String name;
  final int method, crc, size, offset;
  const ZipEntryInfo(this.name, this.method, this.crc, this.size, this.offset);
}

class ZipReader {
  final RandomAccessFile _raf;
  final Map<String, ZipEntryInfo> _byName;

  ZipReader._(this._raf, this._byName);

  Iterable<ZipEntryInfo> get entries => _byName.values;
  ZipEntryInfo? find(String name) => _byName[name];

  static Future<ZipReader> open(String path) async {
    final raf = await File(path).open();
    try {
      final len = await raf.length();
      if (len < 22) throw const FormatException('Not a zip file');
      final int tailStart = len - math.min<int>(len, 22 + 0xFFFF).toInt();
      await raf.setPosition(tailStart);
      final tail = await raf.read(len - tailStart);
      var e = -1;
      for (var i = tail.length - 22; i >= 0; i--) {
        if (tail[i] == 0x50 &&
            tail[i + 1] == 0x4b &&
            tail[i + 2] == 5 &&
            tail[i + 3] == 6) {
          e = i;
          break;
        }
      }
      if (e < 0) throw const FormatException('Not a zip file');
      final tb = ByteData.sublistView(tail);
      var count = tb.getUint16(e + 10, Endian.little);
      var cdSize = tb.getUint32(e + 12, Endian.little);
      var cdOff = tb.getUint32(e + 16, Endian.little);
      if (count == 0xFFFF || cdSize == 0xFFFFFFFF || cdOff == 0xFFFFFFFF) {
        final locPos = tailStart + e - 20;
        if (locPos < 0) throw const FormatException('Bad zip64 data');
        await raf.setPosition(locPos);
        final loc = await raf.read(20);
        final lb = ByteData.sublistView(loc);
        if (loc.length < 20 || lb.getUint32(0, Endian.little) != 0x07064b50) {
          throw const FormatException('Bad zip64 data');
        }
        await raf.setPosition(lb.getUint64(8, Endian.little));
        final rec = await raf.read(56);
        final rb = ByteData.sublistView(rec);
        if (rec.length < 56 || rb.getUint32(0, Endian.little) != 0x06064b50) {
          throw const FormatException('Bad zip64 data');
        }
        count = rb.getUint64(32, Endian.little);
        cdSize = rb.getUint64(40, Endian.little);
        cdOff = rb.getUint64(48, Endian.little);
      }
      if (cdSize > 256 * 1024 * 1024) {
        throw const FormatException('Table of contents is too big');
      }
      await raf.setPosition(cdOff);
      final cd = await raf.read(cdSize);
      final b = ByteData.sublistView(cd);
      final map = <String, ZipEntryInfo>{};
      var p = 0;
      for (var i = 0; i < count; i++) {
        if (p + 46 > cd.length || b.getUint32(p, Endian.little) != 0x02014b50) {
          throw const FormatException('Damaged zip file');
        }
        final method = b.getUint16(p + 10, Endian.little);
        final crc = b.getUint32(p + 16, Endian.little);
        var csize = b.getUint32(p + 20, Endian.little);
        var usize = b.getUint32(p + 24, Endian.little);
        final nl = b.getUint16(p + 28, Endian.little);
        final el = b.getUint16(p + 30, Endian.little);
        final cl = b.getUint16(p + 32, Endian.little);
        var off = b.getUint32(p + 42, Endian.little);
        if (p + 46 + nl + el > cd.length) {
          throw const FormatException('Damaged zip file');
        }
        final name = utf8.decode(cd.sublist(p + 46, p + 46 + nl),
            allowMalformed: true);
        var q = p + 46 + nl;
        final qEnd = q + el;
        while (q + 4 <= qEnd) {
          final id = b.getUint16(q, Endian.little);
          final sz = b.getUint16(q + 2, Endian.little);
          if (id == 1) {
            var r = q + 4;
            if (usize == 0xFFFFFFFF && r + 8 <= qEnd) {
              usize = b.getUint64(r, Endian.little);
              r += 8;
            }
            if (csize == 0xFFFFFFFF && r + 8 <= qEnd) {
              csize = b.getUint64(r, Endian.little);
              r += 8;
            }
            if (off == 0xFFFFFFFF && r + 8 <= qEnd) {
              off = b.getUint64(r, Endian.little);
              r += 8;
            }
          }
          q += 4 + sz;
        }
        p += 46 + nl + el + cl;
        map[name] = ZipEntryInfo(name, method, crc, usize, off);
      }
      return ZipReader._(raf, map);
    } catch (_) {
      await raf.close();
      rethrow;
    }
  }

  Future<int> _dataStart(ZipEntryInfo e) async {
    if (e.method != 0) {
      throw const FormatException('This zip was not made by the app');
    }
    await _raf.setPosition(e.offset);
    final h = await _raf.read(30);
    final hb = ByteData.sublistView(h);
    if (h.length < 30 || hb.getUint32(0, Endian.little) != 0x04034b50) {
      throw const FormatException('Damaged zip file');
    }
    return e.offset +
        30 +
        hb.getUint16(26, Endian.little) +
        hb.getUint16(28, Endian.little);
  }

  Future<Uint8List> readBytes(ZipEntryInfo e) async {
    if (e.size > 64 * 1024 * 1024) {
      throw const FormatException('Entry is too big to read at once');
    }
    await _raf.setPosition(await _dataStart(e));
    final d = await _raf.read(e.size);
    if (d.length != e.size || crc32Update(0, d) != e.crc) {
      throw const FormatException('Damaged zip file');
    }
    return d;
  }

  Future<void> extractTo(ZipEntryInfo e, String destPath,
      {void Function(int bytes)? onBytes}) async {
    RandomAccessFile? out;
    try {
      await _raf.setPosition(await _dataStart(e));
      out = await File(destPath).open(mode: FileMode.write);
      var left = e.size;
      var crc = 0;
      while (left > 0) {
        final d = await _raf.read(math.min(left, 256 * 1024));
        if (d.isEmpty) throw const FormatException('Damaged zip file');
        crc = crc32Update(crc, d);
        await out.writeFrom(d);
        left -= d.length;
        onBytes?.call(d.length);
      }
      await out.close();
      out = null;
      if (crc != e.crc) throw const FormatException('Damaged zip file');
    } catch (_) {
      try {
        await out?.close();
      } catch (_) {}
      try {
        await File(destPath).delete();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> close() async {
    try {
      await _raf.close();
    } catch (_) {}
  }
}

Future<bool> looksLikeZip(String path) async {
  try {
    final raf = await File(path).open();
    try {
      final h = await raf.read(4);
      return h.length == 4 &&
          h[0] == 0x50 &&
          h[1] == 0x4b &&
          (h[2] == 3 || h[2] == 5);
    } finally {
      await raf.close();
    }
  } catch (_) {
    return false;
  }
}
