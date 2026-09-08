/// User-question sheet: renders an `ask_user_question` batch and submits one
/// whole answer.
library;

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:flutter/material.dart';

/// Interactive question sheet over the pending question batch.
class QuestionSheet extends StatefulWidget {
  const QuestionSheet({super.key, required this.question, required this.onSubmit});

  final QuestionRequest question;
  final ValueChanged<QuestionAnswerBatch> onSubmit;

  @override
  State<QuestionSheet> createState() => _QuestionSheetState();
}

class _QuestionSheetState extends State<QuestionSheet> {
  final _answers = <String, QuestionAnswer>{};

  bool get _complete =>
      widget.question.questions.every((item) => _answers.containsKey(item.id));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final questions = widget.question.questions;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.help_outline, color: scheme.primary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('提问', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final item in questions) _QuestionItemEditor(
              item: item,
              answer: _answers[item.id],
              onChange: (answer) {
                setState(() => _answers[item.id] = answer);
              },
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _complete
                    ? () => widget.onSubmit(QuestionAnswerBatch([
                          for (final item in widget.question.questions)
                            (id: item.id, answer: _answers[item.id]!),
                        ]))
                    : null,
                child: const Text('提交回答'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Editor for one question item: options (single/multi) plus free text.
class _QuestionItemEditor extends StatelessWidget {
  const _QuestionItemEditor({
    required this.item,
    required this.answer,
    required this.onChange,
  });

  final QuestionItem item;
  final QuestionAnswer? answer;
  final ValueChanged<QuestionAnswer> onChange;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = answer?.selected ?? const <String>[];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.question, style: const TextStyle(fontWeight: FontWeight.w600)),
          if (item.header != null)
            Text(item.header!, style: TextStyle(fontSize: 12, color: scheme.outline)),
          const SizedBox(height: 4),
          for (final option in item.options)
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(option.label),
              subtitle: option.description != null ? Text(option.description!) : null,
              value: selected.contains(option.label),
              onChanged: (checked) {
                final next = List<String>.from(selected);
                if (item.multiSelect) {
                  if (checked == true) {
                    next.add(option.label);
                  } else {
                    next.remove(option.label);
                  }
                } else {
                  next
                    ..clear()
                    ..add(option.label);
                }
                onChange(QuestionAnswer(selected: next));
              },
            ),
          if (item.options.isNotEmpty)
            TextField(
              decoration: const InputDecoration(labelText: '或输入自定义答案'),
              onChanged: (value) {
                onChange(QuestionAnswer(
                  // The host's single-select validation rejects a question
                  // answered with both an option and custom text; typing a
                  // custom answer clears the option selection (web parity).
                  selected: value.isEmpty || item.multiSelect ? selected : const <String>[],
                  custom: value.trim().isEmpty ? null : value,
                ));
              },
            ),
        ],
      ),
    );
  }
}
