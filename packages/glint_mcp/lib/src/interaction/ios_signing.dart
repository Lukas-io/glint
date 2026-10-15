import 'dart:convert';
import 'dart:io';

import 'backend.dart';

/// The team glint signs a phone build with, and why it chose it.
typedef SigningChoice = ({String team, String why, List<String> others});

/// Raised when several teams could sign and nothing says which.
class SigningUndecided implements Exception {
  SigningUndecided(this.teams, this.projectTeam);
  final List<String> teams;
  final String? projectTeam;
  @override
  String toString() => 'SigningUndecided(${teams.join(', ')})';
}

/// Where glint remembers the team it last signed a phone build with.
String _memoryPath() => '${Platform.environment['HOME'] ?? '.'}/.glint/signing.json';

/// The team glint signed with last time on this Mac, if any.
String? rememberedTeam() {
  try {
    return (jsonDecode(File(_memoryPath()).readAsStringSync()) as Map)['team'] as String?;
  } on Object {
    return null;
  }
}

/// Remembers [team] for the next phone build that needs one.
void rememberTeam(String team) {
  try {
    final f = File(_memoryPath());
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(jsonEncode({'team': team, 'at': DateTime.now().toIso8601String()}));
  } on Object {
    // a forgotten team only means choosing again next time
  }
}

/// The team ids of the Apple Development certificates in this Mac's keychain.
Future<List<String>> localTeams({ProcessRunner run = Process.run}) async {
  final ids = await run('security', ['find-identity', '-v', '-p', 'codesigning']);
  final names = RegExp(r'"(Apple Development: [^"]+)"').allMatches('${ids.stdout}').map((m) => m.group(1)!).toSet();
  final teams = <String>{};
  for (final name in names) {
    final pem = await run('sh', ['-c', 'security find-certificate -c "\$1" -p | openssl x509 -noout -subject', 'sh', name]);
    final team = RegExp(r'OU\s*=\s*([A-Z0-9]{10})').firstMatch('${pem.stdout}')?.group(1);
    if (team != null) teams.add(team);
  }
  return teams.toList()..sort();
}

/// The `DEVELOPMENT_TEAM` the project's Runner target names, if any.
String? projectTeam(String projectDir) {
  final pbx = File('$projectDir/ios/Runner.xcodeproj/project.pbxproj');
  if (!pbx.existsSync()) return null;
  return RegExp(r'DEVELOPMENT_TEAM = ([A-Z0-9]{10});').firstMatch(pbx.readAsStringSync())?.group(1);
}

/// The project's bundle identifier, if the Runner target names one.
String? projectBundleId(String projectDir) {
  final pbx = File('$projectDir/ios/Runner.xcodeproj/project.pbxproj');
  if (!pbx.existsSync()) return null;
  return RegExp(r'PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);').allMatches(pbx.readAsStringSync()).map((m) => m.group(1)!).where((id) => !id.contains('Tests')).firstOrNull;
}

/// Teams with an unexpired provisioning profile for [bundleId] that lists the phone [udid].
Future<List<String>> teamsWithProfile(String udid, String bundleId, {ProcessRunner run = Process.run}) async {
  final dir = Directory('${Platform.environment['HOME']}/Library/Developer/Xcode/UserData/Provisioning Profiles');
  if (!dir.existsSync()) return const [];
  final teams = <String>{};
  for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.mobileprovision'))) {
    final r = await run('sh', ['-c', 'security cms -D -i "\$1" | plutil -convert xml1 -o - -', 'sh', f.path]);
    final xml = '${r.stdout}';
    if (!xml.contains(udid)) continue;
    final team = RegExp(r'<key>TeamIdentifier</key>\s*<array>\s*<string>([A-Z0-9]{10})</string>').firstMatch(xml)?.group(1);
    final appId = RegExp(r'<key>application-identifier</key>\s*<string>[A-Z0-9]{10}\.([^<]+)</string>').firstMatch(xml)?.group(1);
    final expires = DateTime.tryParse(RegExp(r'<key>ExpirationDate</key>\s*<date>([^<]+)</date>').firstMatch(xml)?.group(1) ?? '');
    if (team == null || appId != bundleId || (expires != null && expires.isBefore(DateTime.now()))) continue;
    teams.add(team);
  }
  return teams.toList();
}

/// Picks the team to sign [projectDir] for phone [udid]: [requested], the project's own team, the one remembered here, the only one, or the one already provisioned for this app; throws [SigningUndecided] otherwise.
Future<SigningChoice> pickSigningTeam(String projectDir, String udid, {String? requested, ProcessRunner run = Process.run}) async {
  final local = await localTeams(run: run);
  final own = projectTeam(projectDir);
  List<String> others(String team) => [for (final t in local) if (t != team) t];
  if (requested != null) return (team: requested, why: 'signingTeam asked for it', others: others(requested));
  if (own != null && local.contains(own)) return (team: own, why: 'the project names it', others: others(own));
  final remembered = rememberedTeam();
  if (remembered != null && local.contains(remembered)) {
    return (team: remembered, why: 'glint signed with it last time on this Mac${own == null ? '' : ' (the project names $own, which has no certificate here)'}', others: others(remembered));
  }
  if (local.length == 1) return (team: local.single, why: 'it is the only team with a certificate on this Mac', others: const <String>[]);
  final bundle = projectBundleId(projectDir);
  final provisioned = bundle == null ? const <String>[] : await teamsWithProfile(udid, bundle, run: run);
  if (provisioned.length == 1) return (team: provisioned.single, why: 'it already has a profile for $bundle on this phone', others: others(provisioned.single));
  throw SigningUndecided(local, own);
}
