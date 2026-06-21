/// Runtime-tunable defaults. Tools that have a baked-in constant
/// (poll cadences, ceilings, ring capacities) consult this instead,
/// so the agent can adjust them via the `config` MCP tool without
/// restarting glint.
class GlintConfig {
  GlintConfig({
    this.readyTimeoutMs = 5000,
    this.attachProbeTimeoutMs = 2000,
    this.launchTimeoutMs = 180000,
    this.settleCeilingMs = 5000,
    this.settleQuietFrames = 3,
    this.scrollMaxScrolls = 8,
    this.scrollAmountFraction = 0.6,
    this.actionLogCapacity = 200,
    this.appLogCapacity = 500,
    this.iconEnrichMax = 20,
    this.inputEnrichMax = 10,
  });

  /// Default ceiling for tap/long_press/swipe/drag/type `awaitReady`.
  int readyTimeoutMs;

  /// Max time `attach` polls for the first rendered frame before giving up
  /// on the iOS viewport probe (blank/loading first frame).
  int attachProbeTimeoutMs;

  /// Max time `attach launch:…` waits for `flutter run` to print its VM URI.
  /// Cold builds are slow, so this defaults high.
  int launchTimeoutMs;

  /// Default ceiling for the `wait_for_settle` tool.
  int settleCeilingMs;

  /// Consecutive `schedulerPhase==idle` polls before declaring settled.
  int settleQuietFrames;

  /// Default ceiling for `scroll_to_find` scroll attempts.
  int scrollMaxScrolls;

  /// Default per-step scroll size as fraction of viewport.
  double scrollAmountFraction;

  /// Ring capacity for glint's tool-call action log.
  int actionLogCapacity;

  /// Ring capacity for the app stderr/logging buffer.
  int appLogCapacity;

  /// Max SemanticIcons enriched per scene (each costs ~1 VM eval).
  int iconEnrichMax;

  /// Max SemanticInputs enriched per scene (each costs ~2 VM evals).
  int inputEnrichMax;

  /// All known keys → string of current value, for the `config get` view.
  /// Telemetry is env-controlled now (GLINT_NO_TELEMETRY, GLINT_NO_USAGE);
  /// not exposed here so the agent can't accidentally re-enable telemetry
  /// a user disabled at the env level.
  Map<String, Object> toJson() => {
        'readyTimeoutMs': readyTimeoutMs,
        'attachProbeTimeoutMs': attachProbeTimeoutMs,
        'launchTimeoutMs': launchTimeoutMs,
        'settleCeilingMs': settleCeilingMs,
        'settleQuietFrames': settleQuietFrames,
        'scrollMaxScrolls': scrollMaxScrolls,
        'scrollAmountFraction': scrollAmountFraction,
        'actionLogCapacity': actionLogCapacity,
        'appLogCapacity': appLogCapacity,
        'iconEnrichMax': iconEnrichMax,
        'inputEnrichMax': inputEnrichMax,
      };

  /// Returns null on success, or a description of the validation failure.
  String? set(String key, Object value) {
    switch (key) {
      case 'readyTimeoutMs':
        final v = _asPositiveInt(value);
        if (v == null) return 'readyTimeoutMs must be a positive int';
        readyTimeoutMs = v;
      case 'attachProbeTimeoutMs':
        final v = _asPositiveInt(value);
        if (v == null) return 'attachProbeTimeoutMs must be a positive int';
        attachProbeTimeoutMs = v;
      case 'launchTimeoutMs':
        final v = _asPositiveInt(value);
        if (v == null) return 'launchTimeoutMs must be a positive int';
        launchTimeoutMs = v;
      case 'settleCeilingMs':
        final v = _asPositiveInt(value);
        if (v == null) return 'settleCeilingMs must be a positive int';
        settleCeilingMs = v;
      case 'settleQuietFrames':
        final v = _asPositiveInt(value);
        if (v == null) return 'settleQuietFrames must be a positive int';
        settleQuietFrames = v;
      case 'scrollMaxScrolls':
        final v = _asPositiveInt(value);
        if (v == null) return 'scrollMaxScrolls must be a positive int';
        scrollMaxScrolls = v;
      case 'scrollAmountFraction':
        final v = (value is num) ? value.toDouble() : null;
        if (v == null || v <= 0 || v > 1) {
          return 'scrollAmountFraction must be in (0, 1]';
        }
        scrollAmountFraction = v;
      case 'actionLogCapacity':
        final v = _asPositiveInt(value);
        if (v == null) return 'actionLogCapacity must be a positive int';
        actionLogCapacity = v;
      case 'appLogCapacity':
        final v = _asPositiveInt(value);
        if (v == null) return 'appLogCapacity must be a positive int';
        appLogCapacity = v;
      case 'iconEnrichMax':
        final v = _asPositiveInt(value);
        if (v == null) return 'iconEnrichMax must be a positive int';
        iconEnrichMax = v;
      case 'inputEnrichMax':
        final v = _asPositiveInt(value);
        if (v == null) return 'inputEnrichMax must be a positive int';
        inputEnrichMax = v;
      default:
        return 'unknown config key: $key';
    }
    return null;
  }

  static int? _asPositiveInt(Object value) {
    if (value is int && value > 0) return value;
    if (value is num && value > 0 && value == value.toInt()) {
      return value.toInt();
    }
    return null;
  }
}
