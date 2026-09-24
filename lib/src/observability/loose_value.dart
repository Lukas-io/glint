/// An int from an int, a whole double (15000.0) or a numeric string ("15000"); null otherwise.
int? looseInt(Object? value) {
  final n = looseNum(value);
  if (n == null || n.isNaN || n.isInfinite || n != n.truncateToDouble()) {
    return null;
  }
  return n.toInt();
}

/// A number from a num or a numeric string; null otherwise.
double? looseNum(Object? value) => switch (value) {
      num n => n.toDouble(),
      String s => double.tryParse(s.trim()),
      _ => null,
    };

/// A bool from a bool or the strings "true" / "false"; null otherwise.
bool? looseBool(Object? value) => switch (value) {
      bool b => b,
      String s when s.trim().toLowerCase() == 'true' => true,
      String s when s.trim().toLowerCase() == 'false' => false,
      _ => null,
    };
