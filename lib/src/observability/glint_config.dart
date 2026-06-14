/// Runtime-tunable defaults. Tools that have a baked-in constant
/// (poll cadences, ceilings, ring capacities) consult this instead,
/// so the agent can adjust them via the `config` MCP tool without
/// restarting glint.
class GlintConfig {
  GlintConfig({
    this.readyTimeoutMs = 5000,
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

  /// Opt in to anonymous usage telemetry. Default off. Events have no
  /// PII — see [TelemetryClient] for the schema.
  bool telemetryEnabled = false;

  /// Where to POST telemetry events. Set this to your own collector or
  /// leave at the default (the Cloudflare Worker shipped with glint).
  String telemetryEndpoint = 'https://glint-telemetry.lukas-io.workers.dev/v1/event';

  /// All known keys → string of current value, for the `config get` view.
  Map<String, Object> toJson() => {
        'readyTimeoutMs': readyTimeoutMs,
        'settleCeilingMs': settleCeilingMs,
        'settleQuietFrames': settleQuietFrames,
        'scrollMaxScrolls': scrollMaxScrolls,
        'scrollAmountFraction': scrollAmountFraction,
        'actionLogCapacity': actionLogCapacity,
        'appLogCapacity': appLogCapacity,
        'iconEnrichMax': iconEnrichMax,
        'inputEnrichMax': inputEnrichMax,
        'telemetryEnabled': telemetryEnabled,
        'telemetryEndpoint': telemetryEndpoint,
      };

  /// Returns null on success, or a description of the validation failure.
  String? set(String key, Object value) {
    switch (key) {
      case 'readyTimeoutMs':
        final v = _asPositiveInt(value);
        if (v == null) return 'readyTimeoutMs must be a positive int';
        readyTimeoutMs = v;
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
      case 'telemetryEnabled':
        if (value is! bool) return 'telemetryEnabled must be a bool';
        telemetryEnabled = value;
      case 'telemetryEndpoint':
        if (value is! String || value.isEmpty) {
          return 'telemetryEndpoint must be a non-empty string';
        }
        telemetryEndpoint = value;
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
