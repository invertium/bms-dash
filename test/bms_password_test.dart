import 'package:bms_dash/ble.dart';
import 'package:bms_dash/bms_state.dart';
import 'package:bms_dash/jbd_auth.dart';
import 'package:bms_dash/jbd_bms.dart';
import 'package:bms_dash/settings.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _device = BmsScanDevice(
  name: 'JBD-SP04S034',
  remoteId: 'A4:C1:37:04:2D:BE',
  rssi: -60,
  isLikelyBms: true,
);

void main() {
  late FakePasswordStore passwords;

  Future<ProviderContainer> containerWith(
    BluetoothScannerClient scanner,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        bluetoothScannerClientProvider.overrideWithValue(scanner),
        bmsPasswordStoreProvider.overrideWithValue(passwords),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  setUp(() => passwords = FakePasswordStore());

  test('a saved password is used without prompting', () async {
    await passwords.save(_device.remoteId, '123123');
    final scanner = RecordingScannerClient();
    final container = await containerWith(scanner);

    await container
        .read(bmsControllerProvider.notifier)
        .connectToDevice(_device);

    expect(scanner.lastPassword, '123123');
    expect(container.read(bmsControllerProvider).passwordPrompt, isNull);
  });

  test('no saved password connects without one', () async {
    final scanner = RecordingScannerClient();
    final container = await containerWith(scanner);

    await container
        .read(bmsControllerProvider.notifier)
        .connectToDevice(_device);

    expect(scanner.lastPassword, isNull);
  });

  test('the saved password is matched case-insensitively', () async {
    // The scanner and the persisted last-device id disagree on case; a
    // lookup miss here would silently re-prompt on every reconnect.
    await passwords.save('a4:c1:37:04:2d:be', '123123');
    final scanner = RecordingScannerClient();
    final container = await containerWith(scanner);

    await container
        .read(bmsControllerProvider.notifier)
        .connectToDevice(_device);

    expect(scanner.lastPassword, '123123');
  });

  test('a locked pack with no saved password prompts for one', () async {
    final container = await containerWith(
      FailingScannerClient(
        const JbdAuthException(
          JbdAuthFailure.passwordRequired,
          'This pack is password protected',
        ),
      ),
    );

    await container
        .read(bmsControllerProvider.notifier)
        .connectToDevice(_device);

    final state = container.read(bmsControllerProvider);
    expect(state.passwordPrompt, _device);
    expect(state.phase, BmsPhase.disconnected);
    expect(state.statusMessage, 'This pack is password protected');
  });

  test('a rejected password asks the user instead of dead-ending', () async {
    final scanner = RejectingScannerClient();
    final container = await containerWith(scanner);

    await container
        .read(bmsControllerProvider.notifier)
        .connectToDevice(_device);

    final state = container.read(bmsControllerProvider);
    expect(state.passwordPrompt, _device);
    expect(state.phase, BmsPhase.disconnected);
    expect(state.statusMessage, 'The BMS rejected the password');
  });

  test('a rejected password is not overwritten in storage', () async {
    await passwords.save(_device.remoteId, '123123');
    final container = await containerWith(RejectingScannerClient());

    await container
        .read(bmsControllerProvider.notifier)
        .connectToDevice(_device, password: '999999');

    expect(await passwords.passwordFor(_device.remoteId), '123123');
  });

  test('an accepted password is saved for next time', () async {
    final scanner = RecordingScannerClient();
    final container = await containerWith(scanner);

    await container
        .read(bmsControllerProvider.notifier)
        .connectToDevice(_device, password: '123123');

    expect(await passwords.passwordFor(_device.remoteId), '123123');
    expect(container.read(bmsControllerProvider).passwordPrompt, isNull);
  });

  test('a timeout does not prompt for a password', () async {
    // Nothing the user types fixes a silent module, so re-prompting would
    // just loop them.
    final container = await containerWith(
      FailingScannerClient(
        const JbdAuthException(
          JbdAuthFailure.timeout,
          'The BMS did not answer the unlock request',
        ),
      ),
    );

    await container
        .read(bmsControllerProvider.notifier)
        .connectToDevice(_device);

    expect(container.read(bmsControllerProvider).passwordPrompt, isNull);
  });

  test('dismissing the prompt clears it', () async {
    final container = await containerWith(RejectingScannerClient());
    final controller = container.read(bmsControllerProvider.notifier);

    await controller.connectToDevice(_device);
    expect(container.read(bmsControllerProvider).passwordPrompt, isNotNull);

    controller.dismissPasswordPrompt();
    expect(container.read(bmsControllerProvider).passwordPrompt, isNull);
  });

  test('forgetting a password re-prompts on the next connection', () async {
    await passwords.save(_device.remoteId, '123123');
    final scanner = RecordingScannerClient();
    final container = await containerWith(scanner);
    final controller = container.read(bmsControllerProvider.notifier);

    await controller.forgetPassword(_device.remoteId);
    await controller.connectToDevice(_device);

    expect(scanner.lastPassword, isNull);
  });
}

class FakePasswordStore implements BmsPasswordStore {
  final Map<String, String> _entries = {};

  @override
  Future<String?> passwordFor(String remoteId) async =>
      _entries[BmsPasswordStore.keyFor(remoteId)];

  @override
  Future<void> save(String remoteId, String password) async {
    _entries[BmsPasswordStore.keyFor(remoteId)] = password;
  }

  @override
  Future<void> clear(String remoteId) async {
    _entries.remove(BmsPasswordStore.keyFor(remoteId));
  }
}

/// Connects successfully and remembers whichever password it was handed.
class RecordingScannerClient extends _FakeScannerClient {
  String? lastPassword;

  @override
  Future<BmsConnection> connectAndDiscover(
    BmsScanDevice device, {
    Duration pollInterval = JbdBmsSession.defaultPollInterval,
    String? password,
  }) async {
    lastPassword = password;
    return _connectionFor(device);
  }
}

class RejectingScannerClient extends FailingScannerClient {
  RejectingScannerClient()
      : super(
          const JbdAuthException(
            JbdAuthFailure.wrongPassword,
            'The BMS rejected the password',
          ),
        );
}

class FailingScannerClient extends _FakeScannerClient {
  FailingScannerClient(this.error);

  final Object error;

  @override
  Future<BmsConnection> connectAndDiscover(
    BmsScanDevice device, {
    Duration pollInterval = JbdBmsSession.defaultPollInterval,
    String? password,
  }) async {
    throw error;
  }
}

abstract class _FakeScannerClient implements BluetoothScannerClient {
  @override
  Future<bool> get isSupported async => true;

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      Stream.value(BluetoothAdapterState.on);

  @override
  Stream<List<BmsScanDevice>> get scanResults => Stream.value(const []);

  @override
  Stream<bool> get isScanning => Stream.value(false);

  @override
  bool get isScanningNow => false;

  @override
  Future<void> startScan({required bool androidUsesFineLocation}) async {}

  @override
  Future<void> stopScan() async {}
}

BmsConnection _connectionFor(BmsScanDevice device) => BmsConnection(
      summary: DeviceConnectionSummary(
        name: device.name,
        remoteId: device.remoteId,
        serviceCount: 1,
        characteristicCount: 2,
      ),
      session: null,
    );
