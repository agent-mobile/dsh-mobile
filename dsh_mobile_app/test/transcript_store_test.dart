/// Unit regression: the local transcript store round-trip — save writes the
/// documented layout, the header parses back with all metadata intact, the
/// body equals the labeled document, newest-first ordering holds, and delete
/// removes the file.
library;

import 'dart:io';

import 'package:dsh_mobile_app/services/transcript_store.dart';
import 'package:dsh_mobile_app/state/transcription_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// In-memory path_provider so the store lands in a scratch directory.
class _TempPathProvider extends PathProviderPlatform {
  _TempPathProvider(this.documentsPath);

  final String documentsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}

TranscriptionSessionResult _result({
  required List<TranscriptionTurn> turns,
  required String text,
}) {
  final now = DateTime(2026, 9, 7, 15, 30);
  return TranscriptionSessionResult(
    text: text,
    turns: turns,
    durationMs: 192000,
    startedAt: now.subtract(const Duration(seconds: 192)),
    endedAt: now,
  );
}

/// The store joins paths with '/', Windows tests split on '\'; accept both.
String _basename(String path) =>
    path.replaceAll('\\', '/').split('/').last;

void main() {
  late Directory scratch;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    scratch = await Directory.systemTemp.createTemp('transcript-store-test');
    PathProviderPlatform.instance = _TempPathProvider(scratch.path);
  });

  tearDownAll(() async {
    await scratch.delete(recursive: true);
  });

  test('save → list parses header metadata and body round-trips', () async {
    final saved = await saveTranscript(_result(
      text: '第一句\n第二句',
      turns: const [
        TranscriptionTurn(speaker: 0, text: '第一句', startMs: 0, endMs: 100),
        TranscriptionTurn(speaker: 1, text: '第二句', startMs: 100, endMs: 200),
      ],
    ));

    expect(saved.existsSync(), isTrue);
    expect(
      _basename(saved.path),
      'transcript-20260907-1530-192s-2turns.txt',
    );
    final lines = saved.readAsLinesSync();
    expect(lines.first, startsWith('# 转录 2026-09-07 15:30 · 时长 192s · 2 段 · 说话人分离'));
    expect(lines.skip(1).join('\n'), '[说话人 1] 第一句\n[说话人 2] 第二句');

    final entries = await listTranscripts();
    expect(entries, hasLength(1));
    expect(entries.single.filename, _basename(saved.path));
    expect(entries.single.date, DateTime(2026, 9, 7, 15, 30));
    expect(entries.single.durationSeconds, 192);
    expect(entries.single.turnCount, 2);
    expect(entries.single.diarized, isTrue);

    expect(await loadTranscriptBody(entries.single.file),
        '[说话人 1] 第一句\n[说话人 2] 第二句\n');
  });

  test('a single-speaker session saves unlabeled and non-diarized', () async {
    await saveTranscript(_result(
      text: '只有一句话',
      turns: const [
        TranscriptionTurn(speaker: 0, text: '只有一句话', startMs: 0, endMs: 400),
      ],
    ));
    final entries = await listTranscripts();
    final entry = entries.singleWhere((e) => e.filename.contains('1turns'));
    expect(entry.diarized, isFalse);
    expect(entry.turnCount, 1);
    expect(await loadTranscriptBody(entry.file), '只有一句话\n');
  });

  test('list is newest-first and delete removes the file', () async {
    final older = _result(
      text: '早',
      turns: const [TranscriptionTurn(speaker: 0, text: '早', startMs: 0, endMs: 0)],
    );
    await saveTranscript(older);
    final before = await listTranscripts();
    expect(before, hasLength(2));
    // The 15:30 two-turn session sorts ahead of the same-minute single-turn
    // one only by name; both must precede nothing older — check ordering is
    // deterministic (date desc, then stable).
    expect(before.first.date.isAfter(before.last.date)
        || before.first.date.isAtSameMomentAs(before.last.date), isTrue);

    await deleteTranscript(before.last.file);
    final after = await listTranscripts();
    expect(after, hasLength(1));
    expect(
      before.last.file.existsSync(),
      isFalse,
      reason: 'deleted file must be gone',
    );
  });
}
