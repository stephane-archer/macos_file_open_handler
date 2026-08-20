import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

final Object _callbackZoneKey = Object();

_NativeFileOpenBatch _decodeBatch(dynamic payload) {
  if (payload is! Map) {
    throw const FormatException('Expected a file-open event map.');
  }
  final batchID = payload['batchId'];
  final rawFiles = payload['files'];
  if (batchID is! String || batchID.isEmpty) {
    throw const FormatException('Expected a non-empty batchId.');
  }
  if (rawFiles is! List || rawFiles.isEmpty) {
    throw const FormatException('Expected a non-empty files list.');
  }

  final files = rawFiles.map<MacosOpenedFile>((dynamic rawFile) {
    if (rawFile is! Map) {
      throw const FormatException('Expected each opened file to be a map.');
    }
    final name = rawFile['name'];
    final path = rawFile['path'];
    final rawURI = rawFile['uri'];
    if (name is! String || name.isEmpty) {
      throw const FormatException('Expected a non-empty file name.');
    }
    if (path is! String || path.isEmpty) {
      throw const FormatException('Expected a non-empty file path.');
    }
    if (rawURI is! String || rawURI.isEmpty) {
      throw const FormatException('Expected a non-empty file URI.');
    }
    final uri = Uri.tryParse(rawURI);
    if (uri == null || !uri.isScheme('file')) {
      throw const FormatException('Expected a valid file URI.');
    }
    return MacosOpenedFile(name: name, path: path, uri: uri);
  }).toList(growable: false);

  return _NativeFileOpenBatch(
    id: batchID,
    files: List<MacosOpenedFile>.unmodifiable(files),
  );
}

String? _readBatchID(dynamic payload) {
  if (payload is Map) {
    final batchID = payload['batchId'];
    if (batchID is String && batchID.isNotEmpty) {
      return batchID;
    }
  }
  return null;
}

/// Handles a batch of files opened through macOS.
typedef MacosFileOpenCallback = Future<void> Function(
    List<MacosOpenedFile> files);

/// Receives callback, event-stream, decoding, and native-release errors.
typedef MacosFileOpenErrorCallback = void Function(
    Object error, StackTrace stackTrace);

/// Receives files opened through Finder, Dock drops, or `open -a` on macOS.
///
/// The native plugin attempts to start security-scoped access for each opened
/// file URL. Every successful start is kept active for the duration of the
/// asynchronous callback and balanced automatically afterwards.
final class MacosFileOpenHandler {
  /// The shared application-wide handler.
  static final MacosFileOpenHandler instance = MacosFileOpenHandler._(
    methodChannel: const MethodChannel('macos_file_open_handler'),
    eventChannel: const EventChannel('macos_file_open_handler/events'),
  );

  final MethodChannel _methodChannel;

  final EventChannel _eventChannel;

  _MacosFileOpenListener? _activeListener;

  /// Creates a handler backed by custom channels for tests.
  @visibleForTesting
  factory MacosFileOpenHandler.withChannels({
    required MethodChannel methodChannel,
    required EventChannel eventChannel,
  }) {
    return MacosFileOpenHandler._(
      methodChannel: methodChannel,
      eventChannel: eventChannel,
    );
  }
  MacosFileOpenHandler._({
    required MethodChannel methodChannel,
    required EventChannel eventChannel,
  })  : _methodChannel = methodChannel,
        _eventChannel = eventChannel;

  /// Starts listening for file-open batches.
  ///
  /// Batches are delivered serially in arrival order. Any security-scoped
  /// access successfully started by the native plugin remains active until
  /// [callback] completes and is then balanced even when the callback throws.
  /// Only one listener may be active at a time. When [onError] is omitted,
  /// errors are reported as uncaught errors in the zone that called [listen].
  MacosFileOpenSubscription listen(
    MacosFileOpenCallback callback, {
    MacosFileOpenErrorCallback? onError,
  }) {
    if (_activeListener != null) {
      throw StateError(
        'macos_file_open_handler already has an active listener.',
      );
    }

    late final _MacosFileOpenListener listener;
    listener = _MacosFileOpenListener(
      methodChannel: _methodChannel,
      eventChannel: _eventChannel,
      callback: callback,
      onError: onError,
      zone: Zone.current,
      onCancelled: () {
        if (identical(_activeListener, listener)) {
          _activeListener = null;
        }
      },
    );
    _activeListener = listener;
    try {
      listener.start();
    } catch (_) {
      _activeListener = null;
      rethrow;
    }
    return MacosFileOpenSubscription._(listener.cancel);
  }
}

/// A cancellable file-open listener.
final class MacosFileOpenSubscription {
  final Future<void> Function() _cancelCallback;

  MacosFileOpenSubscription._(this._cancelCallback);

  /// Stops receiving new events after the current callback and its native
  /// security-scope balancing have completed. When awaited by the active
  /// callback itself, cancellation is requested immediately and this returns
  /// without waiting for that callback to finish.
  Future<void> cancel() {
    return _cancelCallback();
  }
}

/// A file passed to the application by macOS.
@immutable
final class MacosOpenedFile {
  /// The final path component supplied by macOS.
  final String name;

  /// The absolute filesystem path supplied by macOS.
  final String path;

  /// The original file URI supplied by macOS.
  final Uri uri;

  /// Creates an immutable description of an opened file.
  const MacosOpenedFile({
    required this.name,
    required this.path,
    required this.uri,
  });

  @override
  int get hashCode => Object.hash(name, path, uri);

  @override
  bool operator ==(Object other) {
    return other is MacosOpenedFile &&
        other.name == name &&
        other.path == path &&
        other.uri == uri;
  }

  @override
  String toString() {
    return 'MacosOpenedFile(name: $name, path: $path, uri: $uri)';
  }
}

final class _MacosFileOpenListener {
  final MethodChannel methodChannel;

  final EventChannel eventChannel;
  final MacosFileOpenCallback callback;
  final MacosFileOpenErrorCallback? onError;
  final Zone zone;
  final VoidCallback onCancelled;
  final Queue<_NativeFileOpenBatch> _queue = Queue<_NativeFileOpenBatch>();
  final Set<String> _deferredReleaseBatchIDs = <String>{};
  StreamSubscription<dynamic>? _platformSubscription;

  Future<void>? _drainFuture;
  Future<void>? _cancelFuture;
  Future<void> _releaseSerial = Future<void>.value();
  Object? _activeCallbackToken;
  bool _cancelRequested = false;
  _MacosFileOpenListener({
    required this.methodChannel,
    required this.eventChannel,
    required this.callback,
    required this.onError,
    required this.zone,
    required this.onCancelled,
  });

  Future<void> cancel() {
    final cancellation = _cancelFuture ??= _cancel();
    // Waiting here from inside [callback] would deadlock: cancellation waits
    // for the active drain, while the drain is waiting for the callback. The
    // request has already been applied synchronously by [_cancel], so let the
    // callback return and allow cleanup to finish afterwards.
    final callbackToken = Zone.current[_callbackZoneKey];
    if (callbackToken != null &&
        identical(callbackToken, _activeCallbackToken)) {
      return Future<void>.value();
    }
    return cancellation;
  }

  void start() {
    _platformSubscription = eventChannel.receiveBroadcastStream().listen(
      _onPlatformEvent,
      onError: (Object error, StackTrace stackTrace) {
        _reportError(error, stackTrace);
      },
    );
  }

  Future<void> _cancel() async {
    _cancelRequested = true;
    _platformSubscription?.pause();

    try {
      final drainFuture = _drainFuture;
      if (drainFuture != null) {
        await drainFuture;
      }
      while (_queue.isNotEmpty) {
        await _releaseBatch(_queue.removeFirst().id);
      }
      final finalRelease = _releaseSerial.then(
        (_) => _retryDeferredReleases(),
      );
      _releaseSerial = finalRelease;
      await finalRelease;
    } finally {
      try {
        // Native onCancel releases every retained batch, including any whose
        // Dart-side acknowledgement or earlier cleanup failed.
        await _platformSubscription?.cancel();
      } finally {
        _deferredReleaseBatchIDs.clear();
        onCancelled();
      }
    }
  }

  Future<void> _drain() async {
    while (_queue.isNotEmpty && !_cancelRequested) {
      final batch = _queue.removeFirst();
      Object? callbackError;
      StackTrace? callbackStackTrace;
      final callbackToken = Object();
      _activeCallbackToken = callbackToken;
      try {
        await zone.fork(
          zoneValues: <Object?, Object?>{
            _callbackZoneKey: callbackToken,
          },
        ).run<Future<void>>(() => callback(batch.files));
      } catch (error, stackTrace) {
        callbackError = error;
        callbackStackTrace = stackTrace;
      } finally {
        _activeCallbackToken = null;
        await _releaseBatch(batch.id);
      }
      if (callbackError != null) {
        _reportError(callbackError, callbackStackTrace!);
      }
    }
  }

  Future<void> _invokeRelease(String batchID) {
    return methodChannel.invokeMethod<void>(
      'releaseBatch',
      <String, Object?>{'batchId': batchID},
    );
  }

  void _onPlatformEvent(dynamic payload) {
    _NativeFileOpenBatch batch;
    try {
      batch = _decodeBatch(payload);
    } catch (error, stackTrace) {
      final batchID = _readBatchID(payload);
      if (batchID != null) {
        unawaited(_releaseBatch(batchID));
      }
      _reportError(error, stackTrace);
      return;
    }

    if (_cancelRequested) {
      unawaited(_releaseBatch(batch.id));
      return;
    }
    _queue.addLast(batch);
    _startDrainIfNeeded();
  }

  Future<void> _releaseBatch(String batchID) async {
    final release = _releaseSerial.then((_) async {
      await _retryDeferredReleases(excluding: batchID);
      await _releaseNewBatch(batchID);
    });
    _releaseSerial = release;
    await release;
  }

  Future<void> _releaseNewBatch(String batchID) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await _invokeRelease(batchID);
        return;
      } catch (error, stackTrace) {
        if (attempt == 1) {
          _deferredReleaseBatchIDs.add(batchID);
          _reportError(error, stackTrace);
        }
      }
    }
  }

  void _reportError(Object error, StackTrace stackTrace) {
    final errorCallback = onError;
    if (errorCallback == null) {
      zone.handleUncaughtError(error, stackTrace);
      return;
    }
    zone.runBinaryGuarded<Object, StackTrace>(errorCallback, error, stackTrace);
  }

  Future<void> _retryDeferredReleases({String? excluding}) async {
    final deferred = List<String>.of(_deferredReleaseBatchIDs);
    for (final batchID in deferred) {
      if (batchID == excluding) {
        continue;
      }
      _deferredReleaseBatchIDs.remove(batchID);
      try {
        await _invokeRelease(batchID);
      } catch (error, stackTrace) {
        // This is the final Dart-side attempt. Native onCancel retains ownership
        // and releases the batch if the acknowledgement remains unavailable.
        _reportError(error, stackTrace);
      }
    }
  }

  void _startDrainIfNeeded() {
    if (_drainFuture != null || _queue.isEmpty || _cancelRequested) {
      return;
    }
    // Register the drain before it can invoke a callback. A callback may cancel
    // its own subscription synchronously, and cancellation must still see and
    // wait for this active drain.
    final drainFuture = Future<void>.microtask(_drain);
    _drainFuture = drainFuture;
    unawaited(
      drainFuture.whenComplete(() {
        _drainFuture = null;
        _startDrainIfNeeded();
      }),
    );
  }
}

final class _NativeFileOpenBatch {
  final String id;

  final List<MacosOpenedFile> files;
  const _NativeFileOpenBatch({required this.id, required this.files});
}
