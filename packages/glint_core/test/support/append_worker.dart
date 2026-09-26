import 'package:glint_core/glint_core.dart';

/// Appends [count] entries to the audit log in [dir]; the concurrency test runs several of these at once.
void main(List<String> args) {
  final dir = args[0];
  final worker = args[1];
  final count = int.parse(args[2]);
  for (var i = 0; i < count; i++) {
    AuditLog.append(dir, '{"worker":$worker,"i":$i}');
  }
}
