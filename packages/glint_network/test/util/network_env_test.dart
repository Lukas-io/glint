import 'package:glint_network/src/util/network_env.dart';
import 'package:test/test.dart';

void main() {
  test('a legacy FLUTTER_NETWORK_MCP_ variable is readable under its GLINT_NETWORK_ name', () {
    final env = withLegacyNames({'FLUTTER_NETWORK_MCP_TELEMETRY': 'on', 'HOME': '/h'});
    expect(env['GLINT_NETWORK_TELEMETRY'], 'on');
    expect(env['HOME'], '/h');
  });

  test('the new name wins when both are set', () {
    final env = withLegacyNames({
      'FLUTTER_NETWORK_MCP_MAX_ATTACH': '2',
      'GLINT_NETWORK_MAX_ATTACH': '5',
    });
    expect(env['GLINT_NETWORK_MAX_ATTACH'], '5');
  });

  test('the warning names each legacy variable and its replacement', () {
    expect(
      legacyEnvWarning({'FLUTTER_NETWORK_MCP_TELEMETRY': 'on', 'FLUTTER_NETWORK_MCP_DATA_DIR': '/d'}),
      'deprecated env vars FLUTTER_NETWORK_MCP_DATA_DIR (now GLINT_NETWORK_DATA_DIR), '
      'FLUTTER_NETWORK_MCP_TELEMETRY (now GLINT_NETWORK_TELEMETRY); '
      'the old names still work but will be removed in a later release',
    );
    expect(legacyEnvWarning({'GLINT_NETWORK_TELEMETRY': 'on'}), isNull);
  });
}
