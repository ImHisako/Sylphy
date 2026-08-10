import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/identity/account_transfer_service.dart';

class AccountQrScannerPage extends StatefulWidget {
  const AccountQrScannerPage({super.key});

  @override
  State<AccountQrScannerPage> createState() => _AccountQrScannerPageState();
}

class _AccountQrScannerPageState extends State<AccountQrScannerPage> {
  bool _handled = false;
  String? _error;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    String? payload;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null) continue;
      try {
        parseAccountQrPayload(value);
        payload = value;
        break;
      } on AccountTransferException {
        // Keep looking when the camera sees another, unrelated QR code.
      }
    }
    if (payload == null) {
      if (_error == null && mounted) {
        setState(() => _error = 'Questo non è un QR di trasferimento Sylphy.');
      }
      return;
    }
    _handled = true;
    Navigator.of(context).pop(payload);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Scansiona il QR del computer'),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            key: const ValueKey('account-qr-camera'),
            onDetect: _onDetect,
          ),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 3,
                  ),
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                margin: const EdgeInsets.all(20),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xE6161A20),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  _error ??
                      'Inquadra il codice mostrato da Sylphy sul computer. La fotocamera è usata solo in questa schermata.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _error == null
                        ? Colors.white
                        : const Color(0xFFFFB0A8),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
