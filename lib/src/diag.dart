import 'dart:io' show File, FileMode, Platform;

/// Optional file diagnostics: `--dart-define=SONIC_DIAG=/path/to/log`.
/// Appends timestamped lines so behavior can be verified when the app is
/// launched via `open` (stdout detached).
const String kSonicDiagPath =
    String.fromEnvironment('SONIC_DIAG', defaultValue: '');

void sonicDiag(String message) {
  if (kSonicDiagPath.isEmpty) return;
  try {
    final f = File(kSonicDiagPath)
      ..createSync(recursive: true)
      ..writeAsStringSync(
          '${DateTime.now().toIso8601String()} | $message\n',
          mode: FileMode.append);
    // Touch to silence unused warnings in release paths.
    f.lengthSync();
  } catch (_) {}
}

bool get kSonicIsMacOS {
  try {
    return Platform.isMacOS;
  } catch (_) {
    return false;
  }
}
