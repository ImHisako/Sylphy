# Sylphy

Client Flutter responsive per una messenger privata, pensato per **Windows**, **Linux** e **Android**. L'interfaccia segue l'architettura di `agents.md`: Flutter gestisce UI e stato non sensibile, mentre vault, sessioni crittografiche e trasporto vivono dietro il bridge nativo Rust.

## Funzionalità incluse

- onboarding al primo avvio e pannello “Il mio profilo”, apribile dall’avatar, per vedere o modificare nome e foto;
- ID Sylphy stabile con invito firmato copiabile, identità Ed25519 e prekey X25519/ML-KEM-768 custodite nel vault nativo;
- import di una persona dalla home tramite codice invito Sylphy validato dal core nativo, con stato iniziale “in attesa di verifica”;
- inbox nativa fail-closed, senza contatti o messaggi dimostrativi;
- chat e composer disponibili solo per record validati dal core nativo;
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

Quando `sylphy_core.dll` o `libsylphy_core.so` è disponibile, l'app crea uno storage applicativo persistente, avvia `veilid-core 0.5.7`, esegue `attach` e aggiorna periodicamente lo stato mostrato nella UI. Gli errori di rete e lo stato detached attivano un retry automatico; una build realmente priva della feature Veilid viene invece segnalata senza retry infinito. Su Android il manifest release concede i permessi di rete e `MainActivity` registra Context/JVM prima di avviare Flutter, evitando la race del primo startup. Lo shutdown dell'app arresta il nodo in modo deterministico.

Il callback nativo conserva in una coda limitata soltanto gli `AppMessage` opachi ricevuti. Veilid non riceve plaintext: l'adapter accetta `MessageEnvelope` applicativi già autenticati e cifrati, impone un limite di 32 KiB e non espone NodeId, route o payload nelle risposte FFI.

## GitHub Actions

`.github/workflows/ci.yml` esegue checkout del commit caricato, test e analisi su Ubuntu, quindi produce bundle Android, Linux e Windows completi del core Veilid. I job ordinari hanno accesso in sola lettura; sui tag `v*` il solo job finale riceve `contents: write` per creare o aggiornare la GitHub Release.

## Nota di sicurezza

L'app non carica conversazioni dimostrative. Con ABI nativa assente mostra un inbox vuoto; con ABI v4 usa `SylphyMessagingBridge`, che legge soltanto record restituiti dal core Rust. Il pannello profilo mostra il fingerprint pubblico e copia un invito `sylphy:` firmato completo; la chiave che apre il record identità cifrato è conservata dal secure storage della piattaforma. Un invito è accettato solo dopo la decodifica e la verifica nativa del bundle pubblico Ed25519/X25519/ML-KEM; il relativo contatto resta pending e non abilita il composer. Il composer non inoltra plaintext finché vault, contatto verificato e sessione persistente non sono disponibili.

Il core include `signalapp/libsignal` fissato al tag `v0.99.3` e implementa creazione prekey, apertura sessione, cifratura/decrittazione, rotazione DH/PQ e gestione dei messaggi fuori ordine. Il self-test FFI verifica l'intero percorso e la serializzazione opaca destinata a Veilid. L'invio UI resta intenzionalmente disabilitato finché identity store, prekey store e session store non saranno persistiti nel vault cifrato: non esiste alcun fallback a sessioni effimere o non ratchettate.

`libsignal` è distribuito con licenza AGPL-3.0-only. Prima di distribuire binari combinati, verificare e soddisfare gli obblighi indicati in `THIRD_PARTY_NOTICES.md`.

Il contratto di integrazione del client è documentato in `specs/flutter-client.md`.
