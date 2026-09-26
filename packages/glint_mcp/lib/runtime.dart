/// Module — runtime. Transport abstraction over the running Flutter
/// app's VM service. Every glint primitive that talks to the live app
/// goes through [FlutterRuntime]; no other code reaches the raw
/// `ext.flutter.inspector.*` RPCs or `evaluate` calls directly.
library;

export 'src/runtime/flutter_runtime.dart';
export 'src/runtime/vm_service_runtime.dart';
