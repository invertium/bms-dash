import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

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
  });

  static JbdBasicInfo? fromPayload(Uint8List payload) {
    if (payload.length < 23) {
      return null;
    }
    final data = ByteData.sublistView(payload);
    final ntcCount = payload[22];
    final temperatures = <double>[];
    for (var i = 0; i < ntcCount && 24 + i * 2 < payload.length; i++) {
      // Per the JBD spec: 0.1 K units with a fixed 2731 offset.
      temperatures.add((data.getUint16(23 + i * 2) - 2731) / 10);
    }
    final fetStatus = payload[20];
    return JbdBasicInfo(
      totalVoltage: data.getUint16(0) / 100,
      current: data.getInt16(2) / 100,
      remainingCapacityAh: data.getUint16(4) / 100,
      nominalCapacityAh: data.getUint16(6) / 100,
      cycleCount: data.getUint16(8),
      protectionStatus: data.getUint16(16),
      socPercent: payload[19],
      chargeFetOn: fetStatus & 0x01 != 0,
      dischargeFetOn: fetStatus & 0x02 != 0,
      cellCount: payload[21],
      temperaturesCelsius: temperatures,
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

  bool get mosfetsOn => chargeFetOn && dischargeFetOn;

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

/// A live link to a connected JBD BMS: polls basic info and sends MOSFET
/// commands.
class JbdBmsSession {
  JbdBmsSession._(
    this._device,
    this._notifyCharacteristic,
    this._writeCharacteristic,
  );

  static const Duration _pollInterval = Duration(seconds: 2);
  static const Duration _mosfetConfirmTimeout = Duration(milliseconds: 2500);
  static const Duration _mosfetConfirmReadInterval =
      Duration(milliseconds: 500);
  static const int _mosfetCommandAttempts = 3;

  final BluetoothDevice _device;
  final BluetoothCharacteristic _notifyCharacteristic;
  final BluetoothCharacteristic _writeCharacteristic;
  final JbdFrameAssembler _assembler = JbdFrameAssembler();
  final StreamController<JbdBasicInfo> _basicInfoController =
      StreamController<JbdBasicInfo>.broadcast();

  StreamSubscription<List<int>>? _notifySubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  Timer? _pollTimer;
  bool _disposed = false;

  /// Starts a session over the JBD service in [services], or returns null if
  /// the device does not expose one.
  static Future<JbdBmsSession?> start(
    BluetoothDevice device,
    List<BluetoothService> services,
  ) async {
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

    final session = JbdBmsSession._(device, notify, write);
    await session._begin();
    return session;
  }

  /// Emits telemetry as poll responses arrive; closes when the session ends
  /// or the device disconnects.
  Stream<JbdBasicInfo> get basicInfo => _basicInfoController.stream;

  String get remoteId => _device.remoteId.str;

  /// The BMS treats charge and discharge FETs independently; callers that
  /// want a single switch pass the same value for both.
  ///
  /// The command write is unacknowledged and the BMS occasionally drops it,
  /// so this resends until telemetry confirms the requested state. Completes
  /// only once the change is confirmed; throws [TimeoutException] if the BMS
  /// never reports it.
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
  Future<bool> _confirmFetState({
    required bool chargeOn,
    required bool dischargeOn,
  }) async {
    final matched = basicInfo
        .firstWhere(
          (info) =>
              info.chargeFetOn == chargeOn && info.dischargeFetOn == dischargeOn,
        )
        .then((_) => true)
        // The stream closing (disconnect) must not confirm the change.
        .catchError((Object _) => false);
    final nudger = Timer.periodic(
      _mosfetConfirmReadInterval,
      (_) => _requestBasicInfo(),
    );
    try {
      return await matched.timeout(
        _mosfetConfirmTimeout,
        onTimeout: () => false,
      );
    } finally {
      nudger.cancel();
    }
  }

  Future<void> disconnect() async {
    await dispose();
    try {
      await _device.disconnect();
    } catch (_) {
      // Already disconnecting or gone.
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _pollTimer?.cancel();
    await _notifySubscription?.cancel();
    await _connectionSubscription?.cancel();
    await _basicInfoController.close();
  }

  Future<void> _begin() async {
    _notifySubscription = _notifyCharacteristic.onValueReceived.listen(_onChunk);
    await _notifyCharacteristic.setNotifyValue(true);
    _connectionSubscription = _device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        unawaited(dispose());
      }
    });
    _pollTimer = Timer.periodic(_pollInterval, (_) => _requestBasicInfo());
    await _requestBasicInfo();
  }

  Future<void> _requestBasicInfo() async {
    try {
      await _write(JbdProtocol.readCommand(JbdProtocol.basicInfoRegister));
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
    for (final frame in _assembler.addChunk(chunk)) {
      final payload = JbdProtocol.parseResponse(
        frame,
        JbdProtocol.basicInfoRegister,
      );
      if (payload == null) {
        continue;
      }
      final info = JbdBasicInfo.fromPayload(payload);
      if (info != null && !_basicInfoController.isClosed) {
        _basicInfoController.add(info);
      }
    }
  }
}
