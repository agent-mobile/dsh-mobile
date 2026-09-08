/// Directory picker over the host's browse capability (`host.listDirectory` /
/// `host.createDirectory`): breadcrumb navigation, directory entries, and a
/// create-folder action. The phone has no native picker for the host
/// filesystem, so this is the workspace-path entry surface.
library;

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:flutter/material.dart';

import '../state/connection_controller.dart';

/// Full-screen directory browser; returns the selected path.
class DirectoryPickerScreen extends StatefulWidget {
  const DirectoryPickerScreen({super.key, required this.connection});

  final ConnectionController connection;

  @override
  State<DirectoryPickerScreen> createState() => _DirectoryPickerScreenState();
}

class _DirectoryPickerScreenState extends State<DirectoryPickerScreen> {
  DirectoryListing? _listing;
  bool _loading = true;
  String? _error;
  String? _currentPath;

  @override
  void initState() {
    super.initState();
    _browse(null);
  }

  Future<void> _browse(String? path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final listing = await widget.connection.workspaces.listDirectory(path: path);
      if (!mounted) return;
      setState(() {
        _listing = listing;
        _currentPath = listing.path;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _createFolder() async {
    final name = await _promptFolderName();
    if (name == null || name.trim().isEmpty || _currentPath == null) return;
    try {
      await widget.connection.workspaces.createDirectory(
        path: _currentPath!,
        name: name.trim(),
      );
      await _browse(_currentPath);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('创建失败：$error')),
        );
      }
    }
  }

  Future<String?> _promptFolderName() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '文件夹名称'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('选择工作区'),
        actions: [
          if (_currentPath != null)
            FilledButton(
              onPressed: () => Navigator.of(context).pop(_currentPath),
              child: const Text('选择此文件夹'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : Column(
                  children: [
                    // Breadcrumbs.
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        children: [
                          for (final crumb in _listing?.crumbs ?? const <DirectoryEntry>[])
                            InkWell(
                              onTap: () => _browse(crumb.path),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 4),
                                child: Row(
                                  children: [
                                    const Icon(Icons.chevron_right, size: 14),
                                    Text(crumb.name, style: const TextStyle(fontSize: 13)),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    // Directory entries.
                    Expanded(
                      child: (_listing?.entries.isEmpty ?? true)
                          ? const Center(child: Text('空文件夹'))
                          : ListView.builder(
                              itemCount: _listing!.entries.length,
                              itemBuilder: (context, index) {
                                final entry = _listing!.entries[index];
                                return ListTile(
                                  dense: true,
                                  leading: const Icon(Icons.folder_outlined),
                                  title: Text(entry.name),
                                  subtitle: Text(entry.path),
                                  onTap: () => _browse(entry.path),
                                );
                              },
                            ),
                    ),
                  ],
                ),
      floatingActionButton: FloatingActionButton.small(
        tooltip: '新建文件夹',
        onPressed: _createFolder,
        child: const Icon(Icons.create_new_folder_outlined),
      ),
    );
  }
}
