import '../runtime/app_agent.dart';
import '../runtime/flutter_runtime.dart';

/// Why Flutter could not take an input itself; the caller hands it to the platform instead.
enum FlutterInputMiss {
  systemSurface('a system surface (alert, sheet, permission prompt) is over the app'),
  keyboard('the point is on the on-screen keyboard'),
  platformView('the point is on a native view embedded in the app'),
  outside('the point is outside the app'),
  noFocus('no Flutter text field has focus'),
  readOnly('the focused field is read-only'),
  partial('only part of the input landed'),
  unsupportedKey('the key has no Flutter text-editing equivalent'),
  evalFailed('the app did not answer glint\'s in-app agent');

  const FlutterInputMiss(this.reason);
  final String reason;
}

/// Input delivered inside the app by glint's agent: pointer events into GestureBinding, edits into the focused EditableText.
class FlutterInput {
  FlutterInput(this.runtime);

  final FlutterRuntime runtime;

  static var _nextPointer = 0x7A000;

  /// Keys with a text-editing equivalent the agent applies itself.
  static const editingKeys = {'backspace', 'delete', 'left', 'right', 'space', 'enter'};

  /// The agent's own error after an [FlutterInputMiss.evalFailed] or a partial edit, for the reply.
  String? lastError;

  /// How much of the last partial edit landed: `delivered` of `of`.
  ({int delivered, int of})? lastPartial;

  /// Sends one touch through [points] (logical x, y, ms after the first); null when it was delivered.
  Future<FlutterInputMiss?> touch(List<({double x, double y, int ms})> points) => _call({
        'op': 'touch',
        'pointer': '${_nextPointer++}',
        'pts': points.map((p) => '${p.x},${p.y},${p.ms}').join(';'),
      }, extraMs: points.last.ms);

  /// Types [text] into the focused Flutter field, one character per edit so formatters see each keystroke; null when delivered.
  Future<FlutterInputMiss?> type(String text, {int gapMs = 0}) =>
      _call({'op': 'type', 'text': text, 'gapMs': '$gapMs'}, extraMs: gapMs * text.length);

  /// Presses an editing key ([key] is a `KeyName` name) [count] times in the focused Flutter field; null when delivered.
  Future<FlutterInputMiss?> key(String key, {int count = 1}) async =>
      editingKeys.contains(key) ? _call({'op': 'key', 'key': key, 'count': '$count'}) : FlutterInputMiss.unsupportedKey;

  /// Two pointers around logical [cx], [cy] going from [from] to [to] apart over [ms]; null when delivered.
  Future<FlutterInputMiss?> pinch(double cx, double cy, double from, double to, int ms) {
    final base = _nextPointer;
    _nextPointer += 2;
    return _call({'op': 'pinch', 'cx': '$cx', 'cy': '$cy', 'from': '$from', 'to': '$to', 'ms': '$ms', 'pointer': '$base'}, extraMs: ms);
  }

  /// Selects all text in the focused Flutter field; null when delivered.
  Future<FlutterInputMiss?> selectAll() => _call({'op': 'selectAll'});

  Future<FlutterInputMiss?> _call(Map<String, String> args, {int extraMs = 0}) async {
    lastError = null;
    lastPartial = null;
    final agent = AppAgent.of(runtime);
    if (agent == null) {
      lastError = 'this connection cannot call service extensions';
      return FlutterInputMiss.evalFailed;
    }
    final Map<String, Object?> reply;
    try {
      reply = await agent.call(args, timeout: Duration(milliseconds: 10000 + extraMs));
    } on Object catch (e) {
      lastError = '$e'.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '$e');
      return FlutterInputMiss.evalFailed;
    }
    final status = reply['status'];
    if (status == 'ok') return null;
    if (status == 'partial') {
      lastPartial = (delivered: (reply['delivered'] as num?)?.toInt() ?? 0, of: (reply['of'] as num?)?.toInt() ?? 0);
      lastError = '${reply['error']}';
      return FlutterInputMiss.partial;
    }
    final miss = FlutterInputMiss.values.where((m) => m.name == status).firstOrNull;
    if (miss == null) lastError = 'unexpected reply $status';
    return miss ?? FlutterInputMiss.evalFailed;
  }
}
