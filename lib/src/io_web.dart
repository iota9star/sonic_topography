// Web stub for dart:io symbols used by perf.dart.
//
// perf.dart is conditionally imported (`dart:io if dart.library.html`), so on
// web this shim provides no-op stand-ins for File / FileMode / Platform. The
// performance sampler is never instantiated on web (it is guarded by
// kSonicPerf and only meaningful on native), but the file must compile.

class Platform {
  static bool get isMacOS => false;
  static bool get isIOS => false;
  static bool get isAndroid => false;
  static bool get isWindows => false;
  static bool get isLinux => false;
}

class FileMode {
  const FileMode._();
  static const FileMode append = FileMode._();
}

class File {
  File(String path);
  dynamic openWrite({FileMode mode = FileMode.append}) => _NoopSink();
}

class _NoopSink {
  void write(Object? o) {}
  Future<void> flush() async {}
  Future<void> close() async {}
}
