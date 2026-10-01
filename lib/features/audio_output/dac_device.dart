import 'pcm_format.dart';

class DacDevice {
  final String id;
  final String name;
  final String manufacturer;
  final String enumerator;
  final bool isDefault;
  final bool exclusiveSupported;
  final bool hardwareVolume;
  final List<PcmFormat> formats;

  const DacDevice({
    required this.id,
    required this.name,
    this.manufacturer = '',
    this.enumerator = '',
    this.isDefault = false,
    this.exclusiveSupported = false,
    this.hardwareVolume = false,
    this.formats = const [],
  });

  String get displayName {
    if (manufacturer.isNotEmpty &&
        !name.toLowerCase().contains(manufacturer.toLowerCase())) {
      return '$manufacturer · $name';
    }
    return name;
  }

  /// The `audio-device` string to hand libmpv, which is enumerator-aware
  /// because the two backends want genuinely different shapes.
  ///
  /// An ALSA PCM name is passed VERBATIM: `hw:CARD=PCH,DEV=0` is exactly
  /// the `snd_pcm_open` string that bypasses `dmix`/`plughw` and with it
  /// the mixer, which is the whole point of asking for exclusive on Linux.
  /// The `alsa/` prefix means "let libmpv resolve this name", and libmpv
  /// resolves it through the default conversion plugin — a shared path —
  /// so it is only added to a name that is ALSA but not already a PCM.
  ///
  /// WASAPI keeps `wasapi/<endpoint-id>`: libmpv's wasapi AO reads the
  /// enumerator prefix off the front to pick the backend.
  String get mpvDeviceName {
    if (id.isEmpty) return 'auto';
    if (id.startsWith('hw:') ||
        id.startsWith('plughw:') ||
        id.startsWith('alsa/')) {
      return id;
    }
    return enumerator == 'wasapi' ? 'wasapi/$id' : 'alsa/$id';
  }

  bool supports(PcmFormat format) =>
      formats.any((f) => f.matches(format));

  String get supportedSummary {
    // An ALSA device never carries probed formats (opening a PCM needs
    // alsa-lib), so "no formats reported" would read as "this DAC cannot
    // do exclusive" — the opposite of what an empty list means here.
    if (formats.isEmpty) {
      return enumerator == 'alsa'
          ? 'ALSA hw: PCM · no mixer in path · format confirmed at open'
          : 'No exclusive PCM formats reported';
    }
    final byDepth = <int, List<int>>{};
    for (final f in formats) {
      byDepth.putIfAbsent(f.bitDepth, () => []).add(f.sampleRateHz);
    }
    final depths = byDepth.keys.toList()..sort();
    return depths.map((d) {
      final rates = (byDepth[d]!..sort()).map(PcmFormat.rateLabel).join(' / ');
      return '$d-bit: $rates';
    }).join('\n');
  }

  factory DacDevice.fromJson(Map<dynamic, dynamic> json) {
    final raw = json['formats'];
    final formats = <PcmFormat>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) formats.add(PcmFormat.fromJson(item));
      }
    }
    return DacDevice(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Audio device',
      manufacturer: json['manufacturer']?.toString() ?? '',
      enumerator: json['enumerator']?.toString() ?? '',
      isDefault: json['isDefault'] == true,
      exclusiveSupported: json['exclusiveSupported'] == true,
      hardwareVolume: json['hardwareVolume'] == true,
      formats: formats,
    );
  }
}
