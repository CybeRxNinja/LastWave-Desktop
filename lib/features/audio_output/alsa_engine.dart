import 'dart:developer' as developer;
import 'dart:io';

import 'package:meta/meta.dart';

import 'dac_device.dart';

/// Pure-Dart client for Linux ALSA sound-card discovery.
///
/// Windows gets bit-perfect playback from a native WASAPI engine. The Linux
/// equivalent of an exclusive open is `snd_pcm_open("hw:CARD=<card>,DEV=<n>")`,
/// which bypasses `dmix`/`plughw` and therefore the mixer — and libmpv already
/// does exactly that when the string is handed to it verbatim with `ao=alsa`.
/// So this engine only has to do the half it can do honestly: enumerate `hw:`
/// PCMs from procfs and report what we actually know.
///
/// What it deliberately does not do:
/// - fabricate format lists. Opening a PCM needs alsa-lib, and a guessed
///   `PcmFormat` would be trusted downstream, so [probeDevice] returns an empty
///   `formats` (= unknown) and the runtime `audio-out-params` check stays the
///   single source of truth for bit-perfect.
/// - claim hardware volume. There is no control-ABI path in this slice, so
///   volume stays software-side and [setHardwareVolume] always fails honestly.
class AlsaEngine {
  const AlsaEngine();

  bool get isSupported => Platform.isLinux;

  /// Every `hw:` playback PCM, ordered by card index then stream index.
  ///
  /// procfs raises for every missing node inside containers, WSL sessions
  /// and sandboxes, so a read failure degrades to `const []` (with a log)
  /// instead of throwing at the player.
  Future<List<DacDevice>> enumerateDevices() async {
    if (!isSupported) return const [];
    final cards = parseAlsaCards(_readProcFile('$_procAsound/cards') ?? '');
    if (cards.isEmpty) return const [];
    return buildDacDevices(
      cards,
      _readPlaybackStreams(),
      defaultCardIndex: parseDefaultCardIndex(_readDefaultLinkTarget(), cards),
    );
  }

  /// The same device list with EMPTY `formats`.
  ///
  /// The id is checked against procfs so a stale preference cannot resurrect a
  /// DAC that is gone, but nothing is measured: an id procfs never reported is
  /// unknown, not guessed. A malformed id never even reaches the filesystem.
  Future<DacDevice?> probeDevice(String id) async {
    if (!isSupported) return null;
    if (parseAlsaDeviceId(id) == null) {
      alsaLog('probeDevice: malformed id "$id"');
      return null;
    }
    final wanted = id.trim().toLowerCase();
    for (final d in await enumerateDevices()) {
      if (d.id.toLowerCase() == wanted) return d;
    }
    alsaLog('probeDevice: $id is not an ALSA playback PCM');
    return null;
  }

  /// Always false — no `amixer`/control-ABI access in this slice.
  ///
  /// Reporting success here would leave the UI showing a hardware-volume knob
  /// that never touched the DAC, so the player keeps its software volume.
  Future<bool> setHardwareVolume(String id, double scalar) async {
    if (!isSupported) return false;
    final s = scalar.clamp(0.0, 1.0);
    alsaLog('setHardwareVolume ignored for $id ($s): soft volume only');
    return false;
  }

  /// Always null — same reason as [setHardwareVolume].
  Future<double?> getHardwareVolume(String id) async {
    if (!isSupported) return null;
    return null;
  }

  /// `hw:CARD=<default card>,DEV=0`, or `''` when nothing is resolvable.
  ///
  /// Only DEV=0 is flagged default, so returning the first device carrying
  /// `isDefault` is exactly the `DEV=0` rule the id contract promises.
  Future<String> defaultDeviceId() async {
    if (!isSupported) return '';
    for (final d in await enumerateDevices()) {
      if (d.isDefault) return d.id;
    }
    return '';
  }

  /// Playback streams per card, `cardN -> [0, 1, ...]`.
  Map<int, List<int>> _readPlaybackStreams() {
    final out = <int, List<int>>{};
    for (final name in _listProcNames(_procAsound)) {
      // The node also holds `cards`, `default`, `pcm`, `seq`, ... so guard the
      // slice: `substring(4)` on `pcm` would be a RangeError, not a null.
      if (!name.startsWith('card')) continue;
      final n = int.tryParse(name.substring(4));
      if (n == null) continue; // not a `cardN` directory
      final listing = _listProcNames('$_procAsound/$name').join('\n');
      final streams = parsePlaybackStreams(listing);
      if (streams.isNotEmpty) out[n] = streams;
    }
    return out;
  }

  /// procfs is a filesystem, not an API: a missing node is normal, not an
  /// error.
  String? _readProcFile(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) {
        alsaLog('no $path (no ALSA cards?)');
        return null;
      }
      return file.readAsStringSync();
    } on FileSystemException catch (e) {
      alsaLog('read $path failed: ${e.message}');
      return null;
    }
  }

  /// Entry names of [path], or `const []` on any failure. ALSA is Linux-only,
  /// so '/' is the separator.
  List<String> _listProcNames(String path) {
    try {
      final dir = Directory(path);
      if (!dir.existsSync()) return const [];
      return dir.listSync().map((e) => e.path.split('/').last).toList();
    } on FileSystemException catch (e) {
      alsaLog('list $path failed: ${e.message}');
      return const [];
    }
  }

  /// `/proc/asound/default -> cardN` is how ALSA itself resolves the default.
  String? _readDefaultLinkTarget() {
    try {
      return Link('$_procAsound/default').target;
    } on FileSystemException catch (e) {
      alsaLog('default ALSA card unresolved: ${e.message}');
      return null;
    }
  }
}

const _procAsound = '/proc/asound';
const _hwPrefix = 'hw:CARD=';
const _devSep = ',DEV=';

/// One card header from `/proc/asound/cards`.
class AlsaCardInfo {
  /// Kernel card number (`cardN`).
  final int index;

  /// ALSA card id, i.e. the bracketed token `hw:CARD=` expects.
  final String id;

  /// Human card name, i.e. the long name after the driver.
  final String name;

  const AlsaCardInfo({
    required this.index,
    required this.id,
    required this.name,
  });

  @override
  String toString() => 'card$index [$id] $name';
}

/// A parsed `hw:CARD=<cardId>,DEV=<n>` device id.
class AlsaDeviceId {
  final String cardId;
  final int stream;

  const AlsaDeviceId({required this.cardId, required this.stream});

  @override
  String toString() => '$_hwPrefix$cardId$_devSep$stream';
}

final RegExp _cardHeader = RegExp(r'^\s*(\d+)\s+\[(.+?)\]:\s*(.*)$');
final RegExp _pcmName = RegExp(r'^pcm(\d+)p$');
final RegExp _digits = RegExp(r'\d+');

/// Parses `/proc/asound/cards`, in file order.
///
/// ```
///  0 [PCH       ]: PCH - HDA Intel PCH
///  1 [Device    ]: USB - Audio Class Gadget
///                  USB Audio          : USB Audio
/// ```
///
/// The indented continuation lines name the card's individual devices, not
/// cards, so they are skipped. Unparseable lines are dropped rather than
/// thrown: the file is simply absent on machines without ALSA.
List<AlsaCardInfo> parseAlsaCards(String raw) {
  final cards = <AlsaCardInfo>[];
  for (final line in raw.split('\n')) {
    final m = _cardHeader.firstMatch(line);
    final index = int.tryParse(m?.group(1) ?? '');
    final id = (m?.group(2) ?? '').trim();
    if (index == null || id.isEmpty) continue;
    final rest = (m?.group(3) ?? '').trim();
    // `<driver> - <long name>`; very old kernels omit the driver half.
    final dash = rest.indexOf(' - ');
    final name = (dash >= 0 ? rest.substring(dash + 3) : rest).trim();
    cards.add(AlsaCardInfo(index: index, id: id, name: name));
  }
  return cards;
}

/// Playback stream numbers from a `cardN` directory listing.
///
/// ALSA core names streams `pcm<n>p` for playback and `pcm<n>c` for capture,
/// so the suffix alone answers "can this record?", which is why a
/// capture-only card yields `[]`. Plugin names (`plughw`, `dmix`, `dsnoop`,
/// `surround*`) are never procfs nodes, which is what makes every result a
/// plain `hw:` device.
List<int> parsePlaybackStreams(String listing) {
  final out = <int>[];
  for (final line in listing.split('\n')) {
    final n = int.tryParse(_pcmName.firstMatch(line.trim())?.group(1) ?? '');
    if (n != null) out.add(n);
  }
  out.sort();
  return out;
}

/// Resolves the default card index from the `default` symlink target.
///
/// Falls back to a card literally named `default`, which is all a few kernels
/// report; `null` means "not resolvable" and no device is flagged default.
int? parseDefaultCardIndex(String? linkTarget, List<AlsaCardInfo> cards) {
  if (linkTarget != null) {
    final n = int.tryParse(_digits.firstMatch(linkTarget)?.group(0) ?? '');
    if (n != null) return n;
  }
  for (final c in cards) {
    if (c.id.toLowerCase() == 'default') return c.index;
  }
  return null;
}

/// Flattens cards × playback streams into devices, ordered and honest.
///
/// Cards sort by kernel index and devices by stream index so the picker never
/// reshuffles between polls. `formats` stays empty (unknown), `hardwareVolume`
/// is false, and `exclusiveSupported` is true precisely because a procfs
/// `pcm<n>p` node is the hardware PCM — `dmix`/`plughw` are mixer/conversion
/// plugins and are never listed here, so nothing resamples behind the player's
/// back.
List<DacDevice> buildDacDevices(
  List<AlsaCardInfo> cards,
  Map<int, List<int>> streams, {
  int? defaultCardIndex,
}) {
  final sorted = List<AlsaCardInfo>.of(cards)
    ..sort((a, b) => a.index.compareTo(b.index));
  final out = <DacDevice>[];
  for (final card in sorted) {
    final nums =
        List<int>.of(streams[card.index] ?? const <int>[])..sort();
    for (final stream in nums) {
      out.add(DacDevice(
        id: '$_hwPrefix${card.id}$_devSep$stream',
        name: alsaDeviceName(card, stream),
        enumerator: 'alsa',
        isDefault: card.index == defaultCardIndex && stream == 0,
        exclusiveSupported: true,
        hardwareVolume: false,
      ));
    }
  }
  return out;
}

/// Label for one PCM: the card name plus whatever disambiguates it.
///
/// pcm1/pcm2 on one card are separate outputs (HDMI vs S/PDIF, USB vs analog),
/// so they need distinct names to be pickable. A loopback card is a null sink
/// rather than a DAC, so it is tagged instead of being hidden — it is still a
/// valid `hw:` sink, and hiding a sink the user set up on purpose is worse than
/// labelling it.
String alsaDeviceName(AlsaCardInfo card, int stream) {
  final base = card.name.isEmpty ? card.id : card.name;
  final isLoopback = card.id.toLowerCase() == 'loopback';
  final tags = <String>[
    if (isLoopback) 'null sink',
    if (stream != 0) 'pcm$stream',
  ];
  return tags.isEmpty ? base : '$base · ${tags.join(' · ')}';
}

/// Splits `hw:CARD=<cardId>,DEV=<n>` back into its parts.
///
/// Card ids may contain spaces (`hw:CARD=Analog Output,DEV=0`), so the split
/// anchors on the LAST `,DEV=` — a card id cannot itself contain a comma,
/// because ALSA's config parser would read it as a field separator.
AlsaDeviceId? parseAlsaDeviceId(String id) {
  final trimmed = id.trim();
  if (!trimmed.startsWith(_hwPrefix)) return null;
  final rest = trimmed.substring(_hwPrefix.length);
  final at = rest.lastIndexOf(_devSep);
  if (at < 0) return null;
  final cardId = rest.substring(0, at).trim();
  final stream = int.tryParse(rest.substring(at + _devSep.length).trim());
  if (cardId.isEmpty || stream == null || stream < 0) return null;
  return AlsaDeviceId(cardId: cardId, stream: stream);
}

/// Test hook: the enumeration pipeline on raw procfs text, no filesystem.
///
/// [streams] maps card index to playback stream numbers and [cardsRaw] /
/// [defaultLink] are the literal contents of `/proc/asound/cards` and of the
/// `default` symlink target, so every branch is reachable without a real DAC.
@visibleForTesting
List<DacDevice> parseAlsaDevices({
  required String cardsRaw,
  required Map<int, List<int>> streams,
  String? defaultLink,
}) {
  final cards = parseAlsaCards(cardsRaw);
  return buildDacDevices(
    cards,
    streams,
    defaultCardIndex: parseDefaultCardIndex(defaultLink, cards),
  );
}

void alsaLog(String message) {
  developer.log(message, name: 'ALSA');
}