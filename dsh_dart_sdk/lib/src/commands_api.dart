/// Command, skill, and slash-command execution domain API.
///
/// Mirrors the TypeScript command/skill contracts. `commands/list` and
/// `commands/execute` are Typert Remote methods: their payload must be the
/// `{args: {...}}` wrapper the gateway validates. `skill.list` is a plain
/// apiproxy RPC carrying `{sessionId}` directly; its [SkillEntry] type lives
/// in `session_api.dart`.
library;

import 'session_api.dart' show SkillEntry;
import 'transport.dart';
import 'wire.dart';

/// One discoverable slash command (`CommandDescriptor`).
class CommandDescriptor {
  const CommandDescriptor({required this.name, required this.description, this.inputHint});

  final String name;
  final String description;

  /// Input placeholder hint when the command takes an argument.
  final String? inputHint;

  factory CommandDescriptor.fromJson(Map<String, Object?> json) {
    final input = json['input'];
    return CommandDescriptor(
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      inputHint: input is Map ? input['hint'] as String? : null,
    );
  }
}

/// Slash-command domain: discovery (commands/skills) and execution.
class DshCommandsApi {
  DshCommandsApi(this._client);

  final DshApiClient _client;

  /// List discoverable slash commands for one session (`commands/list`).
  ///
  /// 0.1.2 scopes commands by the `agentId` wire field — the session's agent
  /// identity (the session id). The live host's strict descriptor rejects any
  /// other spelling.
  Future<List<CommandDescriptor>> listCommands({required String agentId}) async {
    final result = await _client.callUnary(
      'commands/list',
      {'agentId': agentId},
      (value) => value,
    );
    switch (result) {
      case RpcResultErr():
        throw RpcDomainException('commands/list', result.error);
      case RpcResultOk(:final value):
        if (value is! List) return const [];
        return value
            .whereType<Map>()
            .map((item) => CommandDescriptor.fromJson(Map<String, Object?>.from(item)))
            .toList();
    }
  }

  /// List user-invocable skills for one session (`skills/list`).
  Future<List<SkillEntry>> listSkills({required String sessionId}) async {
    final result = await _client.callUnary('skills/list', {
      'request': <String, Object?>{'sessionId': sessionId},
    }, (value) => value);
    switch (result) {
      case RpcResultErr():
        throw RpcDomainException('skills/list', result.error);
      case RpcResultOk(:final value):
        final map = value is Map ? value : const <String, Object?>{};
        final skills = map['skills'];
        if (skills is! List) return const [];
        return skills.whereType<Map>().map((item) {
          final json = Map<String, Object?>.from(item);
          return SkillEntry(
            name: json['name'] as String? ?? '',
            description: json['description'] as String? ?? '',
            whenToUse: json['whenToUse'] as String?,
            modelInvocable: json['modelInvocable'] == true,
          );
        }).toList();
    }
  }

  /// Execute one slash-command line for one session (`commands/execute`).
  /// Returns the pairing command id, or null when the line resolved to no
  /// command (the gateway omits `value` in that case).
  Future<String?> execute({required String agentId, required String line}) async {
    final result = await _client.callUnary(
      'commands/execute',
      // The host's strict remote descriptor requires the `images` field;
      // a plain invocation sends the empty list. 0.1.2 scopes by `agentId`.
      {'agentId': agentId, 'line': line, 'images': <Object>[]},
      (value) => value,
    );
    switch (result) {
      case RpcResultErr():
        throw RpcDomainException('commands/execute', result.error);
      case RpcResultOk(:final value):
        if (value is! Map) return null;
        return value['commandId'] as String?;
    }
  }
}
