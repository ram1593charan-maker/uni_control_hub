import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:uni_control_hub/app/data/logger.dart';
import 'package:uni_control_hub/app/services/client_service.dart';
import 'package:uni_control_hub/app/services/wireless_adb_service.dart';

const String wirelessAdbSteps = '''
1. On the Android device open **Settings → Developer options → Wireless debugging** and turn it on.
2. Tap **Pair device with QR code** and scan the QR shown here.
3. Wait a few seconds. The device connects automatically.

Already paired before? Tap **Connect paired devices**.
''';

class WirelessAdbDialog extends StatefulWidget {
  const WirelessAdbDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => const WirelessAdbDialog(),
    );
  }

  @override
  State<WirelessAdbDialog> createState() => _WirelessAdbDialogState();
}

class _WirelessAdbDialogState extends State<WirelessAdbDialog> {
  final WirelessPairingSession _session =
      WirelessAdbService.createPairingSession();
  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();

  String _status = 'Waiting for QR scan...';
  bool _busy = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _waitForQrScan();
  }

  @override
  void dispose() {
    _closed = true;
    _addressController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  void _setStatus(String status) {
    if (_closed || !mounted) return;
    setState(() => _status = status);
  }

  Future<void> _waitForQrScan() async {
    try {
      final connected = await WirelessAdbService.waitForQrPairingAndConnect(
        _session,
        isCancelled: () => _closed,
      );
      if (_closed) return;
      if (connected > 0) {
        _setStatus('Connected $connected device(s)');
        ClientService.to.refreshClients();
      } else {
        _setStatus('No pairing detected. Close and try again.');
      }
    } catch (e) {
      logError('Wireless ADB QR pairing failed: $e');
      _setStatus('Error: $e');
    }
  }

  Future<void> _runBusy(Future<String> Function() action) async {
    setState(() => _busy = true);
    try {
      _setStatus(await action());
    } catch (e) {
      logError('Wireless ADB action failed: $e');
      _setStatus('Error: $e');
    } finally {
      if (!_closed && mounted) setState(() => _busy = false);
    }
  }

  Future<String> _connectPaired() async {
    final count = await WirelessAdbService.connectAllDiscovered();
    if (count == 0) return 'No paired devices found on this network';
    ClientService.to.refreshClients();
    return 'Connected $count device(s)';
  }

  Future<String> _pairWithCode() async {
    final address = _addressController.text.trim();
    final code = _codeController.text.trim();
    if (!RegExp(r'^\d{1,3}(\.\d{1,3}){3}:\d{1,5}$').hasMatch(address)) {
      return 'Enter address as IP:PORT, e.g. 192.168.1.20:37123';
    }
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      return 'Pairing code must be 6 digits';
    }
    final paired = await WirelessAdbService.pair(address, code);
    if (!paired) return 'Pairing failed. Check address and code';
    final connected = await WirelessAdbService.connect(address);
    if (!connected) {
      return 'Paired, but connect failed. Try Connect paired devices';
    }
    ClientService.to.refreshClients();
    return 'Paired and connected to $address';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Wireless debugging'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  color: Colors.white,
                  child: QrImageView(
                    data: _session.qrPayload,
                    size: 220,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(_status, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              const Text(wirelessAdbSteps),
              const Divider(height: 28),
              const Text('Pair with code instead'),
              const SizedBox(height: 8),
              TextField(
                controller: _addressController,
                decoration: const InputDecoration(
                  labelText: 'IP:PORT (from "Pair device with pairing code")',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _codeController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: 'Pairing code',
                  counterText: '',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _busy ? null : () => _runBusy(_pairWithCode),
                child: const Text('Pair with code'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => _runBusy(_connectPaired),
          child: const Text('Connect paired devices'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
