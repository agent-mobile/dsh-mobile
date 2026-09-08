/// Local transcript store: persists finished live-transcription documents
/// as plain-text files under the app's private documents directory, so they
/// survive process restarts and can be loaded back as a chat prompt body
/// without server-side file-attachment support.
///
/// File layout: `transcripts/transcript-YYYYMMDD-HHmm-NNs-Nturns.txt`, first
/// line a `# ` metadata header (date, duration, turn count, diarization),
/// following lines the speaker-labeled turns. Any text editor can open them;
/// the loader parses only the header for the list view.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../state/transcription_controller.dart';

/// Metadata parsed from a saved transcript file's header; the body is read
/// on demand through [loadTranscriptBody].
class TranscriptEntry {
  TranscriptEntry({
    required this.filename,
    required this.date,
    required this.durationSeconds,
    required this.turnCount,
    required this.diarized,
    required this.file,
  });

  /// File basename without the directory.
  final String filename;

  /// Parsed session date.
  final DateTime date;

  /// Duration in seconds, from the header.
  final int durationSeconds;

  /// Turn count, from the header.
  final int turnCount;

  /// Whether the transcript carried speaker labels.
  final bool diarized;

  /// The underlying file handle.
  final File file;
}

/// Persist one finished session as a transcript file.
///
/// Returns the saved file so the caller can show its basename.
Future<File> saveTranscript(TranscriptionSessionResult result) async {
  final dir = await _transcriptsDir();
  final when = result.endedAt;
  final stamp =
      '${when.year.toString().padLeft(4, '0')}'
      '${when.month.toString().padLeft(2, '0')}'
      '${when.day.toString().padLeft(2, '0')}'
      '-'
      '${when.hour.toString().padLeft(2, '0')}'
      '${when.minute.toString().padLeft(2, '0')}';
  final durSec = (result.durationMs / 1000).round();
  final diarized = result.turns.any((turn) => turn.speaker != 0);
  final filename = 'transcript-$stamp-${durSec}s-${result.turns.length}turns.txt';
  final file = File('${dir.path}/$filename');
  final header = '# 转录 ${_formatDate(when)} · 时长 ${durSec}s · '
      '${result.turns.length} 段'
      '${diarized ? ' · 说话人分离' : ''}';
  final body = result.labeledText;
  await file.writeAsString('$header\n$body\n', flush: true);
  return file;
}

/// List saved transcripts, newest first.
Future<List<TranscriptEntry>> listTranscripts() async {
  final dir = await _transcriptsDir();
  final entries = <TranscriptEntry>[];
  await for (final entity in dir.list()) {
    if (entity is! File) continue;
    if (!entity.path.endsWith('.txt')) continue;
    final parsed = _parseHeader(entity);
    if (parsed != null) entries.add(parsed);
  }
  entries.sort((a, b) => b.date.compareTo(a.date));
  return entries;
}

/// Read the full body of one saved transcript (everything after the header).
Future<String> loadTranscriptBody(File file) async {
  final raw = await file.readAsString();
  final nl = raw.indexOf('\n');
  return nl < 0 ? raw : raw.substring(nl + 1);
}

/// Delete one saved transcript file.
Future<void> deleteTranscript(File file) async {
  if (await file.exists()) await file.delete();
}

Future<Directory> _transcriptsDir() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/transcripts');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

TranscriptEntry? _parseHeader(File file) {
  // Header shape:
  //   # 转录 2026-08-24 15:30 · 时长 192s · 5 段 · 说话人分离
  final basename = file.path.split(Platform.pathSeparator).last;
  // Use a synchronous peek of the first line; the file is small.
  // ignore: avoid_slow_async_io
  final lines = file.readAsLinesSync();
  if (lines.isEmpty) return null;
  final header = lines.first;
  if (!header.startsWith('# 转录 ')) return null;
  final parts = header.substring('# 转录 '.length).split(' · ');
  if (parts.length < 3) return null;
  final date = DateTime.tryParse(_joinDate(parts[0])) ?? DateTime.fromMillisecondsSinceEpoch(0);
  final durMatch = RegExp(r'(\d+)s').firstMatch(parts[1]);
  final turnsMatch = RegExp(r'(\d+) 段').firstMatch(parts[2]);
  return TranscriptEntry(
    filename: basename,
    date: date,
    durationSeconds: durMatch != null ? int.parse(durMatch.group(1)!) : 0,
    turnCount: turnsMatch != null ? int.parse(turnsMatch.group(1)!) : 0,
    diarized: parts.any((p) => p.contains('说话人分离')),
    file: file,
  );
}

/// Re-join "2026-08-24 15:30" into ISO "2026-08-24 15:30" → "2026-08-24T15:30".
String _joinDate(String raw) {
  final trimmed = raw.trim();
  final space = trimmed.indexOf(' ');
  if (space < 0) return trimmed;
  return '${trimmed.substring(0, space)}T${trimmed.substring(space + 1)}:00';
}

String _formatDate(DateTime when) =>
    '${when.year.toString().padLeft(4, '0')}-'
    '${when.month.toString().padLeft(2, '0')}-'
    '${when.day.toString().padLeft(2, '0')} '
    '${when.hour.toString().padLeft(2, '0')}:'
    '${when.minute.toString().padLeft(2, '0')}';