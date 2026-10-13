import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:uni_control_hub/app/services/wireless_adb_service.dart';

void main() {
  group('WirelessAdbService.createPairingSession', () {
    test('builds WIFI:T:ADB payload with 6 digit password', () {
      final session = WirelessAdbService.createPairingSession(
        random: Random(1),
      );

      expect(session.serviceName, startsWith('UniHub-'));
      expect(session.password, matches(RegExp(r'^\d{6}$')));
      expect(
        session.qrPayload,
        'WIFI:T:ADB;S:${session.serviceName};P:${session.password};;',
      );
    });

    test('produces different sessions on each call', () {
      final first = WirelessAdbService.createPairingSession();
      final second = WirelessAdbService.createPairingSession();

      expect(first.serviceName, isNot(second.serviceName));
    });
  });

  group('WirelessAdbService.parseMdnsServices', () {
    test('returns pairing and connect services and skips header', () {
      const output = 'List of discovered mdns services\n'
          'UniHub-abc123\t_adb-tls-pairing._tcp\t192.168.1.20:37123\n'
          'adb-R58M-xYz\t_adb-tls-connect._tcp\t192.168.1.21:41111\n';

      final services = WirelessAdbService.parseMdnsServices(output);

      expect(services, hasLength(2));
      expect(services[0].name, 'UniHub-abc123');
      expect(services[0].isPairing, isTrue);
      expect(services[0].address, '192.168.1.20:37123');
      expect(services[1].isConnect, isTrue);
      expect(services[1].address, '192.168.1.21:41111');
    });

    test('ignores unrelated service types and malformed lines', () {
      const output = 'List of discovered mdns services\n'
          'printer\t_ipp._tcp\t192.168.1.5:631\n'
          'garbage line\n'
          '\n';

      expect(WirelessAdbService.parseMdnsServices(output), isEmpty);
    });

    test('returns empty list for empty output', () {
      expect(WirelessAdbService.parseMdnsServices(''), isEmpty);
    });
  });
}
