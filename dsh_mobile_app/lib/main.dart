import 'package:flutter/material.dart';

import 'screens/connect_screen.dart';
import 'screens/home_screen.dart';
import 'state/connection_controller.dart';
import 'state/theme_controller.dart';
import 'state/voice_mode_controller.dart';
import 'theme.dart';

void main() {
  runApp(const DshMobileApp());
}

class DshMobileApp extends StatefulWidget {
  const DshMobileApp({super.key});

  @override
  State<DshMobileApp> createState() => _DshMobileAppState();
}

class _DshMobileAppState extends State<DshMobileApp> {
  final ThemeController _theme = ThemeController();
  final VoiceModeController _voiceMode = VoiceModeController();

  @override
  void initState() {
    super.initState();
    _theme.load();
    _voiceMode.load();
  }

  @override
  void dispose() {
    _theme.dispose();
    _voiceMode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_theme, _voiceMode]),
      builder: (context, _) => MaterialApp(
        title: 'DeepSeek Harness',
        theme: dshLightTheme(),
        darkTheme: dshDarkTheme(),
        themeMode: _theme.mode,
        home: ConnectScreen(
          autoConnect: const String.fromEnvironment('DSH_AUTOCONNECT'),
          themeController: _theme,
          voiceModeController: _voiceMode,
        ),
      ),
    );
  }
}

/// Navigate to the connected home screen after a successful connect.
void openHome(
  BuildContext context,
  ConnectionController connection,
  ThemeController themeController,
  VoiceModeController voiceModeController,
) {
  Navigator.of(context).pushReplacement(
    MaterialPageRoute<void>(
      builder: (_) => HomeScreen(
        connection: connection,
        themeController: themeController,
        voiceModeController: voiceModeController,
      ),
    ),
  );
}