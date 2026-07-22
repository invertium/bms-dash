import 'package:flutter/foundation.dart';

/// Codec for the `0xFF 0xAA` authentication protocol used by password-locked
/// JBD/Xiaoxiang Bluetooth modules.
///
/// This is a *separate* protocol from the `0xDD` BMS register protocol in
/// [JbdProtocol]. It is spoken to the BLE module, not to the BMS controller:
/// it unlocks the module's UART bridge for the current connection only and
/// touches no BMS register, no EEPROM, and no factory mode. Nothing here
/// survives a disconnect.
///
/// Frames are `0xFF 0xAA <command> <len> <data...> <checksum>`, where the
/// checksum is the low byte of `sum(command, len, data)`. Unlike BMS frames
/// there is no trailing sentinel byte.
///
/// The flow, as captured from the vendor app:
///
/// ```text
/// >>> ff aa 15 06 30 30 30 30 30 30 3b   app key, always literal "000000"
/// <<< ff aa 15 01 00 16                  0x00 = password required
/// >>> ff aa 17 00 17                     request challenge byte
/// <<< ff aa 17 01 62 7a                  challenge = 0x62
/// >>> ff aa 18 06 f6 53 69 96 7f f0 d5   password, obfuscated with MAC+challenge
/// <<< ff aa 18 01 00 19                  0x00 = accepted (0x01 = rejected)
/// ```
///
/// Deliberately not implemented: command 0x16 (change the stored password)
/// and command 0x1D (escalate to the vendor's hardcoded root/factory key).
/// Both are persistent module writes and neither is needed to read telemetry.
class JbdAuthProtocol {
  static const int frameStart0 = 0xff;
  static const int frameStart1 = 0xaa;

  static const int appKeyCommand = 0x15;
  static const int randomByteCommand = 0x17;
  static const int passwordCommand = 0x18;

  /// Bytes before the payload: two start bytes, command, length.
  static const int headerLength = 4;

  /// [headerLength] plus the trailing checksum byte.
  static const int frameOverhead = headerLength + 1;

  /// The BMS password is a fixed-length 6-character field; the vendor app's
  /// keypad cannot produce anything else, and the obfuscation step pairs each
  /// character with one MAC byte, so a shorter or longer string has no valid
  /// encoding.
  static const int passwordLength = 6;

  /// A constant the vendor app presents before the password, identical on
  /// every install. It is not a secret and not the user's password — the
  /// module only uses it to decide whether a password is required at all.
  static const String appKey = '000000';

  /// Response status byte shared by [appKeyCommand] and [passwordCommand].
  /// Note that success is zero and rejection is one, not the other way round.
  static const int statusOk = 0x00;
  static const int statusRejected = 0x01;

  /// Only ever returned for [appKeyCommand]: the module has no password set,
  /// so the password exchange is skipped entirely.
  static const int statusNoPasswordSet = 0x02;

  static Uint8List appKeyFrame() =>
      _frame(appKeyCommand, appKey.codeUnits);

  static Uint8List randomByteRequestFrame() =>
      _frame(randomByteCommand, const []);

  /// The password frame for [password], obfuscated against the module's own
  /// MAC and the challenge byte it just issued.
  ///
  /// Throws [ArgumentError] unless [password] is exactly [passwordLength]
  /// single-byte characters and [macAddress] is six bytes.
  static Uint8List passwordFrame({
    required String password,
    required List<int> macAddress,
    required int randomByte,
  }) {
    return _frame(
      passwordCommand,
      obfuscatePassword(
        password: password,
        macAddress: macAddress,
        randomByte: randomByte,
      ),
    );
  }

  /// `((mac[i] ^ password[i]) + challenge) & 0xFF` for each of the six
  /// character/MAC-byte pairs.
  ///
  /// The MAC bytes go in display order — for `A4:C1:37:04:2D:BE` that is
  /// `[0xA4, 0xC1, 0x37, 0x04, 0x2D, 0xBE]`, not reversed.
  static List<int> obfuscatePassword({
    required String password,
    required List<int> macAddress,
    required int randomByte,
  }) {
    if (!isValidPassword(password)) {
      throw ArgumentError.value(
        password,
        'password',
        'must be exactly $passwordLength single-byte characters',
      );
    }
    if (macAddress.length != 6) {
      throw ArgumentError.value(
        macAddress,
        'macAddress',
        'must be six bytes',
      );
    }
    return [
      for (var i = 0; i < passwordLength; i++)
        ((macAddress[i] ^ password.codeUnitAt(i)) + randomByte) & 0xff,
    ];
  }

  /// Whether [password] can be encoded at all: exactly [passwordLength]
  /// characters that each fit in one byte. The vendor keypad only produces
  /// digits, but letters are accepted here because some modules are
  /// configured over serial rather than through the app.
  static bool isValidPassword(String password) {
    return password.length == passwordLength &&
        password.codeUnits.every((unit) => unit >= 0x20 && unit <= 0xff);
  }

  /// Parses the six bytes of a `AA:BB:CC:DD:EE:FF` BLE address, or returns
  /// null if [remoteId] is not one.
  ///
  /// On Android this is the real MAC, which is what the obfuscation needs. On
  /// iOS the platform hands out an opaque per-app UUID instead, which cannot
  /// authenticate — returning null there is correct rather than unlucky.
  static List<int>? parseMacAddress(String remoteId) {
    final parts = remoteId.trim().split(RegExp(r'[:-]'));
    if (parts.length != 6) {
      return null;
    }
    final bytes = <int>[];
    for (final part in parts) {
      if (part.length != 2) {
        return null;
      }
      final byte = int.tryParse(part, radix: 16);
      if (byte == null) {
        return null;
      }
      bytes.add(byte);
    }
    return bytes;
  }

  /// Decodes an auth response, or returns null if [frame] is not a
  /// well-formed one. Frames with an empty payload are rejected: every
  /// response this app waits on carries a status or challenge byte, and
  /// accepting a zero-length one would mean indexing into nothing.
  static JbdAuthResponse? parseResponse(List<int> frame) {
    if (frame.length < frameOverhead ||
        frame[0] != frameStart0 ||
        frame[1] != frameStart1) {
      return null;
    }
    final length = frame[3];
    if (length < 1 || frame.length < length + frameOverhead) {
      return null;
    }
    // A notification may carry trailing bytes; checksum only the frame.
    final checksum = frame[headerLength + length];
    if (checksum != _checksum(frame.take(headerLength + length).skip(2))) {
      return null;
    }
    return JbdAuthResponse(
      command: frame[2],
      value: frame[4],
    );
  }

  /// Whether [chunk] starts an auth frame. Used to keep these frames away
  /// from the `0xDD` frame assembler, whose obfuscated payloads can contain
  /// a `0xDD` byte by chance and would desynchronise it.
  static bool isAuthFrame(List<int> chunk) =>
      chunk.length >= 2 && chunk[0] == frameStart0 && chunk[1] == frameStart1;

  static Uint8List _frame(int command, List<int> data) {
    final body = [command, data.length, ...data];
    return Uint8List.fromList([
      frameStart0,
      frameStart1,
      ...body,
      _checksum(body),
    ]);
  }

  static int _checksum(Iterable<int> bytes) {
    var sum = 0;
    for (final byte in bytes) {
      sum += byte;
    }
    return sum & 0xff;
  }
}

/// A decoded `0xFF 0xAA` response: the command it answers and its single
/// meaningful byte (a status for the app-key and password steps, the
/// challenge for the random-byte step).
@immutable
class JbdAuthResponse {
  const JbdAuthResponse({required this.command, required this.value});

  final int command;
  final int value;

  @override
  bool operator ==(Object other) =>
      other is JbdAuthResponse &&
      other.command == command &&
      other.value == value;

  @override
  int get hashCode => Object.hash(command, value);

  @override
  String toString() =>
      'JbdAuthResponse(command: 0x${command.toRadixString(16)}, '
      'value: 0x${value.toRadixString(16)})';
}

/// Why an authentication attempt failed. The UI distinguishes these: a wrong
/// password is worth re-prompting for, a silent module is not.
enum JbdAuthFailure {
  /// The module rejected the password itself.
  wrongPassword,

  /// The module rejected the app key, i.e. it did not accept the handshake
  /// at all. Not something a different password would fix.
  appKeyRejected,

  /// No usable response arrived in time.
  timeout,

  /// The device address is not a MAC, so the password cannot be obfuscated.
  unsupportedAddress,
}

class JbdAuthException implements Exception {
  const JbdAuthException(this.failure, this.message);

  final JbdAuthFailure failure;
  final String message;

  @override
  String toString() => message;
}
