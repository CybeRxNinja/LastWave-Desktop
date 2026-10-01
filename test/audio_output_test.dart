import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/audio_output/alsa_engine.dart';
import 'package:lastwave_desktop/features/audio_output/dac_device.dart';
import 'package:lastwave_desktop/features/audio_output/format_negotiator.dart';
import 'package:lastwave_desktop/features/audio_output/output_controller.dart';
import 'package:lastwave_desktop/features/audio_output/output_path_status.dart';
import 'package:lastwave_desktop/features/audio_output/pcm_format.dart';
import 'package:lastwave_desktop/features/audio_output/wasapi_engine.dart';

void main() {
  const negotiator = FormatNegotiator();

  DacDevice dac({
    bool exclusive = true,
    List<PcmFormat> formats = const [
      PcmFormat(sampleRateHz: 44100, bitDepth: 16),
      PcmFormat(sampleRateHz: 48000, bitDepth: 16),
      PcmFormat(sampleRateHz: 44100, bitDepth: 24),
      PcmFormat(sampleRateHz: 48000, bitDepth: 24),
      PcmFormat(sampleRateHz: 88200, bitDepth: 24),
      PcmFormat(sampleRateHz: 96000, bitDepth: 24),
      PcmFormat(sampleRateHz: 176400, bitDepth: 24),
      PcmFormat(sampleRateHz: 192000, bitDepth: 24),
    ],
  }) =>
      DacDevice(
        id: 'dac',
        name: 'FiiO K7',
        exclusiveSupported: exclusive,
        hardwareVolume: true,
        formats: formats,
      );

  group('native format match', () {
    test('16/44.1 stays 16/44.1', () {
      const source = PcmFormat(sampleRateHz: 44100, bitDepth: 16);
      final d = negotiator.negotiate(
        source: source,
        device: dac(),
        exclusiveRequested: true,
      );
      expect(d.nativeMatch, isTrue);
      expect(d.output, source);
      expect(d.resampling, isFalse);
    });

    test('24/44.1 stays 24/44.1', () {
      const source = PcmFormat(sampleRateHz: 44100, bitDepth: 24);
      final d = negotiator.negotiate(
        source: source,
        device: dac(),
        exclusiveRequested: true,
      );
      expect(d.output, source);
      expect(d.nativeMatch, isTrue);
    });

    test('24/48 stays 24/48', () {
      const source = PcmFormat(sampleRateHz: 48000, bitDepth: 24);
      final d = negotiator.negotiate(
        source: source,
        device: dac(),
        exclusiveRequested: true,
      );
      expect(d.output, source);
    });

    test('24/96 stays 24/96', () {
      const source = PcmFormat(sampleRateHz: 96000, bitDepth: 24);
      final d = negotiator.negotiate(
        source: source,
        device: dac(),
        exclusiveRequested: true,
      );
      expect(d.output, source);
      expect(d.resampling, isFalse);
    });

    test('24/192 stays 24/192', () {
      const source = PcmFormat(sampleRateHz: 192000, bitDepth: 24);
      final d = negotiator.negotiate(
        source: source,
        device: dac(),
        exclusiveRequested: true,
      );
      expect(d.output, source);
    });
  });

  group('fallback is explicit', () {
    test('44.1 → 48 when 44.1 missing', () {
      const source = PcmFormat(sampleRateHz: 44100, bitDepth: 24);
      final d = negotiator.negotiate(
        source: source,
        device: dac(formats: const [
          PcmFormat(sampleRateHz: 48000, bitDepth: 24),
          PcmFormat(sampleRateHz: 96000, bitDepth: 24),
        ]),
        exclusiveRequested: true,
      );
      expect(d.nativeMatch, isFalse);
      expect(d.resampling, isTrue);
      expect(d.output?.sampleRateHz, 48000);
    });

    test('unsupported 384 kHz does not claim native', () {
      const source = PcmFormat(sampleRateHz: 384000, bitDepth: 32);
      final d = negotiator.negotiate(
        source: source,
        device: dac(),
        exclusiveRequested: true,
      );
      expect(d.nativeMatch, isFalse);
      expect(d.note.toLowerCase(), contains('unavailable'));
    });

    test('shared mode never matches native', () {
      const source = PcmFormat(sampleRateHz: 96000, bitDepth: 24);
      final d = negotiator.negotiate(
        source: source,
        device: dac(),
        exclusiveRequested: false,
      );
      expect(d.nativeMatch, isFalse);
      expect(d.note.toLowerCase(), contains('shared'));
    });
  });

  group('bit-perfect state machine', () {
    FormatDecision native() => negotiator.negotiate(
          source: const PcmFormat(sampleRateHz: 96000, bitDepth: 24),
          device: dac(),
          exclusiveRequested: true,
        );

    test('exclusive + native + no DSP + unity volume = bit-perfect', () {
      expect(
        negotiator.evaluate(
          decision: native(),
          exclusiveRequested: true,
          exclusiveActive: true,
          deviceAvailable: true,
          dspActive: false,
          peqActive: false,
          softwareVolume: false,
          crossfade: false,
          speed: 1.0,
        ),
        BitPerfectReason.bitPerfect,
      );
    });

    test('PEQ blocks bit-perfect', () {
      expect(
        negotiator.evaluate(
          decision: native(),
          exclusiveRequested: true,
          exclusiveActive: true,
          deviceAvailable: true,
          dspActive: false,
          peqActive: true,
          softwareVolume: false,
          crossfade: false,
          speed: 1.0,
        ),
        BitPerfectReason.peqActive,
      );
    });

    test('software volume blocks bit-perfect', () {
      expect(
        negotiator.evaluate(
          decision: native(),
          exclusiveRequested: true,
          exclusiveActive: true,
          deviceAvailable: true,
          dspActive: false,
          peqActive: false,
          softwareVolume: true,
          crossfade: false,
          speed: 1.0,
        ),
        BitPerfectReason.softwareVolume,
      );
    });

    test('shared mode is not bit-perfect', () {
      expect(
        negotiator.evaluate(
          decision: native(),
          exclusiveRequested: false,
          exclusiveActive: false,
          deviceAvailable: true,
          dspActive: false,
          peqActive: false,
          softwareVolume: false,
          crossfade: false,
          speed: 1.0,
        ),
        BitPerfectReason.sharedMode,
      );
    });

    test('same-format consecutive tracks stay native', () {
      const a = PcmFormat(sampleRateHz: 96000, bitDepth: 24);
      const b = PcmFormat(sampleRateHz: 96000, bitDepth: 24);
      expect(a.matches(b), isTrue);
    });

    test('different-format tracks require a new exclusive format', () {
      const a = PcmFormat(sampleRateHz: 44100, bitDepth: 16);
      const b = PcmFormat(sampleRateHz: 96000, bitDepth: 24);
      expect(a.matches(b), isFalse);
      final next = negotiator.negotiate(
        source: b,
        device: dac(),
        exclusiveRequested: true,
      );
      expect(next.output, b);
    });
  });

  group('rate/depth fallbacks', () {
    test('44.1 → 96 when only 96 is listed', () {
      const source = PcmFormat(sampleRateHz: 44100, bitDepth: 24);
      final d = negotiator.negotiate(
        source: source,
        device: dac(formats: const [
          PcmFormat(sampleRateHz: 96000, bitDepth: 24),
        ]),
        exclusiveRequested: true,
      );
      expect(d.resampling, isTrue);
      expect(d.nativeMatch, isFalse);
      expect(d.output?.sampleRateHz, 96000);
    });

    test('96 → 192 when 96 is missing', () {
      const source = PcmFormat(sampleRateHz: 96000, bitDepth: 24);
      final d = negotiator.negotiate(
        source: source,
        device: dac(formats: const [
          PcmFormat(sampleRateHz: 192000, bitDepth: 24),
        ]),
        exclusiveRequested: true,
      );
      expect(d.resampling, isTrue);
      expect(d.output?.sampleRateHz, 192000);
    });

    test('unsupported bit depth does not claim native', () {
      const source = PcmFormat(sampleRateHz: 96000, bitDepth: 32);
      final d = negotiator.negotiate(
        source: source,
        device: dac(),
        exclusiveRequested: true,
      );
      expect(d.nativeMatch, isFalse);
      expect(d.formatConversion, isTrue);
    });
  });

  group('status reasons', () {
    FormatDecision native() => negotiator.negotiate(
          source: const PcmFormat(sampleRateHz: 96000, bitDepth: 24),
          device: dac(),
          exclusiveRequested: true,
        );

    test('exclusive failure is exclusiveUnavailable', () {
      expect(
        negotiator.evaluate(
          decision: native(),
          exclusiveRequested: true,
          exclusiveActive: false,
          deviceAvailable: true,
          dspActive: false,
          peqActive: false,
          softwareVolume: false,
          crossfade: false,
          speed: 1.0,
        ),
        BitPerfectReason.exclusiveUnavailable,
      );
    });

    test('device missing is deviceUnavailable', () {
      expect(
        negotiator.evaluate(
          decision: native(),
          exclusiveRequested: true,
          exclusiveActive: false,
          deviceAvailable: false,
          dspActive: false,
          peqActive: false,
          softwareVolume: false,
          crossfade: false,
          speed: 1.0,
        ),
        BitPerfectReason.deviceUnavailable,
      );
    });

    test('crossfade blocks bit-perfect', () {
      expect(
        negotiator.evaluate(
          decision: native(),
          exclusiveRequested: true,
          exclusiveActive: true,
          deviceAvailable: true,
          dspActive: false,
          peqActive: false,
          softwareVolume: false,
          crossfade: true,
          speed: 1.0,
        ),
        BitPerfectReason.crossfadeActive,
      );
    });

    test('DSP blocks bit-perfect', () {
      expect(
        negotiator.evaluate(
          decision: native(),
          exclusiveRequested: true,
          exclusiveActive: true,
          deviceAvailable: true,
          dspActive: true,
          peqActive: false,
          softwareVolume: false,
          crossfade: false,
          speed: 1.0,
        ),
        BitPerfectReason.dspActive,
      );
    });

    test('exclusive unavailable on device', () {
      const source = PcmFormat(sampleRateHz: 96000, bitDepth: 24);
      final d = negotiator.negotiate(
        source: source,
        device: dac(exclusive: false, formats: const []),
        exclusiveRequested: true,
      );
      expect(d.nativeMatch, isFalse);
      expect(d.output, isNull);
      expect(
        negotiator.evaluate(
          decision: d,
          exclusiveRequested: true,
          exclusiveActive: false,
          deviceAvailable: true,
          dspActive: false,
          peqActive: false,
          softwareVolume: false,
          crossfade: false,
          speed: 1.0,
        ),
        BitPerfectReason.exclusiveUnavailable,
      );
    });
  });

  group('24-bit is not reported as 32-bit', () {
    test('DAC with 24 and 32 keeps 24-bit source native', () {
      const source = PcmFormat(sampleRateHz: 44100, bitDepth: 24);
      final d = negotiator.negotiate(
        source: source,
        device: dac(formats: const [
          PcmFormat(sampleRateHz: 44100, bitDepth: 16),
          PcmFormat(sampleRateHz: 44100, bitDepth: 24),
          PcmFormat(sampleRateHz: 44100, bitDepth: 32),
        ]),
        exclusiveRequested: true,
      );
      expect(d.nativeMatch, isTrue);
      expect(d.output?.bitDepth, 24);
      expect(d.formatConversion, isFalse);
    });

    test('s32 container with forced s24 is 24-bit', () {
      expect(bitDepthFromMpvFormat('s32', forcedFormat: 's24'), 24);
      expect(bitDepthFromMpvFormat('s24'), 24);
      expect(mpvFormatIsFloat('float'), isTrue);
      expect(mpvSampleFormat(24), 's24');
    });

    test('audio-out-params float is not a PCM match', () {
      expect(
        pcmFromMpvOutParams(
          'samplerate=44100,format=float,channel-count=2',
          forcedFormat: 's24',
        ),
        isNull,
      );
      expect(
        pcmFromMpvOutParams(
          'samplerate=44100,format=s32,channel-count=2',
          forcedFormat: 's24',
        ),
        const PcmFormat(sampleRateHz: 44100, bitDepth: 24, channels: 2),
      );
    });
  });

  // ---------------------------------------------------------------------
  // Linux / ALSA
  //
  // Windows behaviour above must not move: every assertion in those
  // groups runs on the same `negotiator` and `dac()` and is platform
  // independent.
  // ---------------------------------------------------------------------

  group('mpvDeviceName is enumerator-aware', () {
    DacDevice withId(String id, {String enumerator = ''}) =>
        DacDevice(id: id, name: 'x', enumerator: enumerator);

    test('a raw hw: PCM is handed to libmpv verbatim', () {
      // Prefix it with alsa/ and libmpv resolves the name through the
      // conversion plugin — which is a mixer in the path, i.e. shared.
      expect(
        withId('hw:CARD=PCH,DEV=0', enumerator: 'alsa').mpvDeviceName,
        'hw:CARD=PCH,DEV=0',
      );
    });

    test('plughw and alsa/ ids are already fully qualified', () {
      expect(
        withId('plughw:CARD=PCH,DEV=0').mpvDeviceName,
        'plughw:CARD=PCH,DEV=0',
      );
      expect(
        withId('alsa/hw:CARD=PCH,DEV=0').mpvDeviceName,
        'alsa/hw:CARD=PCH,DEV=0',
      );
    });

    test('a wasapi enumerator keeps the wasapi/ prefix', () {
      expect(
        withId('{0.0.0.00000000}.{guid}', enumerator: 'wasapi')
            .mpvDeviceName,
        startsWith('wasapi/'),
      );
    });

    test('an ALSA id with no enumerator falls back to alsa/', () {
      // A persisted preference written before this rule has no enumerator
      // on it; it still must not be handed to libmpv as `wasapi/...`.
      expect(
        withId('default').mpvDeviceName,
        'alsa/default',
      );
    });

    test('no id means the system default', () {
      expect(withId('').mpvDeviceName, 'auto');
    });
  });

  group('engine selection per platform', () {
    test('Linux gets the ALSA engine, everything else the WASAPI one', () {
      expect(audioOutputEngineFor(linux: true), isA<AlsaEngine>());
      expect(audioOutputEngineFor(linux: false), isA<WasapiEngine>());
    });

    test('the chosen engine gates on the real platform', () {
      expect((audioOutputEngineFor(linux: true) as AlsaEngine).isSupported,
          Platform.isLinux);
      expect((audioOutputEngineFor(linux: false) as WasapiEngine).isSupported,
          Platform.isWindows);
    });

    test('off both platforms WASAPI is returned but unsupported', () {
      // Not a throw and not a null engine: the status machine keeps
      // running and reports "device unavailable" honestly.
      final engine = audioOutputEngineFor(linux: false) as WasapiEngine;
      expect(engine.isSupported, Platform.isWindows);
    });
  });

  group('ALSA status with unknown formats', () {
    // What the pure-Dart engine actually produces: exclusiveSupported
    // true, hardwareVolume false, formats empty.
    const alsaDac = DacDevice(
      id: 'hw:CARD=PCH,DEV=0',
      name: 'HDA Intel PCH',
      enumerator: 'alsa',
      exclusiveSupported: true,
    );
    const source = PcmFormat(sampleRateHz: 96000, bitDepth: 24);

    test('empty formats never negotiate an output format', () {
      final d = negotiator.negotiate(
        source: source,
        device: alsaDac,
        exclusiveRequested: true,
      );
      expect(d.output, isNull);
      expect(d.nativeMatch, isFalse);
    });

    test('the note says unknown-format rather than blaming the DAC', () {
      final d = negotiator.negotiate(
        source: source,
        device: alsaDac,
        exclusiveRequested: true,
      );
      expect(d.note, contains('ALSA'));
      expect(d.note, isNot(contains('WASAPI')));
    });

    test('shared mode note names ALSA', () {
      final d = negotiator.negotiate(
        source: source,
        device: alsaDac,
        exclusiveRequested: false,
      );
      expect(d.note, 'ALSA Shared — mixer may resample');
      expect(d.nativeMatch, isFalse);
    });

    test('an applied ALSA ao never claims bit-perfect with no probe', () {
      // exclusiveActive true (ao=alsa on a raw hw: PCM really did apply)
      // but decision.output is null because nothing was probed.
      final reason = negotiator.evaluate(
        decision: negotiator.negotiate(
          source: source,
          device: alsaDac,
          exclusiveRequested: true,
        ),
        exclusiveRequested: true,
        exclusiveActive: true,
        deviceAvailable: true,
        dspActive: false,
        peqActive: false,
        softwareVolume: false,
        crossfade: false,
        speed: 1.0,
      );
      // The claim is withheld either way; only the wording is per-platform.
      expect(reason, isNot(BitPerfectReason.bitPerfect));
      expect(
        reason,
        Platform.isLinux
            ? BitPerfectReason.exclusiveUnavailable
            : BitPerfectReason.formatUnsupported,
      );
    });

    test('a Windows device with empty formats still blames the device', () {
      // Same input shape, different backend: the Windows note must not
      // have been softened by the Linux branch.
      final d = negotiator.negotiate(
        source: source,
        device: dac(exclusive: true, formats: const []),
        exclusiveRequested: true,
      );
      expect(d.note, startsWith('WASAPI Exclusive unavailable on'));
    });
  });

  group('ALSA reason strings', () {
    test('sharedMode label names the ALSA mixer on Linux', () {
      final label = BitPerfectReason.sharedMode.label;
      if (Platform.isLinux) {
        expect(label, 'ALSA Shared — mixer may resample');
      } else {
        expect(label, isNot(contains('ALSA')));
      }
    });

    test('exclusiveUnavailable label names the missing native probe', () {
      final label = BitPerfectReason.exclusiveUnavailable.label;
      if (Platform.isLinux) {
        expect(label, contains('ALSA'));
        expect(label, contains('no native probe'));
      } else {
        // Windows (and every other platform) keep the string unchanged.
        expect(label, 'WASAPI Exclusive unavailable');
      }
    });

    test('an ALSA device with no formats is not reported unavailable', () {
      const status = OutputPathStatus(
        deviceId: 'hw:CARD=PCH,DEV=0',
        deviceName: 'HDA Intel PCH',
        exclusiveRequested: true,
        reason: BitPerfectReason.exclusiveUnavailable,
      );
      expect(status.bitPerfect, isFalse);
      expect(status.reason, isNot(BitPerfectReason.deviceUnavailable));
      expect(status.deviceId, isNotEmpty);
    });

    test('an ALSA device says so instead of claiming no formats', () {
      const status = DacDevice(
        id: 'hw:CARD=PCH,DEV=0',
        name: 'HDA Intel PCH',
        enumerator: 'alsa',
      );
      expect(status.supportedSummary, contains('ALSA'));
      expect(status.supportedSummary, isNot(contains('No exclusive')));
    });
  });

  // The payload below is the native `lastwave/alsa` device map, key for key:
  // `id` is `hw:<card id from snd_ctl_card_info_get_id>,DEV=<pcm index>` and
  // `formats` holds the alsa-lib measurement, which is EMPTY when the PCM
  // could not be opened — unknown, never fabricated.
  const nativePcm = {
    'id': 'hw:CARD=PCH,DEV=0',
    'name': 'HDA Intel PCH, ALC295 Analog',
    'manufacturer': '',
    'enumerator': 'alsa',
    'isDefault': true,
    'exclusiveSupported': true,
    'hardwareVolume': false,
    'formats': <Object?>[
      {'sampleRateHz': 44100, 'bitDepth': 16, 'channels': 2},
      {'sampleRateHz': 48000, 'bitDepth': 24, 'channels': 2},
      {'sampleRateHz': 96000, 'bitDepth': 24, 'channels': 2},
    ],
  };
  const nativeSource = PcmFormat(sampleRateHz: 96000, bitDepth: 24);

  group('ALSA native probe drives the verdict', () {
    test('the native device map is read exactly as sent', () {
      final probed = DacDevice.fromJson(nativePcm);
      expect(probed.id, 'hw:CARD=PCH,DEV=0');
      expect(probed.enumerator, 'alsa');
      expect(probed.isDefault, isTrue);
      expect(probed.exclusiveSupported, isTrue);
      // No control-ABI path on ALSA, so the hardware-volume knob stays hidden.
      expect(probed.hardwareVolume, isFalse);
      expect(probed.mpvDeviceName, 'hw:CARD=PCH,DEV=0');
      expect(
        probed.formats.map((f) => '${f.label} x${f.channels}').toList(),
        ['16-bit / 44.1 kHz x2', '24-bit / 48 kHz x2', '24-bit / 96 kHz x2'],
      );
      expect(probed.supports(nativeSource), isTrue);
    });

    test('a probed ALSA PCM with a matching format is bit-perfect', () {
      final probed = DacDevice.fromJson(nativePcm);
      final d = negotiator.negotiate(
        source: nativeSource,
        device: probed,
        exclusiveRequested: true,
      );
      expect(d.output, nativeSource);
      expect(d.nativeMatch, isTrue);
      expect(d.resampling, isFalse);
      expect(d.formatConversion, isFalse);
      // The point of the probe: on Linux this verdict used to be unreachable,
      // because every ALSA device negotiated a null output.
      expect(
        negotiator.evaluate(
          decision: d,
          exclusiveRequested: true,
          exclusiveActive: true,
          deviceAvailable: true,
          dspActive: false,
          peqActive: false,
          softwareVolume: false,
          crossfade: false,
          speed: 1.0,
        ),
        BitPerfectReason.bitPerfect,
      );
    });

    test('a probed ALSA PCM with exclusive inactive is not bit-perfect', () {
      final d = negotiator.negotiate(
        source: nativeSource,
        device: DacDevice.fromJson(nativePcm),
        exclusiveRequested: true,
      );
      // The format is real and matches, but the ao never applied, so the
      // claim is withheld for the exclusive reason, not a format reason.
      expect(d.nativeMatch, isTrue);
      expect(
        negotiator.evaluate(
          decision: d,
          exclusiveRequested: true,
          exclusiveActive: false,
          deviceAvailable: true,
          dspActive: false,
          peqActive: false,
          softwareVolume: false,
          crossfade: false,
          speed: 1.0,
        ),
        BitPerfectReason.exclusiveUnavailable,
      );
    });

    test('a probed PCM with EMPTY formats stays on the unknown-format reason',
        () {
      // Exactly what the native side sends for a PCM it could not open: the
      // device is present, `formats` is empty, and empty means unknown.
      final unprobed = DacDevice.fromJson({
        ...nativePcm,
        'formats': <Object?>[],
      });
      expect(unprobed.formats, isEmpty);
      expect(unprobed.supports(nativeSource), isFalse);
      final d = negotiator.negotiate(
        source: nativeSource,
        device: unprobed,
        exclusiveRequested: true,
      );
      expect(d.output, isNull);
      expect(d.nativeMatch, isFalse);
      expect(
        d.note,
        'ALSA exclusive unavailable / unknown format (PCM not measured)',
      );
      final reason = negotiator.evaluate(
        decision: d,
        exclusiveRequested: true,
        exclusiveActive: true,
        deviceAvailable: true,
        dspActive: false,
        peqActive: false,
        softwareVolume: false,
        crossfade: false,
        speed: 1.0,
      );
      expect(reason, isNot(BitPerfectReason.bitPerfect));
      expect(
        reason,
        Platform.isLinux
            ? BitPerfectReason.exclusiveUnavailable
            : BitPerfectReason.formatUnsupported,
      );
    });

    test('a MissingPluginException answer degrades to the procfs list', () {
      // A build without the probe, a host that never registered the channel,
      // and a probe that raised all leave the device list to procfs.
      final missing = MissingPluginException(
        'No implementation found for method lastwave/alsa.enumerateDevices '
        'on channel lastwave/alsa',
      );
      final procfs = parseAlsaDevices(
        cardsRaw: ' 0 [PCH   ]: PCH - HDA Intel PCH\n',
        streams: const {0: [0]},
        defaultLink: 'card0',
      );
      // The engine reads `alsaDevicesFromNative(answer) ?? _enumerateProcfs()`,
      // so a null answer IS the procfs list: same device, formats unknown,
      // and still exclusive-capable rather than "unavailable".
      expect(alsaDevicesFromNative(missing), isNull);
      expect(alsaDevicesFromNative(missing) ?? procfs, procfs);
      expect(alsaDeviceFromNative(missing), isNull);
      expect(procfs.single.id, 'hw:CARD=PCH,DEV=0');
      expect(procfs.single.exclusiveSupported, isTrue);
      expect(procfs.single.formats, isEmpty);
      // A silent or malformed channel is not an answer either.
      expect(alsaDevicesFromNative(null), isNull);
      expect(alsaDevicesFromNative(<Object?>[]), isNull);
      expect(alsaDevicesFromNative(<Object?>[42, 'garbage']), isNull);
      // A real native list wins over the fallback, measured formats included.
      expect(alsaDevicesFromNative([nativePcm])!.single.formats.length, 3);
      expect(alsaDeviceFromNative(nativePcm)!.supports(nativeSource), isTrue);
      // A probed-but-unmeasurable PCM is still an answer: the device stays
      // present with `formats` empty, never dropped and never filled in.
      final unmeasurable =
          alsaDeviceFromNative({...nativePcm, 'formats': <Object?>[]});
      expect(unmeasurable, isNotNull);
      expect(unmeasurable!.id, 'hw:CARD=PCH,DEV=0');
      expect(unmeasurable.formats, isEmpty);
    });

    test('the Windows exclusive reason strings are unchanged', () {
      // The Linux branch must not have leaked into any Windows note.
      expect(
        negotiator.negotiate(
          source: nativeSource,
          device: dac(exclusive: false, formats: const []),
          exclusiveRequested: true,
        ).note,
        'WASAPI Exclusive unavailable on FiiO K7',
      );
      expect(
        negotiator.negotiate(
          source: nativeSource,
          device: dac(),
          exclusiveRequested: false,
        ).note,
        'WASAPI Shared — Windows mixer in path',
      );
      // The null-device shared note is the one string here that is selected by
      // platform rather than by enumerator (there is no device to carry an
      // enumerator), so it is asserted per platform. Both texts are unchanged.
      expect(
        negotiator.negotiate(
          source: nativeSource,
          device: null,
          exclusiveRequested: false,
        ).note,
        Platform.isLinux
            ? 'ALSA Shared — mixer may resample'
            : 'Shared mode — Windows mixer may resample',
      );
      // The format fallbacks a Windows device gets are still the same ones.
      expect(
        negotiator.negotiate(
          source: const PcmFormat(sampleRateHz: 96000, bitDepth: 32),
          device: dac(),
          exclusiveRequested: true,
        ).note,
        'Native bit depth unavailable — using 24-bit / 96 kHz',
      );
      // And the null-output label keeps its own per-platform text.
      final label = BitPerfectReason.exclusiveUnavailable.label;
      if (Platform.isLinux) {
        expect(label, contains('ALSA'));
      } else {
        expect(label, 'WASAPI Exclusive unavailable');
      }
    });
  });
}
