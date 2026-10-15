/// A tool capability that depends on the kind of device, named as attach lists it.
enum Ability {
  notifications('notifications'),
  sensors('sensors'),
  record('record'),
  media('media (pick works)'),
  locationPermission('location permission'),
  deviceStatus('device status'),
  deviceAppearance('device appearance'),
  deviceOpenUrl('device openurl'),
  devicePrivacy('device privacy'),
  deviceBiometric('device biometric'),
  shutdown('shutdown_sim');

  const Ability(this.label);
  final String label;
}

/// Why a device lacks an ability, and what to do instead.
typedef AbilityGap = ({String reason, String? instead});

/// What one device cannot do, declared once so attach lists it and every tool refuses it with the same words.
class DeviceAbilities {
  const DeviceAbilities(this.gaps);

  /// No gaps: everything a tool offers on this platform works.
  static const none = DeviceAbilities({});

  final Map<Ability, AbilityGap> gaps;

  bool can(Ability a) => !gaps.containsKey(a);

  /// The compact list attach prints, or null when nothing is missing.
  String? get line => gaps.isEmpty ? null : gaps.keys.map((a) => a.label).join(', ');

  Map<String, Object?> toJson() => {
        for (final e in gaps.entries) e.key.name: {'reason': e.value.reason, if (e.value.instead != null) 'instead': e.value.instead},
      };
}

/// A paired physical iPhone: what glint cannot reach on it yet.
const iphoneAbilities = DeviceAbilities({
  Ability.notifications: (reason: 'a physical iPhone gives glint no notification list', instead: 'test notifications on the iOS simulator'),
  Ability.sensors: (reason: 'a physical iPhone exposes no motion state to glint', instead: 'turn the phone yourself, or test rotation on the simulator'),
  Ability.record: (reason: 'recording a physical iPhone is not built yet', instead: 'device op:screenshot for single frames'),
  Ability.media: (reason: 'a phone has no simctl or adb to seed photos or set media permissions', instead: 'media op:pick still chooses in the open photo picker'),
  Ability.locationPermission: (reason: 'devicectl has no privacy setting; only the person holding the phone can change it', instead: 'answer the prompt with tap text:"Allow"'),
  Ability.deviceStatus: (reason: 'device status reads a simulator', instead: null),
  Ability.deviceAppearance: (reason: 'dark mode and text size are set in the phone\'s Settings', instead: null),
  Ability.deviceOpenUrl: (reason: 'opening a URL on a phone is not built yet', instead: null),
  Ability.devicePrivacy: (reason: 'devicectl has no privacy setting', instead: 'answer the app\'s prompt with tap text:"Allow"'),
  Ability.deviceBiometric: (reason: 'Face ID on a phone needs its owner', instead: null),
  Ability.shutdown: (reason: 'glint does not power off a phone', instead: 'kill_app to stop the app'),
});
