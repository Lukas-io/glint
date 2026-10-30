import 'package:glint_mcp/src/interaction/launcher.dart';
import 'package:test/test.dart';

void main() {
  test('an adb storage failure is the reason, not the install banner', () {
    const log = '''
Launching lib/main.dart on sdk gphone64 arm64 in debug mode...
Installing build/app/outputs/flutter-apk/app-debug.apk...          873ms
Error: ADB exited with exit code 1
adb: failed to install app-debug.apk: Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE: Failed to override installation location]
Uninstalling old version...''';
    expect(AppLauncher.failureLine(log), contains('INSTALL_FAILED_INSUFFICIENT_STORAGE'));
  });

  test('a Gradle failure beats a generic error line', () {
    const log = 'Error: something\nFAILURE: Build failed with an exception.\n';
    expect(AppLauncher.failureLine(log), 'FAILURE: Build failed with an exception.');
  });

  test('no telling line gives null', () {
    expect(AppLauncher.failureLine('Launching lib/main.dart...\n'), isNull);
  });
}
