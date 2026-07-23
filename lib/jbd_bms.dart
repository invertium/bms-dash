import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'jbd_auth.dart';

/// Frame codecs for the JBD/Xiaoxiang smart BMS serial protocol.
///
/// The BMS exposes a UART-style GATT service 0xFF00 with notifications on
/// 0xFF01 and commands on 0xFF02. Frames look like
/// `0xDD <type> <register> <len> <data...> <checksum u16> 0x77`, where the
/// checksum is `0x10000 - sum(register/status, len, data)`.
class JbdProtocol {
  static final Guid serviceUuid = Guid('ff00');
  static final Guid notifyCharacteristicUuid = Guid('ff01');
  static final Guid writeCharacteristicUuid = Guid('ff02');

  static const int frameStart = 0xdd;
  static const int frameEnd = 0x77;
  static const int readRequest = 0xa5;
  static const int writeRequest = 0x5a;
  static const int basicInfoRegister = 0x03;
  static const int cellVoltagesRegister = 0x04;
  static const int hardwareVersionRegister = 0x05;
  static const int mosfetRegister = 0xe1;

  /// Number of bytes in a frame besides the payload: start, type/register,
  /// register/status, length, two checksum bytes, and end.
  static const int frameOverhead = 7;

  static Uint8List readCommand(int register) {
    return _frame(readRequest, register, const []);
  }

  /// A set bit in the mask disables the corresponding FET, so 0x00 0x00
  /// switches both back on.
  static Uint8List mosfetCommand({
    required bool chargeOn,
    required bool dischargeOn,
  }) {
    final mask = (chargeOn ? 0 : 0x01) | (dischargeOn ? 0 : 0x02);
    return _frame(writeRequest, mosfetRegister, [0x00, mask]);
  }

  /// Returns the payload of a valid success response for [register], or null
  /// if the frame is malformed, reports an error status, or answers another
  /// register.
  static Uint8List? parseResponse(Uint8List frame, int register) {
    if (frame.length < frameOverhead ||
        frame.first != frameStart ||
        frame.last != frameEnd) {
      return null;
    }
    if (frame[1] != register || frame[2] != 0x00) {
      return null;
    }
    final length = frame[3];
    if (frame.length != length + frameOverhead) {
      return null;
    }
    final checksum = (frame[frame.length - 3] << 8) | frame[frame.length - 2];
    if (checksum != _checksum(frame.sublist(2, 4 + length))) {
      return null;
    }
    return Uint8List.sublistView(frame, 4, 4 + length);
  }

  static Uint8List _frame(int requestType, int register, List<int> data) {
    final checksum = _checksum([register, data.length, ...data]);
    return Uint8List.fromList([
      frameStart,
      requestType,
      register,
      data.length,
      ...data,
      checksum >> 8,
      checksum & 0xff,
      frameEnd,
    ]);
  }

  static int _checksum(Iterable<int> bytes) {
    var sum = 0;
    for (final byte in bytes) {
      sum += byte;
    }
    return (0x10000 - sum) & 0xffff;
  }

  /// Decodes a register 0x04 payload (one big-endian u16 per cell, in mV)
  /// into volts. An odd-length payload is not a truncated-but-usable list,
  /// it is a different layout — reject it instead of dropping a byte.
  static List<double> parseCellVoltages(Uint8List payload) {
    if (payload.length.isOdd) {
      return const [];
    }
    final data = ByteData.sublistView(payload);
    return [
      for (var i = 0; i + 1 < payload.length; i += 2) data.getUint16(i) / 1000,
    ];
  }

  /// Decodes a register 0x05 payload: an ASCII version string.
  static String parseHardwareVersion(Uint8List payload) {
    return String.fromCharCodes(payload.where((b) => b >= 0x20 && b < 0x7f))
        .trim();
  }
}

/// Reassembles protocol frames from BLE notification chunks, which arrive in
/// MTU-sized pieces smaller than a full basic-info response.
class JbdFrameAssembler {
  final List<int> _buffer = [];

  List<Uint8List> addChunk(List<int> chunk) {
    _buffer.addAll(chunk);
    final frames = <Uint8List>[];
    while (true) {
      final start = _buffer.indexOf(JbdProtocol.frameStart);
      if (start < 0) {
        _buffer.clear();
        break;
      }
      if (start > 0) {
        _buffer.removeRange(0, start);
      }
      if (_buffer.length < 4) {
        break;
      }
      final total = _buffer[3] + JbdProtocol.frameOverhead;
      if (_buffer.length < total) {
        break;
      }
      if (_buffer[total - 1] == JbdProtocol.frameEnd) {
        frames.add(Uint8List.fromList(_buffer.sublist(0, total)));
        _buffer.removeRange(0, total);
      } else {
        // False frame start inside other data; drop one byte and resync.
        _buffer.removeAt(0);
      }
    }
    return frames;
  }
}

/// Decoded basic-info (register 0x03) telemetry.
@immutable
class JbdBasicInfo {
  const JbdBasicInfo({
    required this.totalVoltage,
    required this.current,
    required this.remainingCapacityAh,
    required this.nominalCapacityAh,
    required this.cycleCount,
    required this.protectionStatus,
    required this.socPercent,
    required this.chargeFetOn,
    required this.dischargeFetOn,
    required this.cellCount,
    required this.temperaturesCelsius,
    this.balanceStatus = 0,
    this.softwareVersion = 0,
    this.productionDateRaw = 0,
  });

  static JbdBasicInfo? fromPayload(Uint8List payload) {
    if (payload.length < 23) {
      return null;
    }
    final data = ByteData.sublistView(payload);
    // A frame can be checksummed and still be from an incompatible layout;
    // reject anything whose declared contents don't fit the payload or the
    // protocol's defined ranges rather than publishing truncated/garbage
    // telemetry.
    final ntcCount = payload[22];
    if (payload.length < 23 + ntcCount * 2) {
      return null;
    }
    final socPercent = payload[19];
    final cellCount = payload[21];
    if (socPercent > 100 || cellCount < 1 || cellCount > 32) {
      return null;
    }
    final temperatures = <double>[
      // Per the JBD spec: 0.1 K units with a fixed 2731 offset.
      for (var i = 0; i < ntcCount; i++)
        (data.getUint16(23 + i * 2) - 2731) / 10,
    ];
    final fetStatus = payload[20];
    return JbdBasicInfo(
      totalVoltage: data.getUint16(0) / 100,
      current: data.getInt16(2) / 100,
      remainingCapacityAh: data.getUint16(4) / 100,
      nominalCapacityAh: data.getUint16(6) / 100,
      cycleCount: data.getUint16(8),
      protectionStatus: data.getUint16(16),
      socPercent: socPercent,
      chargeFetOn: fetStatus & 0x01 != 0,
      dischargeFetOn: fetStatus & 0x02 != 0,
      cellCount: cellCount,
      temperaturesCelsius: temperatures,
      balanceStatus: (data.getUint16(14) << 16) | data.getUint16(12),
      softwareVersion: payload[18],
      productionDateRaw: data.getUint16(10),
    );
  }

  /// Pack voltage in volts.
  final double totalVoltage;

  /// Pack current in amps; positive while charging, negative while
  /// discharging.
  final double current;

  final double remainingCapacityAh;
  final double nominalCapacityAh;
  final int cycleCount;
  final int protectionStatus;
  final int socPercent;
  final bool chargeFetOn;
  final bool dischargeFetOn;
  final int cellCount;
  final List<double> temperaturesCelsius;

  /// One bit per cell (bit 0 = cell 1); set while the balancer bleeds that
  /// cell.
  final int balanceStatus;

  /// Raw version byte; BCD-style nibbles, e.g. 0x20 -> "2.0".
  final int softwareVersion;

  /// Packed date: bits 15-9 year since 2000, 8-5 month, 4-0 day.
  final int productionDateRaw;

  bool get mosfetsOn => chargeFetOn && dischargeFetOn;

  bool isCellBalancing(int cellIndex) => balanceStatus >> cellIndex & 1 != 0;

  String get softwareVersionLabel =>
      '${softwareVersion >> 4}.${softwareVersion & 0xf}';

  DateTime? get productionDate {
    if (productionDateRaw == 0) {
      return null;
    }
    final year = 2000 + (productionDateRaw >> 9);
    final month = (productionDateRaw >> 5) & 0xf;
    final day = productionDateRaw & 0x1f;
    if (month < 1 || month > 12 || day < 1 || day > 31) {
      return null;
    }
    final date = DateTime(year, month, day);
    // DateTime normalizes impossible dates (Feb 31 -> Mar 2); an impossible
    // packed date is garbage, not a date, so reject it instead.
    if (date.year != year || date.month != month || date.day != day) {
      return null;
    }
    return date;
  }

  /// Bit 12 of the protection word: FETs disabled by software command
  /// (register 0xE1) rather than by a protection trip.
  static const int softwareLockBit = 0x1000;

  static const List<String> _protectionNames = [
    'Cell overvoltage',
    'Cell undervoltage',
    'Pack overvoltage',
    'Pack undervoltage',
    'Charge over-temperature',
    'Charge under-temperature',
    'Discharge over-temperature',
    'Discharge under-temperature',
    'Charge overcurrent',
    'Discharge overcurrent',
    'Short circuit',
    'Frontend IC error',
  ];

  /// True only for real protection trips; the software FET lock is expected
  /// whenever the MOSFETs are toggled off and is not a fault.
  bool get hasProtectionFault => protectionStatus & ~softwareLockBit != 0;

  bool get isSoftwareLocked => protectionStatus & softwareLockBit != 0;

  /// Human-readable names of the active protection trips, with a hex
  /// fallback for any bits this decoder does not know.
  List<String> get activeProtections {
    final names = <String>[
      for (var bit = 0; bit < _protectionNames.length; bit++)
        if (protectionStatus & (1 << bit) != 0) _protectionNames[bit],
    ];
    final unknown =
        protectionStatus & ~softwareLockBit & ~((1 << _protectionNames.length) - 1);
    if (unknown != 0) {
      names.add('Unknown (0x${unknown.toRadixString(16)})');
    }
    return names;
  }
}

/// The session surface the UI depends on, implemented by the real BLE
/// session and by the in-app demo battery.
abstract class BmsSession {
  /// Emits telemetry as poll responses arrive; closes when the session ends.
  Stream<JbdBasicInfo> get basicInfo;

  /// Emits per-cell voltages (volts) as register 0x04 responses arrive.
  Stream<List<double>> get cellVoltages;

  String get remoteId;

  /// Hardware version string, once read; null before the response arrives.
  String? get hardwareVersion;

  Future<void> setMosfets({required bool chargeOn, required bool dischargeOn});

  Future<void> disconnect();

  Future<void> dispose();
}

/// A live link to a connected JBD BMS: polls basic info and cell voltages,
/// and sends MOSFET commands.
class JbdBmsSession implements BmsSession {
  JbdBmsSession._(
    this._device,
    this._notifyCharacteristic,
    this._writeCharacteristic,
    this._pollInterval,
  );

  /// Basic info and cell voltages alternate on the poll tick, so each
  /// register refreshes every two ticks.
  static const Duration defaultPollInterval = Duration(seconds: 1);

  /// The BLE link can stay "connected" while the BMS has stopped answering
  /// (e.g. it went to sleep or moved out of range without a clean
  /// disconnect). If no *accepted basic-info frame* arrives for this long,
  /// the session tears itself down so the UI does not show frozen values as
  /// live data. Cell-only or malformed traffic deliberately does not count:
  /// the dashboard's voltage/current/SOC must be what is fresh.
  ///
  /// Basic info arrives every second poll tick; allow two full cycles plus
  /// slack so a single lost frame does not drop the session.
  Duration get _staleTimeout {
    final scaled = _pollInterval * 4 + const Duration(seconds: 2);
    const floor = Duration(seconds: 12);
    return scaled > floor ? scaled : floor;
  }
  /// Per-step budget for the unlock handshake. The module answers each step
  /// immediately, so this only has to cover a dropped notification before the
  /// user is told the pack is not answering.
  static const Duration _authStepTimeout = Duration(seconds: 4);

  /// Budget for the app-key probe when no password is saved. Modules that
  /// predate the auth protocol never answer it, so every connect to one
  /// waits this out before polling starts — kept short for that reason.
  /// Locked modules answer well within it.
  static const Duration _authProbeTimeout = Duration(seconds: 2);
  static const Duration _mosfetConfirmTimeout = Duration(milliseconds: 2500);
  static const Duration _mosfetConfirmReadInterval =
      Duration(milliseconds: 500);
  static const int _mosfetCommandAttempts = 3;

  final BluetoothDevice _device;
  final BluetoothCharacteristic _notifyCharacteristic;
  final BluetoothCharacteristic _writeCharacteristic;
  final Duration _pollInterval;
  final JbdFrameAssembler _assembler = JbdFrameAssembler();
  final StreamController<JbdBasicInfo> _basicInfoController =
      StreamController<JbdBasicInfo>.broadcast();
  final StreamController<List<double>> _cellVoltagesController =
      StreamController<List<double>>.broadcast();
  final StreamController<JbdAuthResponse> _authResponses =
      StreamController<JbdAuthResponse>.broadcast();

  StreamSubscription<List<int>>? _notifySubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  Timer? _pollTimer;
  Timer? _staleTimer;
  int _pollTick = 0;
  String? _hardwareVersion;
  bool _disposed = false;

  /// True only while the unlock handshake is in flight; see [_onChunk].
  bool _authenticating = false;

  /// Starts a session over the JBD service in [services], or returns null if
  /// the device does not expose one.
  ///
  /// [password] unlocks a password-protected Bluetooth module before polling
  /// starts; pass null when none is saved. The module is always probed for
  /// protection, so a locked pack with no saved password throws a
  /// [JbdAuthFailure.passwordRequired] [JbdAuthException] (the UI's cue to
  /// prompt for one) instead of looking like a dead pack, and a wrong
  /// password fails loudly too.
  static Future<JbdBmsSession?> start(
    BluetoothDevice device,
    List<BluetoothService> services, {
    Duration pollInterval = defaultPollInterval,
    String? password,
  }) async {
    final service = services.firstWhereOrNull(
      (service) => service.uuid == JbdProtocol.serviceUuid,
    );
    if (service == null) {
      return null;
    }
    final notify = service.characteristics.firstWhereOrNull(
      (c) => c.uuid == JbdProtocol.notifyCharacteristicUuid,
    );
    final write = service.characteristics.firstWhereOrNull(
      (c) => c.uuid == JbdProtocol.writeCharacteristicUuid,
    );
    if (notify == null || write == null) {
      return null;
    }

    final session = JbdBmsSession._(device, notify, write, pollInterval);
    try {
      await session._begin(password: password);
    } catch (_) {
      // _begin can fail partway (e.g. setNotifyValue throws after the
      // notify subscription is installed); never leak the half-built
      // session's timers and subscriptions.
      await session.dispose();
      rethrow;
    }
    return session;
  }

  @override
  Stream<JbdBasicInfo> get basicInfo => _basicInfoController.stream;

  @override
  Stream<List<double>> get cellVoltages => _cellVoltagesController.stream;

  @override
  String get remoteId => _device.remoteId.str;

  @override
  String? get hardwareVersion => _hardwareVersion;

  /// The BMS treats charge and discharge FETs independently; callers that
  /// want a single switch pass the same value for both.
  ///
  /// The command write is unacknowledged and the BMS occasionally drops it,
  /// so this resends until telemetry confirms the requested state. Completes
  /// only once the change is confirmed; throws [TimeoutException] if the BMS
  /// never reports it.
  @override
  Future<void> setMosfets({
    required bool chargeOn,
    required bool dischargeOn,
  }) async {
    for (var attempt = 0; attempt < _mosfetCommandAttempts; attempt++) {
      await _write(
        JbdProtocol.mosfetCommand(chargeOn: chargeOn, dischargeOn: dischargeOn),
      );
      final confirmed = await _confirmFetState(
        chargeOn: chargeOn,
        dischargeOn: dischargeOn,
      );
      if (confirmed) {
        return;
      }
    }
    throw TimeoutException(
      'BMS did not confirm the MOSFET change; it may be overriding it '
      '(e.g. a protection is active)',
    );
  }

  /// Waits for a telemetry frame reporting the requested FET state, nudging
  /// extra reads so confirmation does not depend on the slow poll cycle.
  ///
  /// Uses an explicitly owned subscription cancelled in `finally`:
  /// `basicInfo.firstWhere(...).timeout(...)` would keep its listener on the
  /// broadcast stream after the timeout, leaking one per failed attempt.
  Future<bool> _confirmFetState({
    required bool chargeOn,
    required bool dischargeOn,
  }) async {
    final matched = Completer<bool>();
    void settle(bool value) {
      if (!matched.isCompleted) {
        matched.complete(value);
      }
    }

    final subscription = basicInfo.listen(
      (info) {
        if (info.chargeFetOn == chargeOn &&
            info.dischargeFetOn == dischargeOn) {
          settle(true);
        }
      },
      onError: (Object _) => settle(false),
      // The stream closing (disconnect) must not confirm the change.
      onDone: () => settle(false),
    );
    final nudger = Timer.periodic(
      _mosfetConfirmReadInterval,
      (_) => _requestRead(JbdProtocol.basicInfoRegister),
    );
    try {
      return await matched.future.timeout(
        _mosfetConfirmTimeout,
        onTimeout: () => false,
      );
    } finally {
      nudger.cancel();
      await subscription.cancel();
    }
  }

  @override
  Future<void> disconnect() async {
    await dispose();
    try {
      await _device.disconnect();
    } catch (_) {
      // Already disconnecting or gone.
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _pollTimer?.cancel();
    _staleTimer?.cancel();
    await _notifySubscription?.cancel();
    await _connectionSubscription?.cancel();
    await _basicInfoController.close();
    await _cellVoltagesController.close();
    // Closed last: an in-flight _authExchange watches this stream's done
    // event to fail fast instead of waiting out its timeout.
    await _authResponses.close();
  }

  Future<void> _begin({String? password}) async {
    _notifySubscription = _notifyCharacteristic.onValueReceived.listen(_onChunk);
    await _notifyCharacteristic.setNotifyValue(true);
    _connectionSubscription = _device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        unawaited(dispose());
      }
    });
    // Probe/unlock before the first read — even with no password on file,
    // since the probe is the only way to learn that a pack is locked. A
    // locked module ignores register reads, so polling first would just
    // look like an unresponsive pack.
    _authenticating = true;
    try {
      await _authenticate(password);
    } finally {
      _authenticating = false;
    }
    _pollTimer = Timer.periodic(_pollInterval, (_) => _onPollTick());
    _restartStaleTimer();
    await _requestRead(JbdProtocol.hardwareVersionRegister);
    await _requestRead(JbdProtocol.basicInfoRegister);
  }

  Future<void> _authenticate(String? password) {
    return authenticateJbdModule(
      exchange: _authExchange,
      remoteId: remoteId,
      password: password,
      probeTimeout: _authProbeTimeout,
      stepTimeout: _authStepTimeout,
    );
  }

  /// Writes [frame] and waits up to [timeout] for the response to
  /// [expectedCommand], ignoring any unrelated traffic that arrives
  /// meanwhile.
  ///
  /// The listener is subscribed *before* the write: these modules answer in
  /// well under a millisecond, and awaiting the write first loses the race.
  Future<JbdAuthResponse> _authExchange(
    Uint8List frame,
    int expectedCommand,
    Duration timeout,
  ) async {
    final matched = Completer<JbdAuthResponse>();
    final subscription = _authResponses.stream.listen(
      (response) {
        if (response.command == expectedCommand && !matched.isCompleted) {
          matched.complete(response);
        }
      },
      onDone: () {
        if (!matched.isCompleted) {
          matched.completeError(
            const JbdAuthException(
              JbdAuthFailure.timeout,
              'The BMS disconnected during authentication',
            ),
          );
        }
      },
    );
    try {
      await _write(frame);
      return await matched.future.timeout(
        timeout,
        onTimeout: () => throw const JbdAuthException(
          JbdAuthFailure.timeout,
          'The BMS did not answer the unlock request',
        ),
      );
    } finally {
      await subscription.cancel();
    }
  }

  void _restartStaleTimer() {
    _staleTimer?.cancel();
    if (_disposed) {
      return;
    }
    _staleTimer = Timer(_staleTimeout, () => unawaited(disconnect()));
  }

  void _onPollTick() {
    _pollTick++;
    unawaited(
      _requestRead(
        _pollTick.isEven
            ? JbdProtocol.basicInfoRegister
            : JbdProtocol.cellVoltagesRegister,
      ),
    );
  }

  Future<void> _requestRead(int register) async {
    try {
      await _write(JbdProtocol.readCommand(register));
    } catch (_) {
      // Poll writes can fail transiently (e.g. mid-disconnect); the next
      // tick retries and real disconnects close the session.
    }
  }

  Future<void> _write(Uint8List frame) {
    if (_disposed) {
      throw StateError('BMS session is closed');
    }
    return _writeCharacteristic.write(
      frame,
      withoutResponse: _writeCharacteristic.properties.writeWithoutResponse,
    );
  }

  void _onChunk(List<int> chunk) {
    // Auth responses are self-contained in one notification and must never
    // reach the assembler: their obfuscated payload can contain 0xDD, which
    // would be mistaken for a frame start and desynchronise real telemetry.
    //
    // Gated on an in-flight handshake rather than on the 0xFF 0xAA prefix
    // alone. A *continuation* chunk of a long telemetry frame carries raw
    // payload bytes, which can begin 0xFF 0xAA by chance; sniffing every
    // chunk would silently swallow one and corrupt that frame. Once the
    // module is unlocked no auth traffic exists, so this path is closed.
    if (_authenticating && JbdAuthProtocol.isAuthFrame(chunk)) {
      final response = JbdAuthProtocol.parseResponse(chunk);
      if (response != null && !_authResponses.isClosed) {
        _authResponses.add(response);
      }
      return;
    }
    for (final frame in _assembler.addChunk(chunk)) {
      if (frame.length < 2 || _disposed) {
        continue;
      }
      final register = frame[1];
      final payload = JbdProtocol.parseResponse(frame, register);
      if (payload == null) {
        continue;
      }
      switch (register) {
        case JbdProtocol.basicInfoRegister:
          final info = JbdBasicInfo.fromPayload(payload);
          if (info != null && !_basicInfoController.isClosed) {
            // Only decoded, published basic info counts as freshness; a
            // checksummed-but-bogus frame must not keep a dead feed alive.
            _restartStaleTimer();
            _basicInfoController.add(info);
          }
        case JbdProtocol.cellVoltagesRegister:
          final cells = JbdProtocol.parseCellVoltages(payload);
          // A frame can pass the checksum and still carry nonsense (e.g. a
          // BMS variant answering with a different layout); drop anything
          // outside what a JBD pack can physically report.
          final plausible = cells.isNotEmpty &&
              cells.length <= 32 &&
              cells.every((v) => v >= 0 && v < 6);
          if (plausible && !_cellVoltagesController.isClosed) {
            _cellVoltagesController.add(cells);
          }
        case JbdProtocol.hardwareVersionRegister:
          _hardwareVersion = JbdProtocol.parseHardwareVersion(payload);
      }
    }
  }
}

/// One unlock-protocol exchange: writes [frame], returns the module's
/// response to [expectedCommand], or throws a [JbdAuthFailure.timeout]
/// [JbdAuthException] after [timeout].
typedef JbdAuthExchange = Future<JbdAuthResponse> Function(
  Uint8List frame,
  int expectedCommand,
  Duration timeout,
);

/// Runs the `0xFF 0xAA` unlock flow over [exchange]: the app-key probe,
/// then the challenge and obfuscated password when the module wants one.
/// Returns normally once the module reports the link unlocked or not locked
/// at all; throws [JbdAuthException] otherwise.
///
/// The probe is sent even with no [password] — it is the only way to learn
/// that a pack is locked, and the vendor app sends the same frame on every
/// connect. The outcomes:
///
/// - The probe times out: the module predates the auth protocol and cannot
///   be locked, so proceed unauthenticated. With a saved [password] silence
///   is an error instead — that module spoke the protocol when the password
///   was saved, so a mute one is genuinely unresponsive.
/// - The module reports no password set: proceed; a saved [password] is
///   simply unused.
/// - A password is required but [password] is null: throw
///   [JbdAuthFailure.passwordRequired], the UI's cue to prompt for one.
/// - Otherwise run the challenge/password steps; a rejection throws
///   [JbdAuthFailure.wrongPassword].
Future<void> authenticateJbdModule({
  required JbdAuthExchange exchange,
  required String remoteId,
  required String? password,
  required Duration probeTimeout,
  required Duration stepTimeout,
}) async {
  final JbdAuthResponse appKey;
  try {
    appKey = await exchange(
      JbdAuthProtocol.appKeyFrame(),
      JbdAuthProtocol.appKeyCommand,
      password == null ? probeTimeout : stepTimeout,
    );
  } on JbdAuthException catch (error) {
    if (password == null && error.failure == JbdAuthFailure.timeout) {
      return;
    }
    rethrow;
  }
  if (appKey.value == JbdAuthProtocol.statusNoPasswordSet) {
    return;
  }
  if (appKey.value != JbdAuthProtocol.statusOk) {
    throw const JbdAuthException(
      JbdAuthFailure.appKeyRejected,
      'The BMS refused the unlock handshake',
    );
  }
  if (password == null) {
    throw const JbdAuthException(
      JbdAuthFailure.passwordRequired,
      'This pack is password protected',
    );
  }
  final mac = JbdAuthProtocol.parseMacAddress(remoteId);
  if (mac == null) {
    throw const JbdAuthException(
      JbdAuthFailure.unsupportedAddress,
      'This device does not expose a MAC address, which a password-'
      'protected BMS needs to unlock',
    );
  }

  final challenge = await exchange(
    JbdAuthProtocol.randomByteRequestFrame(),
    JbdAuthProtocol.randomByteCommand,
    stepTimeout,
  );
  final result = await exchange(
    JbdAuthProtocol.passwordFrame(
      password: password,
      macAddress: mac,
      randomByte: challenge.value,
    ),
    JbdAuthProtocol.passwordCommand,
    stepTimeout,
  );
  if (result.value != JbdAuthProtocol.statusOk) {
    throw const JbdAuthException(
      JbdAuthFailure.wrongPassword,
      'The BMS rejected the password',
    );
  }
}
