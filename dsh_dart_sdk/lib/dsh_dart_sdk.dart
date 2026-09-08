/// dsh_dart_sdk — Dart wire-protocol client for the DeepSeek Harness host.
///
/// A pure Dart client mirroring the TypeScript `dsh-host-apiproxy` and
/// `dsh-client-connection` contract: unary RPC over HTTP POST, client
/// responses over `/api/respond`, and two WebSocket event downlinks
/// (`events.mux`, `events.host`). A Bearer token authenticates every request.
///
/// Consume [DshApiClient] for raw transport, [DshSessionApi] for the session
/// domain, and [SessionSurface] for the folded transcript.
library;

export 'src/wire.dart';
export 'src/transport.dart';
export 'src/events.dart';
export 'src/sessions.dart';
export 'src/session_api.dart';
export 'src/interaction.dart';
export 'src/settings_api.dart';
export 'src/domain_api.dart';
export 'src/workspace_api.dart';
export 'src/commands_api.dart';
export 'src/speech_api.dart';
