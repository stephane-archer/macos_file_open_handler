import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:macos_file_open_handler/macos_file_open_handler.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native channels support release and listener reconnection', (
    tester,
  ) async {
    const channel = MethodChannel('macos_file_open_handler');
    await channel.invokeMethod<void>('releaseBatch', <String, Object?>{
      'batchId': 'unknown-integration-batch',
    });

    final first = MacosFileOpenHandler.instance.listen((files) async {});
    expect(
      () => MacosFileOpenHandler.instance.listen((files) async {}),
      throwsStateError,
    );
    await first.cancel();

    final second = MacosFileOpenHandler.instance.listen((files) async {});
    await second.cancel();
  });

  testWidgets('buffers Launch Services events until Dart listens', (
    tester,
  ) async {
    final fixtureDirectory = await Directory.systemTemp.createTemp(
      'macos_file_open_handler_',
    );
    final queuedFile = File('${fixtureDirectory.path}/before listener.txt');
    final warmFile = File('${fixtureDirectory.path}/warm start.txt');
    await queuedFile.writeAsString('queued');
    await warmFile.writeAsString('warm');

    final executable = File(Platform.resolvedExecutable);
    final applicationBundle = executable.parent.parent.parent.path;
    MacosFileOpenSubscription? subscription;
    try {
      await _openWithLaunchServices(applicationBundle, queuedFile.path);
      await Future<void>.delayed(const Duration(milliseconds: 250));

      final receivedPaths = <String>[];
      final receivedBoth = Completer<void>();
      subscription = MacosFileOpenHandler.instance.listen((files) async {
        receivedPaths.addAll(files.map((file) => file.path));
        for (final file in files) {
          expect(await File(file.path).readAsString(), isNotEmpty);
        }
        if (receivedPaths.contains(queuedFile.path) &&
            receivedPaths.contains(warmFile.path) &&
            !receivedBoth.isCompleted) {
          receivedBoth.complete();
        }
      });

      await _openWithLaunchServices(applicationBundle, warmFile.path);
      await receivedBoth.future.timeout(const Duration(seconds: 10));
      expect(
          receivedPaths,
          containsAllInOrder(<String>[
            queuedFile.path,
            warmFile.path,
          ]));
    } finally {
      await subscription?.cancel();
      await fixtureDirectory.delete(recursive: true);
    }
  });
}

Future<void> _openWithLaunchServices(String application, String file) async {
  await Process.start(
    '/usr/bin/open',
    <String>['-g', '-a', application, file],
    mode: ProcessStartMode.detached,
  ).timeout(const Duration(seconds: 5));
}
