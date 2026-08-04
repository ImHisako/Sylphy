# Core nativo Sylphy

`core` è una libreria Rust compilabile come `cdylib` per Windows e Android. Espone una ABI C molto piccola: `sylphy_core_abi_version`, `sylphy_core_call` e `sylphy_core_free_string`.

Il core implementa e testa:

- derivazione Argon2id con parametri memory-hard e vault XChaCha20-Poly1305;
- firme Ed25519 sui bundle, validazione delle dimensioni e rifiuto delle versioni non supportate;
- composizione HKDF-SHA-256 di segreti X25519 e ML-KEM-768;
- envelope XChaCha20-Poly1305 con metadata legati come AAD;
- boundary Veilid opzionale, compilabile con `--features veilid`.

Il motore Double Ratchet non è incluso intenzionalmente: deve essere fornito da un'implementazione Signal compatibile e revisionata. Fino a quell'integrazione il core non espone alcun comando di invio, evitando un fallback silenzioso a sessioni non ratchettate.

## Build locale

```powershell
cd native/core
cargo test
cargo build --release --features veilid
```

Per Android installare il target Rust e `cargo-ndk`, quindi eseguire `./native/build-android.ps1`. Le librerie vengono generate in `android/app/src/main/jniLibs/<abi>/`. `MainActivity` carica la libreria e registra il `Context` Android richiesto da Veilid prima dell'avvio del nodo.

Per Windows eseguire `./native/build-windows.ps1`. Il file `sylphy_core.dll` viene prodotto in `native/core/target/release` e CMake lo include automaticamente nel bundle Flutter se presente.
