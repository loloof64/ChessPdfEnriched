import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// Persists per-page chess analysis to a JSON file so that re-opening a PDF
/// does not require re-parsing.
///
/// Cache validity is checked against the PDF file's last-modified timestamp.
/// If the file has been modified since the cache was written, the cache is
/// discarded and a fresh analysis is expected.
class AnalysisCache {
  static const _dirName = 'chess_pdf_cache';

  static Future<Directory> _cacheDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_dirName');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  // A simple, collision-resistant filename derived from the PDF path.
  static String _filename(String pdfPath) =>
      '${pdfPath.hashCode.toUnsigned(32).toRadixString(16).padLeft(8, '0')}.json';

  static Future<File> _file(String pdfPath) async {
    final dir = await _cacheDir();
    return File('${dir.path}/${_filename(pdfPath)}');
  }

  /// Load cached analysis for [pdfPath].
  ///
  /// Returns `null` if no cache exists or if the cache is stale.
  static Future<Map<int, PageAnalysis>?> load(String pdfPath) async {
    try {
      final pdfStat = await File(pdfPath).stat();
      final currentMtime = pdfStat.modified.millisecondsSinceEpoch;

      final cacheFile = await _file(pdfPath);
      if (!cacheFile.existsSync()) return null;

      final json = jsonDecode(await cacheFile.readAsString()) as Map<String, dynamic>;

      final cachedMtime = json['mtime'] as int?;
      if (cachedMtime != currentMtime) return null;

      final pagesJson = json['pages'] as Map<String, dynamic>;
      final pages = <int, PageAnalysis>{};
      for (final entry in pagesJson.entries) {
        final pageNum = int.tryParse(entry.key);
        if (pageNum != null) {
          pages[pageNum] = PageAnalysis.fromJson(
            entry.value as Map<String, dynamic>,
          );
        }
      }
      return pages;
    } catch (_) {
      return null;
    }
  }

  /// Delete the cached analysis for [pdfPath], forcing a fresh analysis next time.
  static Future<void> clear(String pdfPath) async {
    try {
      final cacheFile = await _file(pdfPath);
      if (cacheFile.existsSync()) await cacheFile.delete();
    } catch (_) {}
  }

  /// Persist [pages] analysis for [pdfPath].
  ///
  /// Failures are silently swallowed — the cache is best-effort.
  static Future<void> save(
    String pdfPath,
    Map<int, PageAnalysis> pages,
  ) async {
    try {
      final pdfStat = await File(pdfPath).stat();
      final mtime = pdfStat.modified.millisecondsSinceEpoch;

      final json = {
        'pdfPath': pdfPath,
        'mtime': mtime,
        'pages': {
          for (final entry in pages.entries)
            entry.key.toString(): entry.value.toJson(),
        },
      };

      final cacheFile = await _file(pdfPath);
      await cacheFile.writeAsString(jsonEncode(json));
    } catch (_) {}
  }
}
