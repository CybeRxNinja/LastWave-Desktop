import 'dart:io' show Platform;

import 'dac_device.dart';
import 'output_path_status.dart';
import 'pcm_format.dart';

/// Negotiates a DAC exclusive format from the source PCM.
///
/// Exact source match is required for a native/bit-perfect decision.
/// Fallbacks never pretend to be bit-perfect.
class FormatNegotiator {
  const FormatNegotiator();

  FormatDecision negotiate({
    required PcmFormat source,
    required DacDevice? device,
    required bool exclusiveRequested,
  }) {
    if (device == null) {
      return FormatDecision(
        source: source,
        output: exclusiveRequested ? null : source,
        nativeMatch: false,
        resampling: exclusiveRequested,
        formatConversion: exclusiveRequested,
        note: exclusiveRequested
            ? 'No output device selected'
            : (Platform.isLinux
                ? 'ALSA Shared — mixer may resample'
                : 'Shared mode — Windows mixer may resample'),
      );
    }

    if (!exclusiveRequested) {
      return FormatDecision(
        source: source,
        output: source,
        nativeMatch: false,
        resampling: true,
        formatConversion: true,
        note: device.enumerator == 'alsa'
            ? 'ALSA Shared — mixer may resample'
            : 'WASAPI Shared — Windows mixer in path',
      );
    }

    if (!device.exclusiveSupported || device.formats.isEmpty) {
      return FormatDecision(
        source: source,
        output: null,
        nativeMatch: false,
        resampling: true,
        formatConversion: true,
        // An ALSA device ALWAYS lands here: probing a PCM needs
        // alsa-lib, so `formats` is empty by construction and the empty
        // list must not read as "this DAC cannot do it".
        note: device.enumerator == 'alsa'
            ? 'ALSA exclusive unavailable / unknown format (no native probe)'
            : 'WASAPI Exclusive unavailable on ${device.name}',
      );
    }

    if (device.supports(source)) {
      return FormatDecision(
        source: source,
        output: source,
        nativeMatch: true,
        resampling: false,
        formatConversion: false,
        note: 'DAC supports ${source.label}',
      );
    }

    final sameRate = device.formats
        .where((f) =>
            f.sampleRateHz == source.sampleRateHz &&
            f.channels == source.channels)
        .toList()
      ..sort((a, b) => b.bitDepth.compareTo(a.bitDepth));
    if (sameRate.isNotEmpty) {
      final pick = _closestDepth(sameRate, source.bitDepth);
      return FormatDecision(
        source: source,
        output: pick,
        nativeMatch: false,
        resampling: false,
        formatConversion: pick.bitDepth != source.bitDepth,
        note: 'Native bit depth unavailable — using ${pick.label}',
      );
    }

    final sameDepth = device.formats
        .where((f) =>
            f.bitDepth == source.bitDepth && f.channels == source.channels)
        .toList()
      ..sort((a, b) => a.sampleRateHz.compareTo(b.sampleRateHz));
    if (sameDepth.isNotEmpty) {
      final pick = _closestRate(sameDepth, source.sampleRateHz);
      return FormatDecision(
        source: source,
        output: pick,
        nativeMatch: false,
        resampling: true,
        formatConversion: false,
        note: 'Native sample rate unavailable — using ${pick.label}',
      );
    }

    if (device.formats.isNotEmpty) {
      final pick = _closestOverall(device.formats, source);
      return FormatDecision(
        source: source,
        output: pick,
        nativeMatch: false,
        resampling: pick.sampleRateHz != source.sampleRateHz,
        formatConversion: pick.bitDepth != source.bitDepth,
        note: 'Native format unavailable — using ${pick.label}',
      );
    }

    return FormatDecision(
      source: source,
      output: null,
      nativeMatch: false,
      resampling: true,
      formatConversion: true,
      note: 'No compatible exclusive PCM format',
    );
  }

  BitPerfectReason evaluate({
    required FormatDecision decision,
    required bool exclusiveRequested,
    required bool exclusiveActive,
    required bool deviceAvailable,
    required bool dspActive,
    required bool peqActive,
    required bool softwareVolume,
    required bool crossfade,
    required double speed,
  }) {
    if (!deviceAvailable) return BitPerfectReason.deviceUnavailable;
    if (peqActive) return BitPerfectReason.peqActive;
    if (dspActive) return BitPerfectReason.dspActive;
    if (crossfade) return BitPerfectReason.crossfadeActive;
    if ((speed - 1.0).abs() > 0.001) return BitPerfectReason.speedNotUnity;
    if (!exclusiveRequested || !exclusiveActive) {
      return exclusiveRequested
          ? BitPerfectReason.exclusiveUnavailable
          : BitPerfectReason.sharedMode;
    }
    if (decision.output == null) {
      // ALSA cannot reach here with a real format: `ao=alsa` is applied
      // regardless, so `exclusiveActive` is decided by the ao and the
      // missing output means "no native probe said what it is", not "no
      // native format exists". Windows keeps `formatUnsupported` — there
      // it is unreachable anyway, since a null output also forces
      // `exclusiveActive` false one branch earlier.
      return Platform.isLinux
          ? BitPerfectReason.exclusiveUnavailable
          : BitPerfectReason.formatUnsupported;
    }
    if (decision.resampling) return BitPerfectReason.resampling;
    if (decision.formatConversion || !decision.nativeMatch) {
      return BitPerfectReason.formatConversion;
    }
    if (softwareVolume) return BitPerfectReason.softwareVolume;
    return BitPerfectReason.bitPerfect;
  }

  PcmFormat _closestDepth(List<PcmFormat> options, int depth) {
    PcmFormat best = options.first;
    var bestDelta = (best.bitDepth - depth).abs();
    for (final f in options) {
      final d = (f.bitDepth - depth).abs();
      if (d < bestDelta) {
        best = f;
        bestDelta = d;
      }
    }
    return best;
  }

  PcmFormat _closestRate(List<PcmFormat> options, int rate) {
    PcmFormat best = options.first;
    var bestDelta = (best.sampleRateHz - rate).abs();
    for (final f in options) {
      final d = (f.sampleRateHz - rate).abs();
      if (d < bestDelta) {
        best = f;
        bestDelta = d;
      }
    }
    return best;
  }

  PcmFormat _closestOverall(List<PcmFormat> options, PcmFormat source) {
    PcmFormat best = options.first;
    var bestScore = 1 << 30;
    for (final f in options) {
      final score = (f.sampleRateHz - source.sampleRateHz).abs() +
          (f.bitDepth - source.bitDepth).abs() * 4000;
      if (score < bestScore) {
        best = f;
        bestScore = score;
      }
    }
    return best;
  }
}
