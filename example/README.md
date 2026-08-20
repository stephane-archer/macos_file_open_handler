# macos_file_open_handler_example

Demonstrates cold- and warm-start file-open delivery with
`macos_file_open_handler`.

Run the app on macOS, then open a text file with Finder, pass one with
`open -a`, or drop one on the running app's Dock icon. The example lists each
received file name and path.

```shell
flutter run -d macos
```

The example's `Info.plist` declares `public.text`, and both entitlement files
grant read-only access to user-selected files.

The regular integration test verifies native buffering before Dart starts
listening. To exercise a true cold launch, including Launch Services starting a
fresh application process with a document, run from the package root in a
repository checkout (the repository-only `tool/` directory is not included in
the published package):

```shell
dart run tool/test_cold_start.dart
```
