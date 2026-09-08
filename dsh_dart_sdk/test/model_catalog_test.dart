/// Model catalog modality parsing: the gateway annotates `inputModalities`
/// from the host LLM runtime; entries without the field (legacy host, or a
/// model the runtime cannot describe) parse as UNKNOWN, and only a declared
/// text-only list counts as refusing image input.
library;

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:test/test.dart';

void main() {
  test('a declared vision entry parses modalities and flags image support', () {
    final model = ModelCatalogModel.fromJson(const {
      'id': 'deepseek-v4-flash-vision-exp',
      'name': 'DeepSeek-V4-Flash-Vision-Exp',
      'inputModalities': ['text', 'image'],
    });
    expect(model.inputModalities, ['text', 'image']);
    expect(model.supportsImageInput, isTrue);
    expect(model.refusesImageInput, isFalse);
  });

  test('a declared text-only entry is the only refusal shape', () {
    final model = ModelCatalogModel.fromJson(const {
      'id': 'deepseek-v4-flash',
      'inputModalities': ['text'],
    });
    expect(model.supportsImageInput, isFalse);
    expect(model.refusesImageInput, isTrue);
  });

  test('an entry without the field is unknown, not a refusal', () {
    final model = ModelCatalogModel.fromJson(const {
      'id': 'legacy-model',
      'name': 'Legacy Host',
    });
    expect(model.inputModalities, isEmpty);
    expect(model.supportsImageInput, isFalse);
    expect(model.refusesImageInput, isFalse);
  });

  test('non-string modality entries are dropped, not crash', () {
    final model = ModelCatalogModel.fromJson(const {
      'id': 'weird',
      'inputModalities': ['text', 7, null],
    });
    expect(model.inputModalities, ['text']);
  });

  test('the full catalog envelope flows through SessionModels', () {
    final models = SessionModels.fromJson(const {
      'default': {'provider': 'p', 'model': 'm'},
      'routableProviders': ['p'],
      'groups': [
        {
          'id': 'p',
          'name': 'Provider',
          'models': [
            {'id': 'm', 'inputModalities': ['text']},
            {'id': 'v', 'inputModalities': ['text', 'image']},
          ],
        },
      ],
      'failures': [],
    });
    final flat = [for (final g in models.groups) ...g.models];
    expect(flat.map((m) => m.supportsImageInput), [false, true]);
    expect(flat.map((m) => m.refusesImageInput), [true, false]);
  });
}
