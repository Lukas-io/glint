import 'package:glint_core/glint_core.dart';

void main() {
  const report =
      'POST /login failed in /Users/ada/StudioProjects/shop/lib/api/auth.dart:42 '
      'with Authorization: Bearer 3f9a8c1d2b7e6f50a4c3b2a1908f7e6d5c4b3a29 and password=hunter2';
  print(redactForSharing(report));

  print(editDistance('network_list', 'network_lsit'));
}
