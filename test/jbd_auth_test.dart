import 'package:bms_dash/jbd_auth.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every expected byte string below is copied from packet captures of the
/// vendor app talking to a real password-protected JBD module
/// (JBD-SP04S034L4S200A, MAC a4:c1:37:04:2d:be), not from another
/// implementation. If a refactor changes any of these, the app has stopped
/// speaking the protocol the hardware actually expects.
const _capturedMac = [0xa4, 0xc1, 0x37, 0x04, 0x2d, 0xbe];

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');

void main() {
  group('frame construction', () {
    test('app key frame matches the captured bytes', () {
      expect(
        _hex(JbdAuthProtocol.appKeyFrame()),
        'ff:aa:15:06:30:30:30:30:30:30:3b',
      );
    });

    test('random byte request matches the captured bytes', () {
      expect(_hex(JbdAuthProtocol.randomByteRequestFrame()), 'ff:aa:17:00:17');
    });

    test('password frame matches the captured bytes for 000000', () {
      expect(
        _hex(
          JbdAuthProtocol.passwordFrame(
            password: '000000',
            macAddress: _capturedMac,
            randomByte: 0x62,
          ),
        ),
        'ff:aa:18:06:f6:53:69:96:7f:f0:d5',
      );
    });

    test('password frame matches the captured bytes for 123412', () {
      expect(
        _hex(
          JbdAuthProtocol.passwordFrame(
            password: '123412',
            macAddress: _capturedMac,
            randomByte: 0x61,
          ),
        ),
        'ff:aa:18:06:f6:54:65:91:7d:ed:c8',
      );
    });

    test('password frame matches the captured bytes for 123123', () {
      expect(
        _hex(
          JbdAuthProtocol.passwordFrame(
            password: '123123',
            macAddress: _capturedMac,
            randomByte: 0x37,
          ),
        ),
        'ff:aa:18:06:cc:2a:3b:6c:56:c4:d5',
      );
    });

    test('password frame matches the captured bytes for 111111', () {
      expect(
        _hex(
          JbdAuthProtocol.passwordFrame(
            password: '111111',
            macAddress: _capturedMac,
            randomByte: 0x21,
          ),
        ),
        'ff:aa:18:06:b6:11:27:56:3d:b0:4f',
      );
    });

    test('obfuscation wraps at 256, not 255', () {
      // The captured 0xC1 MAC byte overflows for every password above; a
      // modulo-255 implementation is off by one here and nowhere else, so
      // this is the case that catches it.
      final encoded = JbdAuthProtocol.obfuscatePassword(
        password: '000000',
        macAddress: _capturedMac,
        randomByte: 0x62,
      );
      expect(encoded[1], 0x53);
    });
  });

  group('password validation', () {
    test('accepts exactly six characters', () {
      expect(JbdAuthProtocol.isValidPassword('123456'), isTrue);
      expect(JbdAuthProtocol.isValidPassword('abc123'), isTrue);
    });

    test('rejects anything that cannot be encoded', () {
      expect(JbdAuthProtocol.isValidPassword('12345'), isFalse);
      expect(JbdAuthProtocol.isValidPassword('1234567'), isFalse);
      expect(JbdAuthProtocol.isValidPassword(''), isFalse);
      // One rune, but two UTF-16 code units, so it cannot pair with the MAC.
      expect(JbdAuthProtocol.isValidPassword('12345\u{1F600}'), isFalse);
    });

    test('a wrong-length password throws instead of sending junk', () {
      expect(
        () => JbdAuthProtocol.passwordFrame(
          password: '12345',
          macAddress: _capturedMac,
          randomByte: 0x62,
        ),
        throwsArgumentError,
      );
    });

    test('a short MAC throws instead of sending junk', () {
      expect(
        () => JbdAuthProtocol.passwordFrame(
          password: '123456',
          macAddress: const [0xa4, 0xc1],
          randomByte: 0x62,
        ),
        throwsArgumentError,
      );
    });
  });

  group('MAC parsing', () {
    test('parses a colon-separated address in display order', () {
      expect(JbdAuthProtocol.parseMacAddress('A4:C1:37:04:2D:BE'), _capturedMac);
    });

    test('accepts lowercase and dash separators', () {
      expect(JbdAuthProtocol.parseMacAddress('a4-c1-37-04-2d-be'), _capturedMac);
    });

    test('rejects a non-MAC identifier', () {
      // iOS hands out an opaque UUID, which cannot authenticate.
      expect(
        JbdAuthProtocol.parseMacAddress(
          '0A589F60-D058-4599-B98B-C5FE9DA9FC92',
        ),
        isNull,
      );
      expect(JbdAuthProtocol.parseMacAddress(''), isNull);
      expect(JbdAuthProtocol.parseMacAddress('A4:C1:37:04:2D:ZZ'), isNull);
      expect(JbdAuthProtocol.parseMacAddress('A4:C1:37:04:2D'), isNull);
    });
  });

  group('response parsing', () {
    test('decodes the captured app-key acceptance', () {
      expect(
        JbdAuthProtocol.parseResponse(const [0xff, 0xaa, 0x15, 0x01, 0x00, 0x16]),
        const JbdAuthResponse(command: 0x15, value: 0x00),
      );
    });

    test('decodes the captured challenge responses', () {
      expect(
        JbdAuthProtocol.parseResponse(const [0xff, 0xaa, 0x17, 0x01, 0x62, 0x7a]),
        const JbdAuthResponse(command: 0x17, value: 0x62),
      );
      expect(
        JbdAuthProtocol.parseResponse(const [0xff, 0xaa, 0x17, 0x01, 0x37, 0x4f]),
        const JbdAuthResponse(command: 0x17, value: 0x37),
      );
    });

    test('distinguishes the captured password ACK from the NACK', () {
      // Zero is success here; the inverted reading locks out valid users.
      expect(
        JbdAuthProtocol.parseResponse(const [0xff, 0xaa, 0x18, 0x01, 0x00, 0x19])
            ?.value,
        JbdAuthProtocol.statusOk,
      );
      expect(
        JbdAuthProtocol.parseResponse(const [0xff, 0xaa, 0x18, 0x01, 0x01, 0x1a])
            ?.value,
        JbdAuthProtocol.statusRejected,
      );
    });

    test('rejects a bad checksum', () {
      expect(
        JbdAuthProtocol.parseResponse(const [0xff, 0xaa, 0x18, 0x01, 0x00, 0x00]),
        isNull,
      );
    });

    test('rejects truncated and empty-payload frames', () {
      expect(JbdAuthProtocol.parseResponse(const [0xff, 0xaa, 0x18]), isNull);
      expect(
        JbdAuthProtocol.parseResponse(const [0xff, 0xaa, 0x18, 0x01, 0x00]),
        isNull,
      );
      // Declares no payload, so there is no status byte to read.
      expect(
        JbdAuthProtocol.parseResponse(const [0xff, 0xaa, 0x18, 0x00, 0x18]),
        isNull,
      );
    });

    test('ignores trailing bytes after a complete frame', () {
      expect(
        JbdAuthProtocol.parseResponse(
          const [0xff, 0xaa, 0x17, 0x01, 0x62, 0x7a, 0xdd, 0x03],
        ),
        const JbdAuthResponse(command: 0x17, value: 0x62),
      );
    });

    test('does not mistake a BMS telemetry frame for an auth frame', () {
      expect(
        JbdAuthProtocol.isAuthFrame(const [0xdd, 0x03, 0x00, 0x1d]),
        isFalse,
      );
      expect(
        JbdAuthProtocol.isAuthFrame(const [0xff, 0xaa, 0x15, 0x01]),
        isTrue,
      );
    });
  });

  group('safety', () {
    test('exposes no command that writes to the module or the BMS', () {
      // 0x16 changes the stored password and 0x1D unlocks the vendor's root
      // key; both are persistent and neither is needed to read telemetry.
      const implemented = [
        JbdAuthProtocol.appKeyCommand,
        JbdAuthProtocol.randomByteCommand,
        JbdAuthProtocol.passwordCommand,
      ];
      expect(implemented, isNot(contains(0x16)));
      expect(implemented, isNot(contains(0x1d)));
    });
  });
}
