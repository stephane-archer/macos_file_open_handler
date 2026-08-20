# macos_file_open_handler

Reliably process files opened through Finder, Dock-icon drops, or `open -a` in
a Flutter macOS app.

This plugin is designed for applications that do more than observe a path.
It buffers requests that arrive before Dart starts listening, preserves every
macOS request as one batch, and waits for your asynchronous callback before it
delivers the next batch.

## When to use this package

Use `macos_file_open_handler` when one or more of these guarantees matter:

- A file that launched the app must not be lost while Flutter is starting.
- Files opened together must reach Dart together as one immutable batch.
- Imports must run one at a time and in arrival order.
- Cancellation must wait for active work and native cleanup.
- Callback, decoding, channel, and cleanup failures need one error path.

This package is not required to obtain the initial macOS sandbox permission.
macOS grants a dynamic sandbox extension for files opened or dropped by the
user when the host has the appropriate user-selected-file entitlement. See
[Security scopes and persistent access](#security-scopes-and-persistent-access)
for the lifetime and bookmark details.

## Choosing between similar packages

These are the closest pub.dev packages as of August 20, 2026:

| Package | API model | Startup delivery | Multiple-file request | Async completion | macOS integration |
| --- | --- | --- | --- | --- | --- |
| `macos_file_open_handler` | One async batch callback | Buffered natively until Dart listens | Preserved | Awaited before the next batch and cleanup | Flutter lifecycle delegate |
| [`file_open`](https://pub.dev/packages/file_open) 0.1.0 | Broadcast `Stream<List<Uri>>` | Requires early initialization; its documentation warns that initial files may be missed | Preserved | Not acknowledged by the source stream | Runtime `AppDelegate` interception |
| [`file_open_handler`](https://pub.dev/packages/file_open_handler) 0.0.2 | Single-path getter and callback | Retains the last forwarded path | Not preserved | No batch completion contract | Manual host `AppDelegate` forwarding |

Choose this package when reliable startup delivery and serial, acknowledged
processing are more important than stream composition. Choose `file_open` when
you want a conventional broadcast stream, possibly with multiple listeners,
and your application owns its sequencing and file-access lifecycle. The older
`file_open_handler` is mainly relevant to an existing single-file integration
that already forwards its host `AppDelegate` callback.

A stream is not generally better or worse than a callback. A stream is a good
notification API, but its source does not await an `async` function passed to
`listen`. Here callback completion is part of the contract: it provides
backpressure and gives the plugin a deterministic cleanup boundary.

## Quick start

Add the package:

```console
flutter pub add macos_file_open_handler
```

Configure the document types and sandbox entitlement described in
[macOS setup](#macos-setup), then install one application-wide listener early
in the app lifecycle:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:macos_file_open_handler/macos_file_open_handler.dart';

late final MacosFileOpenSubscription fileOpenSubscription;

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  fileOpenSubscription = MacosFileOpenHandler.instance.listen(
    (files) async {
      for (final file in files) {
        await importFile(file);
      }
    },
    onError: (error, stackTrace) {
      debugPrint('Could not open file: $error');
    },
  );

  runApp(const MyApp());
}
```

`MacosOpenedFile` provides the file's `name`, absolute `path`, and original
file `uri`. Replace `importFile` with the operation your app needs. Await every
operation that uses an opened file:

```dart
import 'dart:io';

Future<void> importFile(MacosOpenedFile file) async {
  final bytes = await File.fromUri(file.uri).readAsBytes();
  await saveToLibrary(file.name, bytes);
}
```

For large files, copy or stream their contents instead of reading the entire
file into memory.

### Handle a multi-file request as one unit

The callback receives exactly one list for each operating-system request. You
can import that list in one transaction:

```dart
fileOpenSubscription = MacosFileOpenHandler.instance.listen(
  (files) async {
    await importTogether(files.map((file) => file.path).toList());
  },
);
```

### Own the listener from a widget

If a widget owns the listener instead of keeping it for the entire application
lifetime, cancel it during disposal:

```dart
import 'dart:async';

late final MacosFileOpenSubscription subscription;

@override
void initState() {
  super.initState();
  subscription = MacosFileOpenHandler.instance.listen(handleOpenedFiles);
}

@override
void dispose() {
  unawaited(subscription.cancel());
  super.dispose();
}
```

Only one listener can be active at a time. For an application-wide listener,
keep its subscription alive for the application lifetime.

## macOS setup

The host app chooses which files it accepts. Add `CFBundleDocumentTypes` to
`macos/Runner/Info.plist`; for example, to accept movie files:

```xml
<key>CFBundleDocumentTypes</key>
<array>
  <dict>
    <key>CFBundleTypeName</key>
    <string>Movie</string>
    <key>CFBundleTypeRole</key>
    <string>Viewer</string>
    <key>LSHandlerRank</key>
    <string>Alternate</string>
    <key>LSItemContentTypes</key>
    <array>
      <string>public.movie</string>
    </array>
  </dict>
</array>
```

Sandboxed apps must also declare the access they need in both Debug/Profile and
Release entitlements:

```xml
<key>com.apple.security.files.user-selected.read-only</key>
<true/>
```

Use `com.apple.security.files.user-selected.read-write` instead when the app
modifies opened files. File extensions, Uniform Type Identifiers, and sandbox
permissions are intentionally host-app configuration because they differ per
consumer.

The plugin supports macOS 10.15 or newer and includes both CocoaPods and Swift
Package Manager integration. Flutter 3.16 or newer is required because that
release added the macOS application lifecycle forwarding used to receive file
open events in plugins.

## Delivery and cleanup behavior

### Ordering and errors

Requests are processed serially in arrival order. A slow callback delays later
batches, so keep callbacks bounded and await only work that must finish before
the next request begins.

Callback, malformed-event, event-stream, and native-release errors are sent to
`onError`. If `onError` is omitted, they are reported as uncaught errors in the
zone that installed the listener. A failed callback does not prevent later
batches from being processed.

### Cancellation

Awaiting `subscription.cancel()` waits for an active callback and its native
cleanup before detaching the listener. It is also safe to await cancellation
from inside the callback; the request takes effect immediately and cleanup
finishes after the callback returns. Install a replacement listener only after
the previous callback and cancellation have completed.

Native batch release is idempotent. The Dart handler retries a failed release
and cancellation asks native code to release every batch it still retains.

### Security scopes and persistent access

macOS automatically extends a sandbox for files opened or dropped through
standard user interactions. This initial access comes from macOS, not from
this package. See Apple's
[App Sandbox documentation](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox).

The plugin additionally calls `startAccessingSecurityScopedResource()` for
each received file URL. When that call succeeds, it retains the original URL
until your callback finishes and balances its call in a `finally` path, even
if the callback throws. It does not claim to revoke or control the separate
dynamic sandbox extension granted by macOS.

Do not start unawaited file work inside the callback: it may continue after the
plugin's explicitly started scope has been stopped. If the app only copies the
file into its own container, no bookmark is needed after that copy completes.
To access the original file in a future launch, create and store a
security-scoped bookmark in native macOS code. Bookmark creation and resolution
are not part of this package's current API.

### Coexistence with URL handlers

Non-file URLs are ignored so URL-scheme plugins can handle them. For a mixed
batch of file and non-file URLs, this plugin processes the files but leaves the
callback unclaimed so Flutter can continue to later lifecycle delegates. A
later delegate should filter file URLs to avoid processing them twice.
