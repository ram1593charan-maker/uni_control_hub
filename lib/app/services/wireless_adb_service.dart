import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:uni_control_hub/app/data/logger.dart';

/// Service types advertised over mDNS by Android wireless debugging.
const String adbPairingServiceType = '_adb-tls-pairing._tcp';
const String adbConnectServiceType = '_adb-tls-connect._tcp';

/// One entry from `adb mdns services`.
class MdnsAdbService {
  const MdnsAdbService({
    required this.name,
    required this.serviceType,
    required this.address,
  });

  final String name;
  final String serviceType;

  /// `ip:port`
  final String address;

  bool get isPairing => serviceType == adbPairingServiceType;
  bool get isConnect => serviceType == adbConnectServiceType;
}

/// QR pairing payload shown to the user. Android's "Pair device with QR code"
/// scanner reads `WIFI:T:ADB;S:<name>;P:<password>;;` and then advertises a
/// pairing service whose name equals `serviceName`.
class WirelessPairingSession {
  const WirelessPairingSession({
    required this.serviceName,
    required this.password,
  });

  final String serviceName;
  final String password;

  String get qrPayload => 'WIFI:T:ADB;S:$serviceName;P:$password;;';
}

class WirelessAdbService {
  static const String _serviceNamePrefix = 'UniHub-';
  static const int _passwordLength = 6;
  static const Duration _pairingPollInterval = Duration(seconds: 2);
  static const String _pairedMarker = 'Successfully paired';
  static const String _connectedMarker = 'connected to';
  static const String _alreadyConnectedMarker = 'already connected';

  /// Creates a fresh QR session with random service name and 6 digit password.
  static WirelessPairingSession createPairingSession({Random? random}) {
    final rng = random ?? Random.secure();
    final suffix = List.generate(
      6,
      (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[rng.nextInt(36)],
    ).join();
    final password = List.generate(
      _passwordLength,
      (_) => rng.nextInt(10).toString(),
    ).join();
    return WirelessPairingSession(
      serviceName: '$_serviceNamePrefix$suffix',
      password: password,
    );
  }

  /// Parses output of `adb mdns services`.
  ///
  /// Each data line looks like: `name<TAB>_service._tcp<TAB>ip:port`.
  /// The header line and unrelated lines are ignored.
  static List<MdnsAdbService> parseMdnsServices(String output) {
    final services = <MdnsAdbService>[];
    for (final rawLine in output.split('\n')) {
      final parts = rawLine.trim().split(RegExp(r'\s+'));
      if (parts.length < 3) continue;
      final serviceType = parts[parts.length - 2];
      if (serviceType != adbPairingServiceType &&
          serviceType != adbConnectServiceType) {
        continue;
      }
      services.add(MdnsAdbService(
        name: parts.sublist(0, parts.length - 2).join(' '),
        serviceType: serviceType,
        address: parts.last,
      ));
    }
    return services;
  }

  /// Lists ADB services currently visible on the local network.
  static Future<List<MdnsAdbService>> discoverServices() async {
    final result = await Process.run('adb', ['mdns', 'services']);
    if (result.exitCode != 0) {
      throw Exception('adb mdns services failed: ${result.stderr}');
    }
    return parseMdnsServices(result.stdout.toString());
  }

  /// Runs `adb pair <address> <code>`. Returns true when paired.
  static Future<bool> pair(String address, String code) async {
    final result = await Process.run('adb', ['pair', address, code]);
    final output = '${result.stdout}${result.stderr}';
    logInfo('adb pair $address: $output');
    return output.contains(_pairedMarker);
  }

  /// Runs `adb connect <address>`. Returns true when connected.
  static Future<bool> connect(String address) async {
    final result = await Process.run('adb', ['connect', address]);
    final output = '${result.stdout}${result.stderr}';
    logInfo('adb connect $address: $output');
    return output.contains(_connectedMarker) ||
        output.contains(_alreadyConnectedMarker);
  }

  /// Waits for the phone to scan the QR code and pairs with it, then connects
  /// every wireless debugging endpoint found. Returns the number of endpoints
  /// connected, or 0 when nothing paired before [timeout].
  static Future<int> waitForQrPairingAndConnect(
    WirelessPairingSession session, {
    Duration timeout = const Duration(minutes: 2),
    bool Function()? isCancelled,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (isCancelled?.call() ?? false) return 0;
      final services = await discoverServices();
      final pairing = services.where(
        (s) => s.isPairing && s.name == session.serviceName,
      );
      if (pairing.isNotEmpty) {
        final paired = await pair(pairing.first.address, session.password);
        if (paired) return connectAllDiscovered();
      }
      await Future<void>.delayed(_pairingPollInterval);
    }
    return 0;
  }

  /// Connects to every wireless debugging endpoint currently advertised.
  /// Returns the number of successful connections.
  static Future<int> connectAllDiscovered() async {
    final services = await discoverServices();
    var connected = 0;
    for (final service in services.where((s) => s.isConnect)) {
      if (await connect(service.address)) connected++;
    }
    return connected;
  }
}
