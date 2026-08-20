import 'dart:async';
import 'dart:io';

Future<void> main() async {
  if (!Platform.isMacOS) {
    stderr.writeln('The cold-start test requires macOS.');
    exitCode = 64;
    return;
  }

  final fixtureDirectory = await Directory.systemTemp.createTemp(
    'macos_file_open_handler_cold_start_',
  );
  try {
    final openedFile = File('${fixtureDirectory.path}/cold launch.txt');
    final userHome = Platform.environment['HOME'];
    if (userHome == null) {
      throw StateError('HOME is unavailable.');
    }
    final containerTemporaryDirectory = Directory(
      '$userHome/Library/Containers/'
      'com.fractale.macosFileOpenHandlerExample/Data/tmp',
    );
    await containerTemporaryDirectory.create(recursive: true);
    final resultFile = File(
      '${containerTemporaryDirectory.path}/macos_file_open_handler_cold_start.txt',
    );
    if (await resultFile.exists()) {
      await resultFile.delete();
    }
    await openedFile.writeAsString('cold launch');

    final build = await Process.start(
      'flutter',
      <String>[
        'build',
        'macos',
        '--debug',
        '--dart-define=MACOS_FILE_OPEN_HANDLER_COLD_START_OUTPUT=${resultFile.path}',
      ],
      workingDirectory: 'example',
      mode: ProcessStartMode.inheritStdio,
    );
    final buildExitCode = await build.exitCode;
    if (buildExitCode != 0) {
      throw const ProcessException('flutter', <String>['build', 'macos']);
    }

    final products = Directory('example/build/macos/Build/Products/Debug');
    final applications = await products
        .list()
        .where((entry) => entry is Directory && entry.path.endsWith('.app'))
        .cast<Directory>()
        .toList();
    if (applications.length != 1) {
      throw StateError(
        'Expected one application bundle in ${products.path}, found '
        '${applications.length}.',
      );
    }

    final launch = await Process.start('/usr/bin/open', <String>[
      '-n',
      '-W',
      '-g',
      '-a',
      applications.single.absolute.path,
      openedFile.absolute.path,
    ]);
    final launchExitCode = await launch.exitCode.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        launch.kill();
        final runningApplication = Process.runSync(
          '/usr/bin/pgrep',
          const <String>['-n', '-x', 'macos_file_open_handler_example'],
        );
        final applicationPID = int.tryParse(
          runningApplication.stdout.toString().trim().split('\n').last,
        );
        if (applicationPID != null) {
          Process.killPid(applicationPID);
        }
        throw TimeoutException('The cold-launched application did not exit.');
      },
    );
    if (launchExitCode != 0) {
      throw ProcessException(
          '/usr/bin/open', const <String>[], '', launchExitCode);
    }

    final openedPath = await openedFile.resolveSymbolicLinks();
    final receivedPaths = await resultFile.readAsLines();
    final resolvedReceivedPaths = await Future.wait(
      receivedPaths.map((path) => File(path).resolveSymbolicLinks()),
    );
    if (!resolvedReceivedPaths.contains(openedPath)) {
      throw StateError(
        'Cold launch did not deliver $openedPath. '
        'Received: $receivedPaths',
      );
    }
    stdout.writeln('Cold-start file-open test passed.');
    if (await resultFile.exists()) {
      await resultFile.delete();
    }
  } finally {
    await fixtureDirectory.delete(recursive: true);
  }
}
