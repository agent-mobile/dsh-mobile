/// Settings, credentials, and LLM-provider domain APIs.
///
/// Mirrors the TypeScript `settings.ts`, `credentials.ts`, and `llm.ts`
/// contract: the configuration-page wire. Settings values are redacted by the
/// seam (secret-role fields never ride a response; the `secrets` slot list
/// reports a write-only field's configured state). Credential values cross the
/// wire in exactly one direction 鈥?inside `credentials/set`.
library;

import 'transport.dart';
import 'wire.dart';

/// One schema-declared secret slot inside a redacted namespace value.
class SettingsSecretView {
  const SettingsSecretView({required this.path, required this.set});

  final List<String> path;
  final bool set;

  factory SettingsSecretView.fromJson(Map<String, Object?> json) => SettingsSecretView(
        path: (json['path'] is List) ? List<String>.from(json['path']! as List) : const [],
        set: json['set'] == true,
      );
}

/// Wire view of one registered settings namespace.
class SettingsNamespaceView {
  const SettingsNamespaceView({
    required this.ns,
    required this.schema,
    required this.value,
    required this.applies,
    required this.secrets,
    required this.revision,
    this.base,
    this.user,
  });

  final String ns;

  /// Serialized schemastery schema envelope (opaque JSON).
  final Object? schema;

  /// Redacted resolved value.
  final Map<String, Object?>? value;

  /// Redacted composition base layer, when declared.
  final Map<String, Object?>? base;

  /// Redacted raw user section, when one exists.
  final Map<String, Object?>? user;

  /// `live` or `restart`.
  final String applies;

  final List<SettingsSecretView> secrets;

  /// Monotonic revision; send back as `expectedRevision` on a write.
  final int revision;

  factory SettingsNamespaceView.fromJson(Map<String, Object?> json) {
    final rawSecrets = json['secrets'];
    final secrets = rawSecrets is List
        ? rawSecrets.whereType<Map>().map((s) => SettingsSecretView.fromJson(Map<String, Object?>.from(s))).toList()
        : const <SettingsSecretView>[];
    return SettingsNamespaceView(
      ns: json['ns'] as String? ?? '',
      schema: json['schema'],
      value: json['value'] is Map ? Map<String, Object?>.from(json['value']! as Map) : null,
      base: json['base'] is Map ? Map<String, Object?>.from(json['base']! as Map) : null,
      user: json['user'] is Map ? Map<String, Object?>.from(json['user']! as Map) : null,
      applies: json['applies'] as String? ?? 'restart',
      secrets: secrets,
      revision: (json['revision'] as num?)?.toInt() ?? 0,
    );
  }
}

/// One path-addressed edit for `settings/mutate`.
sealed class SettingsPathOp {
  const SettingsPathOp();
}

class SettingsPathSet extends SettingsPathOp {
  const SettingsPathSet(this.path, this.value);
  final List<String> path;
  final Object? value;
}

class SettingsPathUnset extends SettingsPathOp {
  const SettingsPathUnset(this.path);
  final List<String> path;
}

/// Wire view of one credential reference's state (never the value).
class CredentialView {
  const CredentialView({required this.configured, required this.writable, this.source});

  final bool configured;
  final bool writable;
  final String? source;

  factory CredentialView.fromJson(Map<String, Object?> json) => CredentialView(
        configured: json['configured'] == true,
        writable: json['writable'] == true,
        source: json['source'] as String?,
      );
}

/// One configurable provider in the directory.
class ConfigurableProviderView {
  const ConfigurableProviderView({
    required this.provider,
    required this.displayName,
    required this.settingsNs,
    required this.settingsPath,
    required this.active,
    this.declared,
  });

  final String provider;
  final String displayName;
  final String settingsNs;
  final List<String> settingsPath;
  final bool active;
  final bool? declared;

  factory ConfigurableProviderView.fromJson(Map<String, Object?> json) => ConfigurableProviderView(
        provider: json['provider'] as String? ?? '',
        displayName: json['displayName'] as String? ?? '',
        settingsNs: json['settingsNs'] as String? ?? '',
        settingsPath: json['settingsPath'] is List ? List<String>.from(json['settingsPath']! as List) : const [],
        active: json['active'] == true,
        declared: json['declared'] as bool?,
      );
}

/// One reasoning-effort level a model advertises.
class ModelReasoningEffort {
  const ModelReasoningEffort({required this.id, this.name, this.description});

  final String id;
  final String? name;
  final String? description;

  factory ModelReasoningEffort.fromJson(Map<String, Object?> json) => ModelReasoningEffort(
        id: json['id'] as String? ?? '',
        name: json['name'] as String?,
        description: json['description'] as String?,
      );
}

/// Exact-model reasoning metadata: advertised effort levels and the default.
class ModelReasoning {
  const ModelReasoning({this.efforts = const [], this.defaultEffort});

  final List<ModelReasoningEffort> efforts;
  final String? defaultEffort;

  factory ModelReasoning.fromJson(Map<String, Object?> json) {
    final raw = json['efforts'];
    final efforts = raw is List
        ? raw.whereType<Map>().map((e) => ModelReasoningEffort.fromJson(Map<String, Object?>.from(e))).toList()
        : const <ModelReasoningEffort>[];
    return ModelReasoning(
      efforts: efforts,
      defaultEffort: json['defaultEffort'] as String?,
    );
  }
}

/// One model advertised by a provider.
class ModelCatalogModel {
  final String id;
  final String? name;
  final String? description;
  final ModelReasoning? reasoning;

  /// Input modalities the model accepts (`text`, `image`, …), annotated by
  /// the gateway from the host LLM runtime. Empty means UNKNOWN — the host
  /// never restricts what a model has not declared, so only a list that is
  /// present AND lacks `image` marks a model as refusing image input.
  final List<String> inputModalities;

  /// Whether the model declares image input; false also when unknown.
  bool get supportsImageInput => inputModalities.contains('image');

  /// Whether the model explicitly declares text-only input (no image).
  bool get refusesImageInput => inputModalities.isNotEmpty && !supportsImageInput;

  const ModelCatalogModel({
    required this.id,
    this.name,
    this.description,
    this.reasoning,
    this.inputModalities = const [],
  });

  factory ModelCatalogModel.fromJson(Map<String, Object?> json) {
    final rawReasoning = json['reasoning'];
    final rawModalities = json['inputModalities'];
    return ModelCatalogModel(
      id: json['id'] as String? ?? '',
      name: json['name'] as String?,
      description: json['description'] as String?,
      reasoning: rawReasoning is Map
          ? ModelReasoning.fromJson(Map<String, Object?>.from(rawReasoning))
          : null,
      inputModalities: rawModalities is List
          ? rawModalities.whereType<String>().toList(growable: false)
          : const [],
    );
  }
}

/// One provider group and its advertised models.
class ModelProviderGroup {
  const ModelProviderGroup({required this.id, required this.name, required this.models});

  final String id;
  final String name;
  final List<ModelCatalogModel> models;

  factory ModelProviderGroup.fromJson(Map<String, Object?> json) {
    final raw = json['models'];
    final models = raw is List
        ? raw.whereType<Map>().map((m) => ModelCatalogModel.fromJson(Map<String, Object?>.from(m))).toList()
        : const <ModelCatalogModel>[];
    return ModelProviderGroup(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      models: models,
    );
  }
}

/// Settings, credentials, and LLM domain methods.
class DshConfigApi {
  DshConfigApi(this._client);

  final DshApiClient _client;

  Future<RpcResult<Object?>> _call(String method, Map<String, Object?> args) =>
      _client.callUnary<Object?>(method, args, (value) => value);

  RpcResultErr? _err(RpcResult<Object?> result) => result is RpcResultErr ? result : null;

  /// Describe every exposed settings namespace.
  Future<SettingsDescribeResult> settingsDescribe() async {
    final result = await _call('settings/describe', const {});
    switch (result) {
      case RpcResultErr(:final error):
        throw RpcDomainException('settings/describe', error);
      case RpcResultOk(:final value):
        final map = value is Map ? value : const <String, Object?>{};
        final rawNamespaces = map['namespaces'];
        final namespaces = rawNamespaces is List
            ? rawNamespaces
                .whereType<Map>()
                .map((ns) => SettingsNamespaceView.fromJson(Map<String, Object?>.from(ns)))
                .toList()
            : const <SettingsNamespaceView>[];
        return SettingsDescribeResult(
          writable: map['writable'] == true,
          hasDocument: map['hasDocument'] == true,
          namespaces: namespaces,
        );
    }
  }

  /// Merge a patch into one namespace's user layer.
  Future<SettingsNamespaceView> settingsUpdate({
    required String ns,
    required Map<String, Object?> patch,
    int? expectedRevision,
  }) async {
    final result = await _call('settings/update', {
      'ns': ns,
      'patch': patch,
      if (expectedRevision != null) 'expectedRevision': expectedRevision,
    });
    switch (result) {
      case RpcResultErr(:final error):
        throw RpcDomainException('settings/update', error);
      case RpcResultOk(:final value):
        return SettingsNamespaceView.fromJson(value is Map ? Map<String, Object?>.from(value) : const {});
    }
  }

  /// Replace one namespace's user section wholesale.
  Future<SettingsNamespaceView> settingsReplace({
    required String ns,
    required Map<String, Object?> section,
    int? expectedRevision,
  }) async {
    final result = await _call('settings/replace', {
      'ns': ns,
      'section': section,
      if (expectedRevision != null) 'expectedRevision': expectedRevision,
    });
    switch (result) {
      case RpcResultErr(:final error):
        throw RpcDomainException('settings/replace', error);
      case RpcResultOk(:final value):
        return SettingsNamespaceView.fromJson(value is Map ? Map<String, Object?>.from(value) : const {});
    }
  }

  /// Apply path-addressed edits to one namespace.
  Future<SettingsNamespaceView> settingsMutate({
    required String ns,
    required List<SettingsPathOp> ops,
    int? expectedRevision,
  }) async {
    final wireOps = ops.map((op) => switch (op) {
          SettingsPathSet(:final path, :final value) => {'op': 'set', 'path': path, 'value': value},
          SettingsPathUnset(:final path) => {'op': 'unset', 'path': path},
        }).toList();
    final result = await _call('settings/mutate', {
      'ns': ns,
      'ops': wireOps,
      if (expectedRevision != null) 'expectedRevision': expectedRevision,
    });
    switch (result) {
      case RpcResultErr(:final error):
        throw RpcDomainException('settings/mutate', error);
      case RpcResultOk(:final value):
        return SettingsNamespaceView.fromJson(value is Map ? Map<String, Object?>.from(value) : const {});
    }
  }

  /// Describe credential references (never values).
  Future<Map<String, CredentialView>> credentialsDescribe(List<String> refs) async {
    final result = await _call('credentials/describe', {'refs': refs});
    switch (result) {
      case RpcResultErr(:final error):
        throw RpcDomainException('credentials/describe', error);
      case RpcResultOk(:final value):
        final map = value is Map ? value : const <String, Object?>{};
        final raw = map['credentials'];
        if (raw is! Map) return const {};
        return {
          for (final entry in raw.entries)
            entry.key as String: CredentialView.fromJson(Map<String, Object?>.from(entry.value as Map)),
        };
    }
  }

  /// Store one credential value.
  Future<void> credentialsSet({required String ref, required String value}) async {
    final result = await _call('credentials/set', {'ref': ref, 'value': value});
    final err = _err(result);
    if (err != null) throw RpcDomainException('credentials/set', err.error);
  }

  /// Remove one credential from the writable layer.
  Future<void> credentialsUnset({required String ref}) async {
    final result = await _call('credentials/unset', {'ref': ref});
    final err = _err(result);
    if (err != null) throw RpcDomainException('credentials/unset', err.error);
  }

  /// List every configurable provider.
  Future<List<ConfigurableProviderView>> llmProviders() async {
    final result = await _call('llm/listProviders', const {});
    switch (result) {
      case RpcResultErr(:final error):
        throw RpcDomainException('llm/listProviders', error);
      case RpcResultOk(:final value):
        // The host answers a bare array of provider views (no wrapper object).
        final raw = value is List ? value : const <Object?>[];
        return raw.whereType<Map>().map((p) => ConfigurableProviderView.fromJson(Map<String, Object?>.from(p))).toList();
    }
  }

  /// Host-scoped model discovery over every registered provider.
  ///
  /// 0.1.2 replaced `llm.models` with `llm/discoverModels`, which takes
  /// `{settingsNs, request}`. A deployment-wide discovery uses the default
  /// settings namespace and an empty discovery request.
  Future<ModelCatalog> llmModels({String settingsNs = 'llm'}) async {
    final result = await _call('llm/discoverModels', {'settingsNs': settingsNs, 'request': const <String, Object?>{}});
    switch (result) {
      case RpcResultErr(:final error):
        throw RpcDomainException('llm/discoverModels', error);
      case RpcResultOk(:final value):
        final map = value is Map ? Map<String, Object?>.from(value) : const <String, Object?>{};
        return ModelCatalog.fromJson(map);
    }
  }
}

/// Result of `settings/describe`.
class SettingsDescribeResult {
  const SettingsDescribeResult({
    required this.writable,
    required this.hasDocument,
    required this.namespaces,
  });

  final bool writable;
  final bool hasDocument;
  final List<SettingsNamespaceView> namespaces;
}

/// Host-scoped model catalog (`llm.models`).
class ModelCatalog {
  const ModelCatalog({required this.groups, required this.failures});

  final List<ModelProviderGroup> groups;
  final List<Map<String, Object?>> failures;

  factory ModelCatalog.fromJson(Map<String, Object?> json) {
    final rawGroups = json['groups'];
    final groups = rawGroups is List
        ? rawGroups.whereType<Map>().map((g) => ModelProviderGroup.fromJson(Map<String, Object?>.from(g))).toList()
        : const <ModelProviderGroup>[];
    final rawFailures = json['failures'];
    final failures = rawFailures is List
        ? rawFailures.whereType<Map>().map((f) => Map<String, Object?>.from(f)).toList()
        : const <Map<String, Object?>>[];
    return ModelCatalog(groups: groups, failures: failures);
  }
}
