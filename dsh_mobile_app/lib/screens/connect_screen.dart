/// Connect screen: server address + token, validated by `host.describe`.
/// The desktop plugin's management page (/m/) shows pairing QR codes that
/// encode `<server>|<token>`; the scan button fills both fields from one.
library;

import 'dart:io' show Platform;

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart' show TransportException;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../main.dart';
import '../state/connection_controller.dart';
import '../state/theme_controller.dart';
import '../state/voice_mode_controller.dart';

/// Connect to a dsh host and navigate to the home screen on success.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, this.autoConnect, required this.themeController, required this.voiceModeController});

  /// When set to `host|token`, connect automatically on startup (used for
  /// headless/GUI verification without manual input).
  final String? autoConnect;

  /// App appearance preference, carried to the home screen for the settings
  /// entry.
  final ThemeController themeController;

  /// Global voice/text mode preference, carried to the home screen.
  final VoiceModeController voiceModeController;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _serverController = TextEditingController(text: 'http://127.0.0.1:3080');
  final _tokenController = TextEditingController();
  final _storage = const FlutterSecureStorage();
  bool _connecting = false;
  String? _error;
  String? _deviceId;

  @override
  void initState() {
    super.initState();
    _restore();
    final auto = widget.autoConnect;
    if (auto != null && auto.isNotEmpty) {
      final parts = auto.split('|');
      if (parts.length >= 2) {
        _serverController.text = parts[0];
        _tokenController.text = parts[1];
        // Defer until the first frame so the loading UI can render.
        WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
      }
    }
  }

  Future<void> _restore() async {
    try {
      final server = await _storage.read(key: 'dsh_server');
      final token = await _storage.read(key: 'dsh_token');
      if (server != null) _serverController.text = server;
      if (token != null) _tokenController.text = token;
    } catch (_) {
      // Storage unavailable (e.g. Windows dev); fall through to defaults.
    }
    await _ensureDeviceIdentity();
  }

  /// Load or mint the stable device identity the gateway's device ledger
  /// tracks, so one install shows up as one device on the management page.
  Future<void> _ensureDeviceIdentity() async {
    try {
      var id = await _storage.read(key: 'dsh_device_id');
      if (id == null || id.isEmpty) {
        id = DateTime.now().microsecondsSinceEpoch.toRadixString(36)
            + Platform.operatingSystem;
        await _storage.write(key: 'dsh_device_id', value: id);
      }
      if (mounted) setState(() => _deviceId = id);
    } catch (_) {
      // Without storage the gateway falls back to identifying by IP.
    }
  }

  Future<void> _connect() async {
    final rawServer = _serverController.text.trim();
    final token = _tokenController.text.trim();
    // A URL with whitespace (e.g. "10 99.0.2") parses as a malformed host:
    // Uri encodes the space to %20, and a % in the host is read as an IPv6
    // zone-id, producing the "not a valid link-local address but contains %"
    // error only later, at request time. Reject it here with a clear message.
    if (RegExp(r'\s').hasMatch(rawServer)) {
      setState(() => _error = '服务器地址包含空格，请去除后重试');
      return;
    }
    Uri? uri;
    try {
      uri = Uri.parse(rawServer);
      if (uri.scheme != 'http' && uri.scheme != 'https') {
        throw const FormatException('scheme');
      }
      if (uri.host.isEmpty) {
        throw const FormatException('host');
      }
    } catch (_) {
      setState(() => _error = '无效的服务器地址（使用 http://主机:端口）');
      return;
    }
    if (token.isEmpty) {
      setState(() => _error = '请输入访问令牌');
      return;
    }

    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      final connection = ConnectionController(
        baseUrl: uri,
        token: token,
        deviceId: _deviceId,
      );
      await connection.connect();
      try {
        await _storage.write(key: 'dsh_server', value: rawServer);
        await _storage.write(key: 'dsh_token', value: token);
      } catch (_) {
        // Non-persistent session is fine when storage is unavailable.
      }
      if (!mounted) return;
      openHome(context, connection, widget.themeController, widget.voiceModeController);
    } on TransportException catch (error) {
      setState(() {
        _connecting = false;
        _error = error.status == 401
            ? '未授权：请检查访问令牌（可在电脑 /m/ 管理页轮换）'
            : '连接失败：${error.message}';
      });
    } catch (error) {
      setState(() {
        _connecting = false;
        _error = '连接失败：$error';
      });
    }
  }

  /// Fill server + token from a pairing QR payload (`<server>|<token>`, the
  /// format the gateway management page renders), then connect at once — a
  /// scan carries both halves of a complete pairing, so an extra manual tap
  /// adds nothing. A bare URL fills only the server field and requires the
  /// token by hand, so it stops before connecting.
  void _applyScan(String raw) {
    final value = raw.trim();
    final separator = value.indexOf('|');
    if (separator > 0) {
      _serverController.text = value.substring(0, separator);
      _tokenController.text = value.substring(separator + 1);
      setState(() => _error = null);
      _connect();
      return;
    }
    if (value.startsWith('http://') || value.startsWith('https://')) {
      _serverController.text = value;
      setState(() => _error = null);
      return;
    }
    setState(() => _error = '二维码内容不是配对信息（应为 服务器|令牌）');
  }

  Future<void> _scan() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _ScannerScreen(onDetected: (value) {
        Navigator.of(context).pop();
        _applyScan(value);
      }),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('连接 DSH')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.terminal, size: 64),
            const SizedBox(height: 16),
            const Text(
              'DeepSeek Harness',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _serverController,
              decoration: const InputDecoration(
                labelText: '服务器地址',
                hintText: 'http://192.168.1.5:3080',
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _tokenController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '访问令牌',
                hintText: '在电脑 /m/ 管理页查看',
              ),
              onSubmitted: (_) => _connect(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _connecting ? null : _connect,
              child: _connecting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('连接'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _scan,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('扫码配对'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen camera scanner: pops itself with the first decoded value.
class _ScannerScreen extends StatefulWidget {
  const _ScannerScreen({required this.onDetected});

  final void Function(String value) onDetected;

  @override
  State<_ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<_ScannerScreen> {
  final _controller = MobileScannerController();
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫码配对')),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: (capture) {
              if (_done) return;
              final value = capture.barcodes.firstOrNull?.rawValue;
              if (value == null || value.isEmpty) return;
              _done = true;
              widget.onDetected(value);
            },
          ),
          const Positioned.fill(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  '对准电脑 /m/ 管理页上的二维码',
                  style: TextStyle(
                    color: Colors.white,
                    backgroundColor: Colors.black54,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
