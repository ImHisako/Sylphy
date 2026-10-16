import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Only the encrypted selection survives route destruction during a lock.
/// Transfer passwords are never retained here.
class AccountTransferRecovery extends ChangeNotifier {
  Uint8List? _document;
  int _generation = 0;
  bool _disposed = false;
  int get generation => _generation;
  bool get hasDocument => _document != null;

  void retain(Uint8List document, int generation) {
    if (_disposed || generation != _generation) {
      document.fillRange(0, document.length, 0);
      return;
    }
    _document?.fillRange(0, _document!.length, 0);
    _document = document;
    notifyListeners();
  }

  Uint8List? take() {
    final document = _document;
    _document = null;
    return document;
  }

  void clear() {
    _generation++;
    _document?.fillRange(0, _document!.length, 0);
    _document = null;
  }

  @override
  void dispose() {
    _disposed = true;
    clear();
    super.dispose();
  }
}

class AccountTransferRecoveryScope extends InheritedWidget {
  const AccountTransferRecoveryScope({
    super.key,
    required this.recovery,
    required super.child,
  });
  final AccountTransferRecovery recovery;
  static AccountTransferRecovery? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AccountTransferRecoveryScope>()
      ?.recovery;
  @override
  bool updateShouldNotify(AccountTransferRecoveryScope oldWidget) =>
      recovery != oldWidget.recovery;
}
