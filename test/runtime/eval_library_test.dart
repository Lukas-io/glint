import 'package:glint/src/runtime/vm_service_runtime.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart' show LibraryRef;

LibraryRef _lib(String id, String uri) => LibraryRef(id: id, uri: uri, name: '');

void main() {
  group('evalLibraryCandidates', () {
    test('framework libraries first, then root, then the app package', () {
      final ids = evalLibraryCandidates(
        libraries: [
          _lib('app-boot', 'package:shop/bootstrap.dart'),
          _lib('dart-core', 'dart:core'),
          _lib('wi', 'package:flutter/src/widgets/widget_inspector.dart'),
          _lib('mtf', 'package:flutter/src/material/text_field.dart'),
          _lib('app-app', 'package:shop/app.dart'),
          _lib('other', 'package:other/x.dart'),
        ],
        rootLib: _lib('root', 'package:shop/main_dev.dart'),
      );
      expect(ids, ['mtf', 'wi', 'root', 'app-boot', 'app-app']);
    });

    test('a file: root adds no package siblings and never repeats an id', () {
      final ids = evalLibraryCandidates(
        libraries: [_lib('root', 'file:///app/main.dart')],
        rootLib: _lib('root', 'file:///app/main.dart'),
      );
      expect(ids, ['root']);
    });
  });
}
