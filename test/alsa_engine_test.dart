import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/audio_output/alsa_engine.dart';
import 'package:lastwave_desktop/features/audio_output/dac_device.dart';
import 'package:lastwave_desktop/features/audio_output/pcm_format.dart';

void main() {
  const pcm = PcmFormat(sampleRateHz: 44100, bitDepth: 16);

  // A realistic /proc/asound/cards body: three cards, two of them with the
  // per-device continuation lines the kernel appends below the card header.
  const cards = '''
 0 [PCH       ]: PCH - HDA Intel PCH
                  ALC295 Analog      : : : : : : :
 1 [Device    ]: USB - Audio Class Gadget
 2 [HDMI      ]: HDA - HDA Intel HDMI
                  ELPIDA Audio       : : : : : : :
''';

  group('parseAlsaCards', () {
    test('reads index, card id and long name', () {
      final parsed = parseAlsaCards(cards);
      expect(parsed.length, 3);
      expect(parsed[0].index, 0);
      expect(parsed[0].id, 'PCH');
      expect(parsed[0].name, 'HDA Intel PCH');
      expect(parsed[1].index, 1);
      expect(parsed[1].id, 'Device');
      expect(parsed[1].name, 'Audio Class Gadget');
      expect(parsed[2].id, 'HDMI');
      expect(parsed[2].name, 'HDA Intel HDMI');
    });

    test('driver half is dropped, padded id is trimmed', () {
      final parsed = parseAlsaCards(' 7 [  Analog Output ]: USB - Out\n');
      expect(parsed.single.index, 7);
      expect(parsed.single.id, 'Analog Output');
      expect(parsed.single.name, 'Out');
    });

    test('card id may contain spaces and dashes', () {
      final parsed = parseAlsaCards(' 0 [my-dac      ]: snd-usb - My DAC\n');
      expect(parsed.single.id, 'my-dac');
      expect(parsed.single.name, 'My DAC');
    });

    test('missing driver half keeps the whole remainder as name', () {
      expect(parseAlsaCards(' 0 [Card  ]:  Bare Name\n').single.name,
          'Bare Name');
    });

    test('empty and garbage input is an empty list, not a throw', () {
      expect(parseAlsaCards(''), isEmpty);
      expect(parseAlsaCards('\n\n   \n'), isEmpty);
      expect(parseAlsaCards('garbage\n\x00  ?? \nnot a card'), isEmpty);
    });

    test('a card header with no id is dropped', () {
      expect(parseAlsaCards(' 0 []: x - y\n 1 [ok]: x - y\n').single.id, 'ok');
    });
  });

  group('parsePlaybackStreams', () {
    test('keeps only p<n> playback streams, numerically ordered', () {
      const listing = 'oss\npcm0c\npcm10p\npcm1p\npcm2c\nmidi0\n';
      expect(parsePlaybackStreams(listing), [1, 10]);
    });

    test('capture-only card has no playback streams', () {
      expect(parsePlaybackStreams('pcm0c\npcm1c\n'), isEmpty);
    });

    test('empty, garbage and plugin names yield nothing', () {
      expect(parsePlaybackStreams(''), isEmpty);
      expect(parsePlaybackStreams('plughw\ndmix\ndsnoop\nsurround21\n'),
          isEmpty);
      expect(parsePlaybackStreams('pcm\npcmXp\npcm1\np2p\n'), isEmpty);
    });
  });

  group('parseAlsaDeviceId', () {
    test('splits the id contract', () {
      final parsed = parseAlsaDeviceId('hw:CARD=Device,DEV=0');
      expect(parsed?.cardId, 'Device');
      expect(parsed?.stream, 0);
      expect(parseAlsaDeviceId('hw:CARD=PCH,DEV=2')?.stream, 2);
    });

    test('card id with spaces survives the split', () {
      final parsed = parseAlsaDeviceId('hw:CARD=Analog Output,DEV=1');
      expect(parsed?.cardId, 'Analog Output');
      expect(parsed?.stream, 1);
    });

    test('malformed ids are rejected', () {
      expect(parseAlsaDeviceId(''), isNull);
      expect(parseAlsaDeviceId('Device'), isNull);
      expect(parseAlsaDeviceId('default'), isNull);
      expect(parseAlsaDeviceId('plughw:CARD=Device,DEV=0'), isNull);
      expect(parseAlsaDeviceId('hw:CARD=Device'), isNull);
      expect(parseAlsaDeviceId('hw:CARD=Device,DEV='), isNull);
      expect(parseAlsaDeviceId('hw:CARD=Device,DEV=x'), isNull);
      expect(parseAlsaDeviceId('hw:CARD=Device,DEV=-1'), isNull);
      expect(parseAlsaDeviceId('hw:CARD=,DEV=0'), isNull);
      expect(parseAlsaDeviceId(',DEV=0'), isNull);
    });
  });

  group('buildDacDevices', () {
    test('ids are exactly hw:CARD=<id>,DEV=<n>', () {
      final List<DacDevice> devices = parseAlsaDevices(
        cardsRaw: cards,
        streams: const {1: [0], 2: [0]},
      );
      expect(
        devices.map((d) => d.id).toList(),
        ['hw:CARD=Device,DEV=0', 'hw:CARD=HDMI,DEV=0'],
      );
      expect(devices.every((d) => d.enumerator == 'alsa'), isTrue);
    });

    test('multiple streams on one card become separate devices', () {
      final devices = parseAlsaDevices(
        cardsRaw: cards,
        streams: const {1: [0, 1, 2]},
      );
      expect(
        devices.map((d) => d.id).toList(),
        [
          'hw:CARD=Device,DEV=0',
          'hw:CARD=Device,DEV=1',
          'hw:CARD=Device,DEV=2',
        ],
      );
      expect(devices[0].name, 'Audio Class Gadget');
      expect(devices[1].name, 'Audio Class Gadget · pcm1');
      expect(devices[2].name, 'Audio Class Gadget · pcm2');
    });

    test('cards sort by kernel index, devices by stream index', () {
      final devices = parseAlsaDevices(
        cardsRaw: ' 3 [C ]: d - Third\n'
            ' 0 [A ]: d - First\n'
            ' 2 [B ]: d - Second\n',
        streams: const {0: [1, 0], 2: [0], 3: [0]},
      );
      expect(
        devices.map((d) => d.id).toList(),
        [
          'hw:CARD=A,DEV=0',
          'hw:CARD=A,DEV=1',
          'hw:CARD=B,DEV=0',
          'hw:CARD=C,DEV=0',
        ],
      );
    });

    test('capture-only card produces no devices', () {
      expect(parseAlsaDevices(cardsRaw: cards, streams: const {0: []}),
          isEmpty);
    });

    test('card with no pcm listing produces no devices', () {
      expect(parseAlsaDevices(cardsRaw: cards, streams: const {}), isEmpty);
    });

    test('no cards, unknown cards and garbage all yield an empty list', () {
      expect(parseAlsaDevices(cardsRaw: '', streams: const {}), isEmpty);
      expect(
        parseAlsaDevices(cardsRaw: '\x00 ??\n', streams: const {9: [0]}),
        isEmpty,
      );
      expect(
        parseAlsaDevices(cardsRaw: ' 4 [Z ]: d - Z\n', streams: const {9: [0]}),
        isEmpty,
      );
    });

    test('every device is hw: exclusive with unknown formats', () {
      final devices =
          parseAlsaDevices(cardsRaw: cards, streams: const {0: [0]});
      final d = devices.single;
      expect(d.id, 'hw:CARD=PCH,DEV=0');
      expect(d.exclusiveSupported, isTrue);
      expect(d.hardwareVolume, isFalse);
      // No alsa-lib to open the PCM, so formats stay unknown and "unknown" must
      // never be dressed up as a fabricated support list.
      expect(d.formats, isEmpty);
      expect(d.supports(pcm), isFalse);
      expect(
        d.supportedSummary,
        'ALSA hw: PCM · no mixer in path · format confirmed at open',
      );
    });

    test('loopback is kept but labelled as a sink', () {
      final devices = parseAlsaDevices(
        cardsRaw: ' 0 [Loopback]: Loopback - Loopback\n 1 [PCH]: PCH - PCH\n',
        streams: const {0: [0], 1: [0]},
      );
      expect(
        devices.map((d) => d.id).toList(),
        ['hw:CARD=Loopback,DEV=0', 'hw:CARD=PCH,DEV=0'],
      );
      expect(devices[0].name, 'Loopback · null sink');
      expect(devices[1].name, 'PCH');
    });
  });

  group('default card', () {
    test('resolves from the default symlink target', () {
      final devices = parseAlsaDevices(
        cardsRaw: cards,
        streams: const {0: [0], 2: [0]},
        defaultLink: 'card2',
      );
      expect(
        devices.where((d) => d.isDefault).map((d) => d.id).toList(),
        ['hw:CARD=HDMI,DEV=0'],
      );
    });

    test('only DEV=0 of the default card is default', () {
      final devices = parseAlsaDevices(
        cardsRaw: cards,
        streams: const {1: [0, 1]},
        defaultLink: 'card1',
      );
      expect(devices.where((d) => d.isDefault).length, 1);
      expect(devices.first.id, 'hw:CARD=Device,DEV=0');
    });

    test('falls back to a card literally named default', () {
      expect(parseDefaultCardIndex(null, parseAlsaCards(cards)), isNull);
      expect(
        parseDefaultCardIndex(null, parseAlsaCards(' 1 [default]: x - Y\n')),
        1,
      );
      expect(
        parseDefaultCardIndex(
            '/proc/asound/card7', parseAlsaCards(' 1 [default]: x - Y\n')),
        7,
      );
    });

    test('a target that names no known card flags nothing', () {
      final devices = parseAlsaDevices(
        cardsRaw: cards,
        streams: const {0: [0]},
        defaultLink: 'card9',
      );
      expect(devices.every((d) => !d.isDefault), isTrue);
      expect(parseAlsaDevices(cardsRaw: cards, streams: const {0: [0]})
          .where((d) => d.isDefault), isEmpty);
    });
  });

  group('engine honesty (no /proc access)', () {
    const engine = AlsaEngine();

    test('a malformed id is unknown without touching the filesystem',
        () async {
      expect(await engine.probeDevice('nonsense'), isNull);
      expect(await engine.probeDevice('plughw:CARD=PCH,DEV=0'), isNull);
      expect(await engine.probeDevice(''), isNull);
    });

    test('hardware volume is never claimed', () async {
      expect(await engine.setHardwareVolume('hw:CARD=PCH,DEV=0', 0.5),
          isFalse);
      expect(await engine.getHardwareVolume('hw:CARD=PCH,DEV=0'), isNull);
    });

    test('supported gate is the platform, with no native channel', () {
      expect(engine.isSupported, Platform.isLinux);
    });
  });
}