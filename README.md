# Sylphy

Client Flutter responsive per una messenger privata, pensato per **Windows** e **Android**. L'interfaccia segue l'architettura di `agents.md`: Flutter gestisce solo UI e stato della conversazione, mentre vault, sessioni crittografiche e trasporto devono vivere dietro un bridge nativo.

## Funzionalità incluse

- lista conversazioni con ricerca, stati di presenza e contatori non letti;
- chat con composer, invio locale dimostrativo e conferme di consegna;
- schermate per fingerprint e stato di verifica del contatto;
- layout a tre colonne su Windows e lista/chat ottimizzate per Android;
- componenti per vault, trasporto privato e sessioni verificate, senza esporre segreti nella UI.

## Avvio

```powershell
flutter pub get
flutter run -d windows
flutter run -d <android-device-id>
```

Per generare i pacchetti:

```powershell
flutter build windows
flutter build apk --debug
```

## Nota di sicurezza

L'app avvia `LocalDemoMessagingBridge`, un repository in memoria necessario per rendere la UI esplorabile. Non esegue cifratura, non crea chiavi e non trasmette dati.

Prima di qualsiasi uso reale, sostituirlo con un bridge Rust/FFI che implementi il contratto in `lib/core/messaging/secure_messaging_bridge.dart` e il profilo definito in `agents.md`: vault Argon2id + XChaCha20-Poly1305, handshake X25519 + ML-KEM-768, Double Ratchet e invio esclusivo di envelope già cifrati tramite Veilid.

Il contratto di integrazione del client è documentato in `specs/flutter-client.md`.
