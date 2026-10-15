import 'flutter_input.dart';

/// Where a session sends input: inside the Flutter app first with real touches for the rest, real touches only, or the app only.
enum InputRoute {
  auto,
  device,
  app;

  /// The route named [name], or null when it names none.
  static InputRoute? parse(String? name) => values.where((r) => r.name == name).firstOrNull;
}

/// Which path delivered one input: inside the Flutter app, or a real OS-level touch.
enum InputPath { app, device }

/// How one input was delivered, and why it left the app path when it did.
typedef InputReport = ({InputPath path, FlutterInputMiss? reason, int ms});

extension InputReportOut on InputReport {
  Map<String, Object?> toJson() => {'path': path.name, if (reason != null) 'reason': reason!.name, 'ms': ms};

  /// The compact suffix replies print: `via app`, `via device (systemSurface)`.
  String get label => reason == null ? 'via ${path.name}' : 'via ${path.name} (${reason!.name})';
}
