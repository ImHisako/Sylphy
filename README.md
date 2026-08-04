# Sylphy

Client Flutter responsive per una messenger privata, pensato per **Windows**, **Linux** e **Android**. L'interfaccia segue l'architettura di `agents.md`: Flutter gestisce UI e stato non sensibile, mentre vault, sessioni crittografiche e trasporto vivono dietro il bridge nativo Rust.

## Funzionalità incluse

- lista conversazioni con ricerca, stati di presenza e contatori non letti;
- chat con composer, invio locale dimostrativo e conferme di consegna;
- schermate per fingerprint e stato di verifica del contatto;
- layout desktop adattivo a tre colonne con navigation rail e layout mobile dedicato;
- stato reale del nodo Veilid (avvio, attach, qualità della rete e peer aggregati) senza esporre NodeId o route;
- core Rust con vault Argon2id/XChaCha20-Poly1305, bundle Ed25519, profilo X25519 + ML-KEM-768, Double Ratchet di Signal e adapter [Veilid](https://veilid.com/);
- runner e packaging nativi per Linux e Windows;
- GitHub Actions su ogni `push` e `pull_request`, con analisi, test, build Veilid e artifact scaricabili.

## Avvio

```powershell
flutter pub get
flutter run -d windows
flutter run -d linux
flutter run -d <android-device-id>
```

Per generare i pacchetti:

```powershell
flutter build windows
flutter build linux
flutter build apk --debug
```

## Core nativo e Veilid

Il core è in `native/core` e viene caricato dal client solo se la libreria nativa è inclusa nel bundle. Per generarla:

```powershell
./native/build-windows.ps1
./native/build-android.ps1
```

Su Linux:

```bash
bash ./native/build-linux.sh release
flutter build linux --release
```

Gli script compilano il core con le feature `veilid,signal-ratchet`. La build richiede anche il compilatore Protobuf `protoc`; Android richiede i target Rust e `cargo-ndk`, Windows Visual Studio Build Tools con C++, Linux Clang/CMake/Ninja, GTK 3 e liblzma. I dettagli dell'ABI, delle route private e del bootstrap Android sono in `native/README.md` e `specs/native-core.md`.

Quando `sylphy_core.dll` o `libsylphy_core.so` è disponibile, l'app crea lo storage applicativo, avvia `veilid-core 0.5.7`, esegue `attach` e aggiorna periodicamente lo stato mostrato nella UI. Lo shutdown dell'app arresta il nodo in modo deterministico. Veilid non riceve plaintext: il relativo adapter accetta soltanto `MessageEnvelope` applicativi già autenticati e cifrati e impone un limite di 32 KiB.

## GitHub Actions

`.github/workflows/ci.yml` esegue checkout del commit caricato, test e analisi su Ubuntu, quindi produce bundle Linux e Windows completi del core Veilid. Gli artifact `sylphy-linux` e `sylphy-windows` sono disponibili dalla run GitHub. Il workflow ha permessi repository in sola lettura: non genera push ricorsivi e non modifica il branch.

## Nota di sicurezza

L'app avvia ancora `LocalDemoMessagingBridge` per rendere la UI esplorabile. Il nodo Veilid è reale quando la libreria nativa è inclusa, ma le conversazioni demo non vengono trasmesse: il bridge demo non esegue cifratura, non crea chiavi e non invia dati.

Il core include `signalapp/libsignal` fissato al tag `v0.99.3` e implementa creazione prekey, apertura sessione, cifratura/decrittazione, rotazione DH/PQ e gestione dei messaggi fuori ordine. Il self-test FFI verifica l'intero percorso e la serializzazione opaca destinata a Veilid. L'invio UI resta intenzionalmente disabilitato finché identity store, prekey store e session store non saranno persistiti nel vault cifrato: non esiste alcun fallback a sessioni effimere o non ratchettate.

`libsignal` è distribuito con licenza AGPL-3.0-only. Prima di distribuire binari combinati, verificare e soddisfare gli obblighi indicati in `THIRD_PARTY_NOTICES.md`.

Il contratto di integrazione del client è documentato in `specs/flutter-client.md`.
