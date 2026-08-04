# Sylphy

Client Flutter responsive per una messenger privata, pensato per **Windows** e **Android**. L'interfaccia segue l'architettura di `agents.md`: Flutter gestisce solo UI e stato della conversazione, mentre vault, sessioni crittografiche e trasporto devono vivere dietro un bridge nativo.

## Funzionalità incluse

- lista conversazioni con ricerca, stati di presenza e contatori non letti;
- chat con composer, invio locale dimostrativo e conferme di consegna;
- schermate per fingerprint e stato di verifica del contatto;
- layout a tre colonne su Windows e lista/chat ottimizzate per Android;
- core Rust opzionale con vault Argon2id/XChaCha20-Poly1305, bundle Ed25519, profilo X25519 + ML-KEM-768 e adapter [Veilid](https://veilid.com/).

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

## Core nativo e Veilid

Il core è in `native/core` e viene caricato dal client solo se la libreria nativa è inclusa nel bundle. Per generarla:

```powershell
./native/build-windows.ps1
./native/build-android.ps1
```

Entrambi gli script compilano il core con la feature `veilid`. Il secondo richiede anche i target Rust Android e `cargo-ndk`; per Windows è richiesto un linker C++ compatibile. I dettagli dell'ABI, delle route private e del bootstrap Android sono in `native/README.md` e `specs/native-core.md`.

## Nota di sicurezza

L'app avvia ancora `LocalDemoMessagingBridge` per rendere la UI esplorabile. Non esegue cifratura, non crea chiavi e non trasmette dati. Quando il core è incluso, l'interfaccia può verificarne il profilo crittografico dalla schermata privacy, ma non avvia un nodo Veilid né invia messaggi reali.

Prima di qualsiasi uso reale, integrare nel bridge Rust/FFI un provider Double Ratchet Signal revisionato. Il core rifiuta intenzionalmente di esporre comandi di invio fino a quell'integrazione: non esiste quindi alcun fallback silenzioso a sessioni non ratchettate.

Il contratto di integrazione del client è documentato in `specs/flutter-client.md`.
