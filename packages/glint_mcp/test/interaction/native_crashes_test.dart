import 'dart:convert';
import 'dart:io';

import 'package:glint_mcp/interaction.dart';
import 'package:test/test.dart';

void main() {
  group('Android crash buffer', () {
    test('a native tombstone names the signal, abort message and top frame', () {
      final log = File('test/interaction/tombstone_sample.txt').readAsStringSync();
      final crash = parseAndroidCrashes(log, package: 'com.google.android.bluetooth').single;
      expect(crash.reason, startsWith('signal 6 (SIGABRT): system/gd/hci/hci_layer.cc:478'));
      expect(crash.frames.first, '/apex/com.android.runtime/lib64/bionic/libc.so (abort+168)');
      expect(parseAndroidCrashes(log, package: 'com.example.ember'), isEmpty);
    });

    test('a Java exception names the exception and its first frame', () {
      const log = '''
2026-09-27 16:40:12.345  1234  1234 E AndroidRuntime: FATAL EXCEPTION: main
2026-09-27 16:40:12.345  1234  1234 E AndroidRuntime: Process: com.example.ember, PID: 1234
2026-09-27 16:40:12.345  1234  1234 E AndroidRuntime: java.lang.IllegalStateException: boom
2026-09-27 16:40:12.345  1234  1234 E AndroidRuntime: 	at com.example.ember.MainActivity.onCreate(MainActivity.kt:12)
2026-09-27 16:40:12.346  1234  1234 E AndroidRuntime: 	at android.app.Activity.performCreate(Activity.java:8000)
''';
      final crash = parseAndroidCrashes(log, package: 'com.example.ember').single;
      expect(crash.line, 'java.lang.IllegalStateException: boom at com.example.ember.MainActivity.onCreate(MainActivity.kt:12)');
      expect(crash.time, DateTime(2026, 9, 27, 16, 40, 12, 345));
    });
  });

  group('iOS crash reports', () {
    String ips(String bundleId) => [
          jsonEncode({'app_name': 'Runner', 'bundleID': bundleId, 'timestamp': '2026-09-27 16:40:12.00 +0100'}),
          jsonEncode({
            'exception': {'type': 'EXC_BAD_ACCESS', 'signal': 'SIGSEGV'},
            'termination': {'indicator': 'Segmentation fault: 11'},
            'usedImages': [
              {'name': 'Flutter'},
              {'name': 'Runner'},
            ],
            'threads': [
              {'frames': []},
              {
                'triggered': true,
                'frames': [
                  {'imageIndex': 0, 'symbol': 'fml::KillProcess()'},
                  {'imageIndex': 1, 'symbol': 'main'},
                ],
              },
            ],
          }),
        ].join('\n');

    test('a report for the app names the exception and crashing frames', () {
      final crash = parseIpsCrash(ips('com.example.ember'), bundleId: 'com.example.ember')!;
      expect(crash.reason, 'EXC_BAD_ACCESS (SIGSEGV): Segmentation fault: 11');
      expect(crash.frames, ['fml::KillProcess() (Flutter)', 'main (Runner)']);
      expect(crash.time.toUtc(), DateTime.utc(2026, 9, 27, 15, 40, 12));
    });

    test('reports for other apps are ignored', () {
      expect(parseIpsCrash(ips('com.apple.Preferences'), bundleId: 'com.example.ember'), isNull);
    });
  });
}
