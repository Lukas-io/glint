import 'action_log.dart';

/// Natural-language view of an [ActionLog]'s entries. Renders each
/// event on one line: `[t+Δ] tool(args) → summary`. Δ is relative to
/// the first entry in the slice.
class LogRenderer {
  const LogRenderer();

  String render(List<LogEntry> entries) {
    if (entries.isEmpty) return '(empty)';
    final origin = entries.first.timestamp;
    final buf = StringBuffer();
    for (final e in entries) {
      buf
        ..write('[t+')
        ..write(_formatDelta(e.timestamp.difference(origin).inMilliseconds))
        ..write('] ')
        ..write(e.tool);
      final argSummary = _argSummary(e);
      if (argSummary.isNotEmpty) buf.write(argSummary);
      buf.write(' → ');
      switch (e) {
        case SuccessEntry():
          buf.write(e.summary);
          if (e.armed != null) {
            buf
              ..write(' (armed: ')
              ..write(e.armed!['attempts'])
              ..write(' polls / ')
              ..write(e.armed!['elapsedMs'])
              ..write('ms)');
          }
        case FailureEntry():
          buf
            ..write('FAIL ')
            ..write(e.errorKind.name)
            ..write(' — ')
            ..write(e.summary);
      }
      buf.write(' [');
      buf.write(e.elapsedMs);
      buf.writeln('ms]');
    }
    return buf.toString().trimRight();
  }

  String _formatDelta(int ms) {
    if (ms < 1000) return '${ms}ms';
    final s = ms / 1000;
    return '${s.toStringAsFixed(s < 10 ? 2 : 1)}s';
  }

  String _argSummary(LogEntry e) {
    final args = switch (e) {
      SuccessEntry() => e.args,
      FailureEntry() => e.args,
    };
    if (args == null || args.isEmpty) return '';
    // Pick the few most informative keys.
    final picks = <String>[];
    for (final k in const [
      'glintId',
      'fromGlintId',
      'toGlintId',
      'targetGlintId',
      'targetTextContent',
      'text',
      'direction',
      'button',
    ]) {
      final v = args[k];
      if (v != null) picks.add('$k=$v');
    }
    if (picks.isEmpty) return '';
    return '(${picks.join(', ')})';
  }
}
