/// Live end-to-end check of the app's approval + question answer path.
///
/// Reproduces exactly what dsh_mobile_app does: open `$events`, create a
/// session, prompt the model in a way that raises each waterfall, answer via
/// `DshInteractionApi`, and verify the HOST side actually consumed the answer
/// (tool result not an error; side effect applied).
///
/// Usage: dart run tool/approval_e2e_check.dart <server-url> <token>
library;

import 'dart:async';
import 'dart:io';

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';

Future<void> main(List<String> args) async {
  final base = Uri.parse(args.isNotEmpty ? args[0] : 'http://127.0.0.1:3080');
  final token = args.length > 1 ? args[1] : 'your-token';
  final client = DshApiClient(baseUrl: base, token: token);
  final sessions = DshSessionApi(client);
  final interaction = DshInteractionApi(client);

  final events = await client.openEvents();
  final frames = <RemoteEventFrame>[];
  final sub = events.frames.listen((frame) {
    frames.add(frame);
    if (frame.type == 'waterfall' || frame.type == 'cancel') {
      print('[frame] ${frame.type} event=${frame.event} eventId=${frame.eventId}');
    }
  });
  final readyDeadline = DateTime.now().add(const Duration(seconds: 10));
  while (events.clientId == null && DateTime.now().isBefore(readyDeadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  print('clientId: ${events.clientId}');

  final sessionId = await sessions.create();
  print('session: $sessionId');

  // ---- Stage 1: out-of-workspace file write -> approval waterfall.
  // The session workspace defaults to a plugin dir, so the user-profile path
  // sits outside it and must raise approval/request under the 'ask' policy.
  // (Drive roots like E:\ are ACL-locked even for raw PowerShell — a failed
  // write there says nothing about the approval path.)
  print('== stage 1: approval ==');
  final framesBeforeStage1 = frames.length;
  const probePath = r'C:\Users\Administrator\dsh-approval-e2e-probe.txt';
  final probe = File(probePath);
  if (probe.existsSync()) probe.deleteSync();
  await sessions.prompt(
    sessionId: sessionId,
    content: [
      {'type': 'text', 'text': '请把一行文字 "approval e2e probe" 写入文件 $probePath（注意：这个路径在当前工作区之外，直接写即可，不要换别的路径）。写完后只回复"已写入"。'},
    ],
  );
  final approval = await _waitFor(
    frames.skip(framesBeforeStage1).toList(),
    (f) => f.type == 'waterfall' && f.event == 'approval/request',
    timeout: const Duration(seconds: 150),
  );
  if (approval == null) {
    print('RESULT stage1: no approval waterfall arrived');
  } else {
    final req = ApprovalRequest.fromWaterfall(
      clientId: events.clientId ?? '',
      eventId: approval.eventId!,
      request: approval.request!,
    );
    print('answering approval eventId=${req.eventId} tool=${req.toolName} reason=${req.reason}');
    try {
      await interaction.answerApproval(request: req, outcome: ApprovalOutcome.allowedOnce);
      print('ANSWER APPROVAL: posted');
    } catch (error) {
      print('ANSWER APPROVAL: FAILED -> $error');
    }
    // The write side effect proves the host honored 'allowed-once'.
    var written = false;
    final writeDeadline = DateTime.now().add(const Duration(seconds: 90));
    while (DateTime.now().isBefore(writeDeadline)) {
      if (probe.existsSync()) {
        written = true;
        break;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    print('FILE WRITTEN AFTER ALLOW: $written'
        '${written ? ' (content: ${probe.readAsStringSync().trim()})' : ''}');
    if (written) probe.deleteSync();
  }

  // ---- Stage 2: ask_user_question waterfall -> the answer must reach the
  // tool (no map error, no re-ask). Only frames arriving AFTER the prompt
  // count: the host re-delivers a previous run's still-pending waterfalls on
  // every new `$events` generation, and answering one of those would say
  // nothing about this run.
  print('== stage 2: user question ==');
  final framesBeforePrompt = frames.length;
  await sessions.prompt(
    sessionId: sessionId,
    content: [
      {'type': 'text', 'text': '请使用 ask_user_question 工具问我一个问题：我更喜欢猫还是狗？给出"猫"和"狗"两个选项。收到我的回答后，直接复述我选了什么，不要再次提问。'},
    ],
  );
  final question = await _waitFor(
    frames.skip(framesBeforePrompt).toList(),
    (f) => f.type == 'waterfall' && f.event == 'user-questions/request',
    timeout: const Duration(seconds: 150),
  );
  if (question == null) {
    print('RESULT stage2: no question waterfall arrived');
  } else {
    final req = QuestionRequest.fromWaterfall(
      clientId: events.clientId ?? '',
      eventId: question.eventId!,
      request: question.request!,
    );
    print('answering question eventId=${req.eventId} items=${req.questions.map((q) => q.id).toList()}');
    final answerBatch = QuestionAnswerBatch([
      for (final q in req.questions)
        (
          id: q.id,
          answer: QuestionAnswer(selected: [
            q.options.isNotEmpty ? q.options.first.label : '猫',
          ]),
        ),
    ]);
    try {
      await interaction.answerQuestions(request: req, answer: answerBatch);
      print('ANSWER QUESTION: posted ${answerBatch.toJson()}');
    } catch (error) {
      print('ANSWER QUESTION: FAILED -> $error');
    }
    // A second waterfall after the prompt means the tool errored and the
    // model re-asked — the exact bug symptom.
    await Future<void>.delayed(const Duration(seconds: 20));
    final reasked = frames
        .skip(framesBeforePrompt)
        .any((f) => f.type == 'waterfall' && f.event == 'user-questions/request' && !identical(f, question));
    print('MODEL RE-ASKED AFTER ANSWER: $reasked');
  }

  await sub.cancel();
  await events.close();
  client.dispose();
  print('== e2e done ==');
}

/// First frame matching [test], polling the accumulated list; null on timeout.
Future<RemoteEventFrame?> _waitFor(
  List<RemoteEventFrame> frames,
  bool Function(RemoteEventFrame) test, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  var scanned = 0;
  while (DateTime.now().isBefore(deadline)) {
    for (; scanned < frames.length; scanned++) {
      if (test(frames[scanned])) return frames[scanned];
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return null;
}
