import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:macos_file_open_handler/macos_file_open_handler.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  static const String _coldStartTestOutput = String.fromEnvironment(
    'MACOS_FILE_OPEN_HANDLER_COLD_START_OUTPUT',
  );

  final List<MacosOpenedFile> _openedFiles = <MacosOpenedFile>[];
  Object? _lastError;
  late final MacosFileOpenSubscription _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = MacosFileOpenHandler.instance.listen(
      (files) async {
        if (_coldStartTestOutput.isNotEmpty) {
          await File(_coldStartTestOutput).writeAsString(
            '${files.map((file) => file.path).join('\n')}\n',
            mode: FileMode.append,
            flush: true,
          );
          unawaited(
            Future<void>.delayed(const Duration(seconds: 1), () => exit(0)),
          );
        }
        if (!mounted) {
          return;
        }
        setState(() {
          _openedFiles.addAll(files);
          _lastError = null;
        });
      },
      onError: (error, stackTrace) {
        if (mounted) {
          setState(() => _lastError = error);
        }
      },
    );
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('macos_file_open_handler example')),
        body: Center(
          child: _lastError != null
              ? Text('Error: $_lastError')
              : _openedFiles.isEmpty
                  ? const Text('Open or drop a text file on the app icon.')
                  : ListView.builder(
                      itemCount: _openedFiles.length,
                      itemBuilder: (context, index) {
                        final file = _openedFiles[index];
                        return ListTile(
                          title: Text(file.name),
                          subtitle: Text(file.path),
                        );
                      },
                    ),
        ),
      ),
    );
  }
}
