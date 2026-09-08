/// Session content search over the connected host.
library;

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:flutter/material.dart';

import '../state/connection_controller.dart';
import '../state/voice_mode_controller.dart';
import 'chat_screen.dart';

/// Search bar + results over `session.search`.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.connection, required this.voiceModeController});

  final ConnectionController connection;

  /// Global voice/text mode preference, forwarded into opened chats.
  final VoiceModeController voiceModeController;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  List<SessionSearchItem> _results = const [];
  bool _hasMore = false;
  bool _searching = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final result = await widget.connection.sessions.search(query);
      if (!mounted) return;
      setState(() {
        _results = result.items;
        _hasMore = result.hasMore;
        _searching = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('搜索会话'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              controller: _controller,
              decoration: const InputDecoration(
                hintText: '搜索会话…',
                prefixIcon: Icon(Icons.search),
              ),
              onSubmitted: _search,
            ),
          ),
        ),
      ),
      body: _searching
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : _results.isEmpty
                  ? const Center(child: Text('搜索以查找匹配的会话消息。'))
                  : ListView(
                      children: [
                        if (_hasMore)
                          const Padding(
                            padding: EdgeInsets.all(8),
                            child: Text('仅显示前 20 条结果，请缩小搜索范围。'),
                          ),
                        for (final item in _results)
                          ListTile(
                            title: Text(item.sessionId.split('-').first),
                            subtitle: Text(
                              item.snippet,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => ChatScreen(
                                  connection: widget.connection,
                                  sessionId: item.sessionId,
                                  voiceModeController: widget.voiceModeController,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
    );
  }
}
