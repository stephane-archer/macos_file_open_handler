import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_file_open_handler/macos_file_open_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _ChannelHarness harness;

  setUp(() {
    harness = _ChannelHarness();
  });

  tearDown(() async {
    await harness.dispose();
  });

  test('decodes files, Unicode, directories, and immutable batches', () async {
    final received = Completer<List<MacosOpenedFile>>();
    final subscription = harness.handler.listen((files) async {
      received.complete(files);
    });
    await harness.waitUntilListening();

    await harness.emit(
      _batch('batch-1', <Map<String, String>>[
        _file('/tmp/My Video.mov'),
        _file('/tmp/Café Library.fcpbundle'),
      ]),
    );

    final files = await received.future;
    expect(files, <MacosOpenedFile>[
      MacosOpenedFile(
        name: 'My Video.mov',
        path: '/tmp/My Video.mov',
        uri: Uri.file('/tmp/My Video.mov'),
      ),
      MacosOpenedFile(
        name: 'Café Library.fcpbundle',
        path: '/tmp/Café Library.fcpbundle',
        uri: Uri.file('/tmp/Café Library.fcpbundle'),
      ),
    ]);
    expect(
      () => files.add(
        MacosOpenedFile(
          name: 'extra.mov',
          path: '/tmp/extra.mov',
          uri: Uri.file('/tmp/extra.mov'),
        ),
      ),
      throwsUnsupportedError,
    );
    await harness.waitForReleaseCount(1);
    expect(harness.releasedBatchIDs, <String>['batch-1']);
    await subscription.cancel();
  });

  test('waits for the callback before releasing native access', () async {
    final callbackStarted = Completer<void>();
    final finishCallback = Completer<void>();
    final subscription = harness.handler.listen((files) async {
      callbackStarted.complete();
      await finishCallback.future;
    });
    await harness.waitUntilListening();

    await harness.emit(
      _batch('held', <Map<String, String>>[_file('/tmp/held.mov')]),
    );
    await callbackStarted.future;
    expect(harness.releasedBatchIDs, isEmpty);

    finishCallback.complete();
    await harness.waitForReleaseCount(1);
    expect(harness.releasedBatchIDs, <String>['held']);
    await subscription.cancel();
  });

  test('processes batches serially in arrival order', () async {
    final firstStarted = Completer<void>();
    final finishFirst = Completer<void>();
    final secondFinished = Completer<void>();
    final callbacks = <String>[];
    final subscription = harness.handler.listen((files) async {
      final name = files.single.name;
      callbacks.add(name);
      if (name == 'first.mov') {
        firstStarted.complete();
        await finishFirst.future;
      } else {
        secondFinished.complete();
      }
    });
    await harness.waitUntilListening();

    await harness.emit(
      _batch('first', <Map<String, String>>[_file('/tmp/first.mov')]),
    );
    await firstStarted.future;
    await harness.emit(
      _batch('second', <Map<String, String>>[_file('/tmp/second.mov')]),
    );
    await Future<void>.delayed(Duration.zero);
    expect(callbacks, <String>['first.mov']);

    finishFirst.complete();
    await secondFinished.future;
    await harness.waitForReleaseCount(2);
    expect(callbacks, <String>['first.mov', 'second.mov']);
    expect(harness.releasedBatchIDs, <String>['first', 'second']);
    await subscription.cancel();
  });

  test('releases failed callbacks, reports the error, and continues', () async {
    final errors = <Object>[];
    final secondFinished = Completer<void>();
    final subscription = harness.handler.listen(
      (files) async {
        if (files.single.name == 'broken.mov') {
          throw StateError('cannot import');
        }
        secondFinished.complete();
      },
      onError: (error, stackTrace) {
        errors.add(error);
      },
    );
    await harness.waitUntilListening();

    await harness.emit(
      _batch('broken', <Map<String, String>>[_file('/tmp/broken.mov')]),
    );
    await harness.emit(
      _batch('working', <Map<String, String>>[_file('/tmp/working.mov')]),
    );

    await secondFinished.future;
    await harness.waitForReleaseCount(2);
    expect(errors.single, isA<StateError>());
    expect(harness.releasedBatchIDs, <String>['broken', 'working']);
    await subscription.cancel();
  });

  test('reports platform-stream errors and continues', () async {
    final errorReceived = Completer<Object>();
    final callbackFinished = Completer<void>();
    final subscription = harness.handler.listen(
      (files) async {
        callbackFinished.complete();
      },
      onError: (error, stackTrace) {
        errorReceived.complete(error);
      },
    );
    await harness.waitUntilListening();

    await harness.emitError(
      code: 'StreamFailure',
      message: 'The native event stream failed.',
    );
    expect(await errorReceived.future, isA<PlatformException>());

    await harness.emit(
      _batch('after-error', <Map<String, String>>[
        _file('/tmp/after-error.mov'),
      ]),
    );
    await callbackFinished.future;
    await harness.waitForReleaseCount(1);
    expect(harness.releasedBatchIDs, <String>['after-error']);
    await subscription.cancel();
  });

  test('reports errors to the listener zone when onError is omitted', () async {
    final errorReceived = Completer<Object>();
    final subscription = runZonedGuarded<MacosFileOpenSubscription>(
      () => harness.handler.listen((files) async {
        throw StateError('cannot import');
      }),
      (error, stackTrace) {
        errorReceived.complete(error);
      },
    )!;
    addTearDown(subscription.cancel);
    await harness.waitUntilListening();

    await harness.emit(
      _batch('zone-error', <Map<String, String>>[_file('/tmp/zone-error.mov')]),
    );

    expect(await errorReceived.future, isA<StateError>());
    await harness.waitForReleaseCount(1);
    expect(harness.releasedBatchIDs, <String>['zone-error']);
  });

  test(
    'reports malformed messages and releases identifiable batches',
    () async {
      final errorReceived = Completer<Object>();
      final subscription = harness.handler.listen(
        (files) async {},
        onError: (error, stackTrace) {
          if (!errorReceived.isCompleted) {
            errorReceived.complete(error);
          }
        },
      );
      await harness.waitUntilListening();

      await harness.emit(<String, Object?>{
        'batchId': 'malformed',
        'files': <Object?>[
          <String, Object?>{
            'name': 'not-a-file',
            'path': '/tmp/not-a-file',
            'uri': 'https://example.com/not-a-file',
          },
        ],
      });

      expect(await errorReceived.future, isA<FormatException>());
      await harness.waitForReleaseCount(1);
      expect(harness.releasedBatchIDs, <String>['malformed']);
      await subscription.cancel();
    },
  );

  test('allows one listener and allows another after cancellation', () async {
    final first = harness.handler.listen((files) async {});
    expect(() => harness.handler.listen((files) async {}), throwsStateError);
    await first.cancel();

    final second = harness.handler.listen((files) async {});
    await second.cancel();
  });

  test('cancellation waits for the in-flight callback and release', () async {
    final callbackStarted = Completer<void>();
    final finishCallback = Completer<void>();
    final subscription = harness.handler.listen((files) async {
      callbackStarted.complete();
      await finishCallback.future;
    });
    await harness.waitUntilListening();
    await harness.emit(
      _batch('in-flight', <Map<String, String>>[_file('/tmp/in-flight.mov')]),
    );
    await callbackStarted.future;

    var cancelled = false;
    final cancellation = subscription.cancel().then((_) => cancelled = true);
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, isFalse);
    expect(harness.cancelCalls, 0);

    finishCallback.complete();
    await cancellation;
    expect(harness.releasedBatchIDs, <String>['in-flight']);
    expect(harness.cancelCalls, 1);
    await subscription.cancel();
    expect(harness.cancelCalls, 1);
  });

  test('cancellation can be awaited from inside the callback', () async {
    final callbackCancelled = Completer<void>();
    final finishCallback = Completer<void>();
    var callbackCount = 0;
    late final MacosFileOpenSubscription subscription;
    subscription = harness.handler.listen((files) async {
      callbackCount++;
      await subscription.cancel();
      callbackCancelled.complete();
      await finishCallback.future;
    });
    await harness.waitUntilListening();

    await harness.emit(
      _batch('one-shot', <Map<String, String>>[_file('/tmp/one-shot.mov')]),
    );

    await callbackCancelled.future.timeout(const Duration(seconds: 1));
    var externallyCancelled = false;
    final externalCancellation = subscription.cancel().then(
          (_) => externallyCancelled = true,
        );
    await Future<void>.delayed(Duration.zero);
    expect(externallyCancelled, isFalse);
    expect(harness.releasedBatchIDs, isEmpty);
    expect(harness.cancelCalls, 0);

    finishCallback.complete();
    await externalCancellation;
    expect(callbackCount, 1);
    expect(harness.releasedBatchIDs, <String>['one-shot']);
    expect(harness.cancelCalls, 1);
  });

  test('cancellation from an old callback zone waits for active work',
      () async {
    final allowOldTaskToCancel = Completer<void>();
    final oldTaskStartedCancellation = Completer<void>();
    final oldTaskFinishedCancellation = Completer<void>();
    final secondCallbackStarted = Completer<void>();
    final finishSecondCallback = Completer<void>();
    late final MacosFileOpenSubscription subscription;
    subscription = harness.handler.listen((files) async {
      if (files.single.name == 'first.mov') {
        unawaited(() async {
          await allowOldTaskToCancel.future;
          oldTaskStartedCancellation.complete();
          await subscription.cancel();
          oldTaskFinishedCancellation.complete();
        }());
        return;
      }
      secondCallbackStarted.complete();
      await finishSecondCallback.future;
    });
    await harness.waitUntilListening();

    await harness.emit(
      _batch('first', <Map<String, String>>[_file('/tmp/first.mov')]),
    );
    await harness.waitForReleaseCount(1);
    await harness.emit(
      _batch('second', <Map<String, String>>[_file('/tmp/second.mov')]),
    );
    await secondCallbackStarted.future;

    allowOldTaskToCancel.complete();
    await oldTaskStartedCancellation.future;
    await Future<void>.delayed(Duration.zero);
    expect(oldTaskFinishedCancellation.isCompleted, isFalse);
    expect(harness.cancelCalls, 0);

    finishSecondCallback.complete();
    await oldTaskFinishedCancellation.future;
    expect(harness.releasedBatchIDs, <String>['first', 'second']);
    expect(harness.cancelCalls, 1);
  });

  test('retries a transient native release failure', () async {
    final errors = <Object>[];
    harness.releaseFailuresRemaining = 1;
    final subscription = harness.handler.listen(
      (files) async {},
      onError: (error, stackTrace) => errors.add(error),
    );
    await harness.waitUntilListening();

    await harness.emit(
      _batch('retried', <Map<String, String>>[_file('/tmp/retried.mov')]),
    );
    await harness.waitForReleaseCount(1);

    expect(harness.releaseAttempts, 2);
    expect(harness.releasedBatchIDs, <String>['retried']);
    expect(errors, isEmpty);
    await subscription.cancel();
  });

  test('reports an exhausted release and retries it with the next batch',
      () async {
    final errorReceived = Completer<Object>();
    final secondFinished = Completer<void>();
    harness.releaseFailuresRemaining = 2;
    final subscription = harness.handler.listen(
      (files) async {
        if (files.single.name == 'second.mov') {
          secondFinished.complete();
        }
      },
      onError: (error, stackTrace) {
        if (!errorReceived.isCompleted) {
          errorReceived.complete(error);
        }
      },
    );
    await harness.waitUntilListening();

    await harness.emit(
      _batch('failed-release', <Map<String, String>>[_file('/tmp/first.mov')]),
    );
    expect(await errorReceived.future, isA<PlatformException>());
    expect(harness.releaseAttempts, 2);
    expect(harness.releasedBatchIDs, isEmpty);

    await harness.emit(
      _batch('released', <Map<String, String>>[_file('/tmp/second.mov')]),
    );
    await secondFinished.future;
    await harness.waitForReleaseCount(2);
    expect(harness.releaseAttempts, 4);
    expect(harness.releasedBatchIDs, <String>['failed-release', 'released']);
    await subscription.cancel();
  });

  test('bounds permanently failing releases to three attempts per batch',
      () async {
    final errors = <Object>[];
    final callbacksFinished = Completer<void>();
    var callbackCount = 0;
    harness.releaseFailuresRemaining = 100;
    final subscription = harness.handler.listen(
      (files) async {
        callbackCount++;
        if (callbackCount == 3) {
          callbacksFinished.complete();
        }
      },
      onError: (error, stackTrace) => errors.add(error),
    );
    await harness.waitUntilListening();

    for (var index = 0; index < 3; index++) {
      await harness.emit(
        _batch(
          'permanent-$index',
          <Map<String, String>>[_file('/tmp/permanent-$index.mov')],
        ),
      );
    }
    await callbacksFinished.future;
    await subscription.cancel();

    expect(harness.releaseAttempts, 9);
    expect(harness.releasedBatchIDs, isEmpty);
    expect(errors, hasLength(6));
  });
}

Map<String, Object?> _batch(String batchID, List<Map<String, String>> files) {
  return <String, Object?>{'batchId': batchID, 'files': files};
}

Map<String, String> _file(String path) {
  return <String, String>{
    'name': Uri.file(path).pathSegments.last,
    'path': path,
    'uri': Uri.file(path).toString(),
  };
}

final class _ChannelHarness {
  _ChannelHarness()
      : suffix = _nextSuffix++,
        _listening = Completer<void>() {
    methodChannel = MethodChannel('macos_file_open_handler/test/$suffix');
    eventChannel = EventChannel('macos_file_open_handler/test_events/$suffix');
    handler = MacosFileOpenHandler.withChannels(
      methodChannel: methodChannel,
      eventChannel: eventChannel,
    );

    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      if (call.method == 'releaseBatch') {
        releaseAttempts++;
        if (releaseFailuresRemaining > 0) {
          releaseFailuresRemaining--;
          throw PlatformException(
            code: 'TransientReleaseFailure',
            message: 'Could not release the native batch.',
          );
        }
        final arguments = call.arguments as Map<Object?, Object?>;
        releasedBatchIDs.add(arguments['batchId']! as String);
        _notifyReleaseWaiters();
        return null;
      }
      throw MissingPluginException('Unexpected method ${call.method}');
    });
    messenger.setMockMethodCallHandler(MethodChannel(eventChannel.name), (
      call,
    ) async {
      if (call.method == 'listen') {
        if (!_listening.isCompleted) {
          _listening.complete();
        }
      } else if (call.method == 'cancel') {
        cancelCalls++;
      }
      return null;
    });
  }

  static int _nextSuffix = 0;

  final int suffix;
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final StandardMethodCodec codec = const StandardMethodCodec();
  final List<String> releasedBatchIDs = <String>[];
  final List<Completer<void>> _releaseWaiters = <Completer<void>>[];
  final Completer<void> _listening;
  late final MethodChannel methodChannel;
  late final EventChannel eventChannel;
  late final MacosFileOpenHandler handler;
  int cancelCalls = 0;
  int releaseAttempts = 0;
  int releaseFailuresRemaining = 0;

  Future<void> waitUntilListening() => _listening.future;

  Future<void> emit(Object? payload) async {
    final ByteData message = codec.encodeSuccessEnvelope(payload);
    await messenger.handlePlatformMessage(eventChannel.name, message, (_) {});
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> emitError({required String code, String? message}) async {
    final ByteData envelope = codec.encodeErrorEnvelope(
      code: code,
      message: message,
    );
    await messenger.handlePlatformMessage(eventChannel.name, envelope, (_) {});
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> waitForReleaseCount(int count) async {
    while (releasedBatchIDs.length < count) {
      final waiter = Completer<void>();
      _releaseWaiters.add(waiter);
      await waiter.future;
    }
  }

  Future<void> dispose() async {
    messenger.setMockMethodCallHandler(methodChannel, null);
    messenger.setMockMethodCallHandler(MethodChannel(eventChannel.name), null);
  }

  void _notifyReleaseWaiters() {
    for (final waiter in _releaseWaiters) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
    _releaseWaiters.clear();
  }
}
