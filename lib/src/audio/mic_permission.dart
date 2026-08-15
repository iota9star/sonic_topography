import 'dart:io' show Process;

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Thrown when the microphone permission cannot be obtained.
///
/// [permanent] distinguishes a recoverable denial (can ask again) from a
/// "Don't ask again" denial which requires opening system settings.
class MicPermissionException implements Exception {
  final String message;
  final bool permanent;

  const MicPermissionException(this.message, {required this.permanent});

  @override
  String toString() =>
      'MicPermissionException($message, permanent: $permanent)';
}

/// Outcome of a microphone permission request.
enum MicPermissionResult {
  /// Granted — safe to start capturing audio.
  granted,

  /// Denied this session but can be asked again.
  denied,

  /// Permanently denied (e.g. "Don't ask again"). The app must send the user
  /// to system settings via [MicPermission.openSettings].
  permanentlyDenied,

  /// The platform's permission model cannot be queried through
  /// `permission_handler`. Callers should attempt capture directly and let the
  /// host OS / browser surface its native prompt; treat capture failure as a
  /// denial.
  unsupported,
}

/// Normalized microphone permission flow across every Flutter target.
///
/// Strategy:
/// * **Android / iOS**: `permission_handler` drives a real
///   request/deny/permanentlyDenied state machine.
/// * **macOS / Windows / Linux / Web**: the permission_handler plugin either
///   doesn't implement the microphone group or only reports status (no
///   prompt). The OS / browser itself prompts the first time audio capture is
///   attempted, so we return [MicPermissionResult.unsupported] and let the
///   recorder run. Any capture failure is then mapped to a denial by
///   [MicPermission.classifyCaptureError].
class MicPermission {
  MicPermission._();

  /// Request microphone access, returning a normalized result.
  static Future<MicPermissionResult> request() async {
    if (_usesPermissionHandler) {
      final status = await Permission.microphone.request();
      return _map(status);
    }
    return MicPermissionResult.unsupported;
  }

  /// Check the current status without prompting.
  static Future<MicPermissionResult> check() async {
    if (_usesPermissionHandler) {
      return _map(await Permission.microphone.status);
    }
    return MicPermissionResult.unsupported;
  }

  /// Open the host's per-app settings so the user can re-grant a permanently
  /// denied permission.
  ///
  /// permission_handler has no macOS implementation in this dependency set,
  /// so drive System Settings directly there.
  static Future<void> openSettings() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
      await Process.run('open', [
        'x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone',
      ]);
      return;
    }
    await openAppSettings();
  }

  /// Whether this target should go through `permission_handler`.
  ///
  /// Only Android and iOS expose a meaningful request flow for the microphone
  /// group through the plugin. On desktop/web the recorder triggers the native
  /// prompt directly.
  static bool get _usesPermissionHandler =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static MicPermissionResult _map(PermissionStatus status) {
    switch (status) {
      case PermissionStatus.granted:
      case PermissionStatus.limited:
      case PermissionStatus.provisional:
        return MicPermissionResult.granted;
      case PermissionStatus.permanentlyDenied:
        return MicPermissionResult.permanentlyDenied;
      case PermissionStatus.denied:
      case PermissionStatus.restricted:
        return MicPermissionResult.denied;
    }
  }
}
