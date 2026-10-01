import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/stream_models.dart';
import '../../core/storage/prefs.dart';
import '../player/playback_service.dart';
import '../player/player_state.dart';
import 'alsa_engine.dart';
import 'dac_device.dart';
import 'format_negotiator.dart';
import 'output_path_status.dart';
import 'pcm_format.dart';
import 'wasapi_engine.dart';

class AudioOutputState {
  final List<DacDevice> devices;
  final String selectedId;
  final bool exclusiveRequested;
  final bool bitPerfectRequested;
  final OutputPathStatus path;
  final PcmFormat? lastOpenedFormat;
  final bool probing;

  const AudioOutputState({
    this.devices = const [],
    this.selectedId = '',
    this.exclusiveRequested = false,
    this.bitPerfectRequested = false,
    this.path = const OutputPathStatus(),
    this.lastOpenedFormat,
    this.probing = false,
  });

  DacDevice? get selected {
    if (devices.isEmpty) return null;
    if (selectedId.isEmpty) {
      for (final d in devices) {
        if (d.isDefault) return d;
      }
      return devices.first;
    }
    for (final d in devices) {
      if (d.id == selectedId) return d;
    }
    return null;
  }

  AudioOutputState copyWith({
    List<DacDevice>? devices,
    String? selectedId,
    bool? exclusiveRequested,
    bool? bitPerfectRequested,
    OutputPathStatus? path,
    PcmFormat? lastOpenedFormat,
    bool? probing,
  }) =>
      AudioOutputState(
        devices: devices ?? this.devices,
        selectedId: selectedId ?? this.selectedId,
        exclusiveRequested: exclusiveRequested ?? this.exclusiveRequested,
        bitPerfectRequested: bitPerfectRequested ?? this.bitPerfectRequested,
        path: path ?? this.path,
        lastOpenedFormat: lastOpenedFormat ?? this.lastOpenedFormat,
        probing: probing ?? this.probing,
      );
}

/// The device engine this platform drives: ALSA on Linux, WASAPI
/// everywhere else.
///
/// Off both platforms [WasapiEngine] is still returned, but its
/// [WasapiEngine.isSupported] is false, so the status machine keeps
/// running and honestly reports "device unavailable" instead of throwing.
///
/// The argument exists so the choice is testable without mocking
/// `dart:io`, and the return is `Object` because the two engines have no
/// common supertype.
Object audioOutputEngineFor({required bool linux}) =>
    linux ? const AlsaEngine() : const WasapiEngine();

/// Owns WASAPI/ALSA device selection, exclusive-mode mpv properties,
/// hardware volume, and the bit-perfect status machine. Does not replace
/// media_kit.
class AudioOutputController extends StateNotifier<AudioOutputState> {
  final Ref _ref;

  /// The device engine for this platform.
  ///
  /// `dynamic` on purpose: [WasapiEngine] and [AlsaEngine] share a member
  /// set but have no common supertype, and this slice deliberately does
  /// not add an interface just to name the union. Every call site below
  /// is reached only through [audioOutputEngineFor], so the two shapes
  /// are chosen in exactly one place.
  final dynamic _engine;

  /// True when this platform's engine is ALSA rather than WASAPI.
  bool get _isAlsa => _engine is AlsaEngine;

  final FormatNegotiator _negotiator;
  StreamSubscription<Map<String, dynamic>>? _hotplug;
  bool _attached = false;
  String? _lastLogged;
  // Last non-zero volume, so unmute restores the pre-mute level
  // instead of full blast. Updated on every audible setVolume and
  // on every mute press (covers slider-dragged-to-zero too).
  double _preMuteVolume = 1.0;

  AudioOutputController(this._ref, {WasapiEngine? engine})
      : _engine = engine ?? audioOutputEngineFor(linux: Platform.isLinux),
        _negotiator = const FormatNegotiator(),
        super(const AudioOutputState()) {
    final prefs = _ref.read(prefsProvider);
    state = state.copyWith(
      selectedId: prefs.audioDeviceId,
      exclusiveRequested: prefs.wasapiExclusive || prefs.bitPerfect,
      bitPerfectRequested: prefs.wasapiExclusive || prefs.bitPerfect,
    );
  }

  @override
  void dispose() {
    _hotplug?.cancel();
    super.dispose();
  }

  Future<void> attach() async {
    if (_attached) return;
    _attached = true;
    await refreshDevices();
    // ALSA has no hotplug event stream — procfs is polled by
    // refreshDevices(), and there is no native watcher on Linux.
    if (!_isAlsa) {
      _hotplug = _engine.deviceEvents.listen((event) {
        unawaited(_onHotplug(event));
      });
    }
    await applyToPlayer();
    _rebuildPath();
  }

  Future<void> onPlaybackChanged(
      PlayerSnapshot? prev, PlayerSnapshot next) async {
    await _onPlayback(prev, next);
  }

  Future<void> refreshDevices() async {
    state = state.copyWith(probing: true);
    final devices = await _engine.enumerateDevices();
    var selected = state.selectedId;
    if (selected.isNotEmpty &&
        devices.every((d) => d.id != selected) &&
        devices.isNotEmpty) {
      selected = '';
    }
    state = state.copyWith(
      devices: devices,
      selectedId: selected,
      probing: false,
    );
    _rebuildPath();
    _logCaps();
  }

  Future<void> selectDevice(String id) async {
    await _ref.read(prefsProvider).setAudioDeviceId(id);
    state = state.copyWith(selectedId: id);
    wasapiLog('Device: ${state.selected?.name ?? 'System default'}');
    await applyToPlayer();
    _rebuildPath();
  }

  Future<void> setExclusive(bool exclusive) async {
    await _ref.read(prefsProvider).setWasapiExclusive(exclusive);
    await _ref.read(prefsProvider).setBitPerfect(exclusive);
    state = state.copyWith(
      exclusiveRequested: exclusive,
      bitPerfectRequested: exclusive,
    );
    wasapiLog('Exclusive Mode: $exclusive');
    await applyToPlayer();
    _rebuildPath();
  }

  Future<void> setBitPerfect(bool enabled) => setExclusive(enabled);

  void refreshPath() => _rebuildPath();

  Future<void> applyToPlayer() async {
    final playback = _ref.read(playbackServiceProvider.notifier);
    final device = state.selected;
    final exclusive = state.exclusiveRequested;
    final hw = exclusive && (device?.hardwareVolume ?? false);
    final source = _sourceOf(_ref.read(playbackServiceProvider).stream);
    final decision = source == null
        ? null
        : _negotiator.negotiate(
            source: source,
            device: device,
            exclusiveRequested: exclusive,
          );
    // When the format is UNKNOWN the negotiated output is null on both
    // backends, so hand the player the SOURCE instead: `ao=alsa` is told to
    // force exactly that rate/depth on the raw hw: PCM, which is the whole of
    // what can be asked for without a measured list. That is the ALSA shape
    // whenever the native probe is absent or the PCM could not be opened.
    // `_refreshAoFormat` then reports what actually came out.
    final outputFormat = exclusive
        ? (decision?.output ?? (_isAlsa ? source : null))
        : null;
    await playback.configureWasapi(
      exclusive: exclusive,
      mpvDevice: device?.mpvDeviceName ?? 'auto',
      lockSoftwareVolume: exclusive,
      outputFormat: outputFormat,
    );
    if (hw) {
      final vol = _ref.read(playbackServiceProvider).volume;
      await _engine.setHardwareVolume(device!.id, vol);
      wasapiLog('Hardware Volume: TRUE');
    } else {
      wasapiLog('Hardware Volume: FALSE');
    }
  }

  Future<void> setVolume(double volume) async {
    if (volume > 0) _preMuteVolume = volume.clamp(0.0, 1.0);
    final playback = _ref.read(playbackServiceProvider.notifier);
    final device = state.selected;
    final hw = state.exclusiveRequested && (device?.hardwareVolume ?? false);
    if (hw) {
      await playback.setVolume(volume, software: false);
      await _engine.setHardwareVolume(device!.id, volume);
      return;
    }
    if (state.exclusiveRequested) {
      await playback.setVolume(1.0, software: false);
      _rebuildPath();
      return;
    }
    await playback.setVolume(volume, software: true);
    _rebuildPath();
  }

  /// Mute toggle: mute remembers the current level, unmute restores it
  /// (never jumps to max). No history yet (e.g. slider dragged to zero
  /// then toggled) falls back to full volume.
  Future<void> toggleMute() async {
    final current = _ref.read(playbackServiceProvider).volume;
    if (current <= 0) {
      await setVolume(_preMuteVolume > 0 ? _preMuteVolume : 1.0);
    } else {
      _preMuteVolume = current;
      await setVolume(0);
    }
  }

  Future<void> _onHotplug(Map<String, dynamic> event) async {
    final reason = event['reason']?.toString() ?? '';
    final id = event['id']?.toString() ?? '';
    wasapiLog('Device event: $reason $id');
    final selected = state.selectedId;
    await refreshDevices();
    if (reason == 'removed' && selected.isNotEmpty && selected == id) {
      await _ref.read(playbackServiceProvider.notifier).pause();
      state = state.copyWith(
        path: state.path.copyWith(
          reason: BitPerfectReason.deviceUnavailable,
          error: 'DAC disconnected',
        ),
      );
      return;
    }
    if (reason == 'added' || reason == 'default' || reason == 'state') {
      await applyToPlayer();
    }
  }

  Future<void> _onPlayback(PlayerSnapshot? prev, PlayerSnapshot next) async {
    final prevFmt = _sourceOf(prev?.stream);
    final nextFmt = _sourceOf(next.stream);
    if (nextFmt != null && state.exclusiveRequested) {
      if (prevFmt == null || !prevFmt.matches(nextFmt)) {
        wasapiLog('Format change detected');
        if (prevFmt != null) wasapiLog('Previous: ${prevFmt.label}');
        wasapiLog('Requested: ${nextFmt.label}');
        final device = state.selected;
        if (device != null && device.supports(nextFmt)) {
          wasapiLog('DAC supports requested format');
          wasapiLog('Reinitializing exclusive stream');
        } else {
          wasapiLog('DAC does not list ${nextFmt.label} as exclusive PCM');
        }
        await applyToPlayer();
      }
    }
    if (next.volume != (prev?.volume ?? next.volume)) {
      final device = state.selected;
      if (state.exclusiveRequested && device?.hardwareVolume == true) {
        await _engine.setHardwareVolume(device!.id, next.volume);
      }
    }
    _rebuildPath(snapshot: next);
  }

  PcmFormat? _sourceOf(ResolvedStream? stream) {
    if (stream == null) return null;
    return pcmFromStream(
      bitDepth: stream.bitDepth,
      samplingRateKhz: stream.samplingRateKhz,
    );
  }

  void _rebuildPath({PlayerSnapshot? snapshot}) {
    final PlayerSnapshot snap =
        snapshot ?? _ref.read(playbackServiceProvider);
    final device = state.selected;
    final source = _sourceOf(snap.stream);
    final live = snap.outputFormat;
    final exclusive = state.exclusiveRequested;
    var decision = source == null
        ? null
        : _negotiator.negotiate(
            source: source,
            device: device,
            exclusiveRequested: exclusive,
          );
    if (exclusive && snap.outputIsFloat && source != null) {
      decision = FormatDecision(
        source: source,
        output: live ?? decision?.output,
        nativeMatch: false,
        resampling: true,
        formatConversion: true,
        note: 'Output is float — not bit-perfect',
      );
    } else if (exclusive &&
        live != null &&
        source != null &&
        decision != null &&
        decision.nativeMatch &&
        live.sampleRateHz != source.sampleRateHz) {
      decision = FormatDecision(
        source: source,
        output: live,
        nativeMatch: false,
        resampling: true,
        formatConversion: false,
        note: 'AO sample rate ${live.label} ≠ source ${source.label}',
      );
    }
    final playback = _ref.read(playbackServiceProvider.notifier);
    final hw = exclusive && (device?.hardwareVolume ?? false);
    final softwareVol = !hw && snap.volume < 0.999;
    // "Exclusive" means different things per backend. On Windows the driver
    // opened one of the probed exclusive PCM formats, so a non-null
    // negotiated output is part of the claim. On Linux `ao=alsa` on a raw
    // `hw:` PCM bypasses `dmix`/`plughw` and therefore the mixer, so the
    // claim follows the ao alone. That holds whether or not the native probe
    // measured anything: an unknown format list (no probe in this build, or a
    // PCM that could not be opened) must not veto an ao that did apply, which
    // is why the `_isAlsa` disjunct stays even now that a probed PCM does
    // carry real formats. A probed PCM that does not list the source is then
    // held to the honest reason — resampling or native format unavailable —
    // by `FormatNegotiator.evaluate` below.
    final exclusiveActive = exclusive &&
        playback.exclusiveApplied &&
        playback.wasapiError == null &&
        (device?.exclusiveSupported ?? false) &&
        (_isAlsa || decision?.output != null);
    final reason = _negotiator.evaluate(
      decision: decision ??
          FormatDecision(
            source: source ?? const PcmFormat(sampleRateHz: 44100, bitDepth: 16),
            output: live ?? source,
            nativeMatch: false,
            resampling: true,
            formatConversion: true,
          ),
      exclusiveRequested: exclusive,
      exclusiveActive: exclusiveActive,
      // "Available" is about the DEVICE, not about its probed format list:
      // an ALSA device with empty `formats` is present and must not be
      // reported unavailable — it reports `exclusiveUnavailable`, which
      // is the real (and much smaller) gap.
      //
      // On Linux a null selection is the ALSA default, which exists and
      // plays; it simply cannot be exclusive (there is no `hw:` string to
      // hand libmpv), so that is `exclusiveUnavailable` too.
      //
      // A missing native probe changes none of this: `AlsaEngine` swallows the
      // channel error and returns the same devices from procfs, with `formats`
      // empty, so a fallback list is never mistaken for an absent device.
      deviceAvailable:
          device != null || _isAlsa || !_engine.isSupported,
      dspActive: false,
      peqActive: false,
      softwareVolume: softwareVol,
      crossfade: _ref.read(prefsProvider).crossfadeEnabled,
      speed: snap.speed,
    );
    // Exclusive DAC format is the negotiated integer PCM — never the
    // decoder's s32/float container that media_kit reports as audio-params.
    final output = exclusive
        ? (decision?.output ?? live ?? source)
        : (live ?? source);
    final path = OutputPathStatus(
      deviceName: device?.displayName ?? 'System default',
      deviceId: device?.id ?? '',
      mode: exclusiveActive
          ? WasapiShareMode.exclusive
          : WasapiShareMode.shared,
      exclusiveRequested: exclusive,
      exclusiveActive: exclusiveActive,
      source: source,
      output: output,
      resampling: decision?.resampling ?? false,
      dspActive: false,
      peqActive: false,
      softwareVolume: softwareVol,
      hardwareVolume: hw,
      crossfade: _ref.read(prefsProvider).crossfadeEnabled,
      speed: snap.speed,
      reason: reason,
      error: playback.wasapiError,
    );
    state = state.copyWith(
      path: path,
      lastOpenedFormat: source ?? state.lastOpenedFormat,
    );
    final line =
        'Device: ${path.deviceName} Exclusive: ${path.exclusiveActive} '
        'Source: ${path.sourceLabel} Output: ${path.outputLabel} '
        'Resampling: ${path.resampling} DSP: ${path.dspActive} '
        'Software Volume: ${path.softwareVolume} Hardware Volume: ${path.hardwareVolume} '
        'Bit-Perfect: ${path.bitPerfect}';
    if (line != _lastLogged) {
      _lastLogged = line;
      wasapiLog(line);
      if (output != null) {
        wasapiLog('New format active: ${output.label}');
      }
    }
  }

  void _logCaps() {
    final device = state.selected;
    if (device == null) return;
    wasapiLog('Device: ${device.displayName}');
    wasapiLog('Exclusive Mode: ${device.exclusiveSupported}');
    wasapiLog('Hardware Volume: ${device.hardwareVolume}');
    for (final line in device.supportedSummary.split('\n')) {
      wasapiLog('PCM $line');
    }
  }
}

final audioOutputProvider =
    StateNotifierProvider<AudioOutputController, AudioOutputState>((ref) {
  final controller = AudioOutputController(ref);
  ref.listen<PlayerSnapshot>(playbackServiceProvider, (prev, next) {
    unawaited(controller.onPlaybackChanged(prev, next));
  });
  return controller;
});
