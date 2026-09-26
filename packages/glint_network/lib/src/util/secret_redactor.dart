import 'network_env.dart';

export 'package:glint_core/glint_core.dart' show redactSecrets;

/// The value stored or shown for a redacted header.
const redactedValue = '<redacted>';

/// A copy of [headers] with the values of every header named in [names] (lowercase) replaced by [redactedValue].
Map<String, dynamic> redactHeaderValues(
  Map<String, dynamic> headers,
  Set<String> names,
) =>
    {
      for (final e in headers.entries)
        e.key: names.contains(e.key.toLowerCase())
            ? (e.value is List ? [redactedValue] : redactedValue)
            : e.value,
    };

/// True when the user asked to keep secret header values in the capture database (`GLINT_NETWORK_STORE_SECRETS`).
bool storeSecrets([Map<String, String>? env]) {
  final v =
      (env ?? networkEnv)['GLINT_NETWORK_STORE_SECRETS']
          ?.trim()
          .toLowerCase();
  return v == 'true' || v == '1' || v == 'yes' || v == 'on';
}
