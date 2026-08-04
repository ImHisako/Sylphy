# Core nativo Sylphy

`core` è una libreria Rust compilabile come `cdylib` per Windows, Linux e Android. Espone una ABI C molto piccola: `sylphy_core_abi_version`, `sylphy_core_call` e `sylphy_core_free_string`.

Il core implementa e testa:

- derivazione Argon2id con parametri memory-hard e vault XChaCha20-Poly1305;
- firme Ed25519 sui bundle, validazione delle dimensioni e rifiuto delle versioni non supportate;
- composizione HKDF-SHA-256 di segreti X25519 e ML-KEM-768;
- sessioni Signal Double Ratchet con prekey post-quantum, chiavi per messaggio e consegna fuori ordine;
- envelope XChaCha20-Poly1305 con metadata legati come AAD;
- lifecycle Veilid opzionale, compilabile con `--features veilid`, con startup, stato aggregato, private route, callback `AppMessage` limitato e shutdown deterministico.

La feature `signal-ratchet` usa l'implementazione ufficiale `signalapp/libsignal` fissata al commit del tag `v0.99.3`. `SignalRatchetAccount` mantiene identity, prekey, signed prekey, Kyber prekey e session store entro il boundary nativo; `RatchetWireMessage` accetta solo ciphertext Signal/PreKey opaco e impone il limite di 32 KiB del trasporto. La persistenza cifrata di questi store è ancora un requisito prima di collegare il composer UI al trasporto reale.

## Build locale

```powershell
cd native/core
cargo test
cargo build --release --features veilid,signal-ratchet
```

La feature Signal richiede `protoc` nel `PATH` (pacchetto `protobuf-compiler` su Ubuntu o `protoc` tramite Chocolatey su Windows).

Per Android installare il target Rust e `cargo-ndk`, quindi eseguire `./native/build-android.ps1`. Le librerie vengono generate in `android/app/src/main/jniLibs/<abi>/`. `MainActivity` carica la libreria e registra il `Context` Android richiesto da Veilid prima dell'avvio del nodo; il manifest release include `INTERNET`, `ACCESS_NETWORK_STATE` e `ACCESS_WIFI_STATE`.

Per Windows eseguire `./native/build-windows.ps1`. Il file `sylphy_core.dll` viene prodotto in `native/core/target/release` e CMake lo include automaticamente nel bundle Flutter se presente.

Per Linux eseguire `./native/build-linux.sh release`. Il file `libsylphy_core.so` viene prodotto in `native/core/target/release` e installato in `bundle/lib` dal runner CMake.

L'ABI v3 espone i comandi `start_veilid`, `veilid_status`, `stop_veilid`, `list_conversations`, `list_messages`, `add_contact` e `ratchet_self_test`. `add_contact` decodifica e valida nel core un bundle pubblico firmato, rifiuta inviti scaduti o duplicati e registra il contatto come pending senza creare una sessione. Le risposte contengono soltanto capability, read model validati, risultato della verifica, stato di attachment, disponibilità Internet pubblica e conteggi aggregati; plaintext non validato, chiavi, NodeId, route private e configurazione sensibile restano nel core.
