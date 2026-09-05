# Core nativo e integrazione Veilid

## ABI

Il confine Flutter/Rust è una singola ABI C JSON, attualmente alla versione 10. Le richieste sono UTF-8; le risposte di stato non riportano password, chiavi, plaintext o diagnostica crittografica. I comandi messaging possono restituire soltanto read model già autenticati e decrittati dal core. Ogni stringa restituita viene liberata esclusivamente tramite `sylphy_core_free_string`.

`ensure_identity` crea o riapre un record Argon2id/XChaCha20-Poly1305 contenente la chiave Ed25519 stabile, la prekey privata X25519 e il seed ML-KEM-768. Le prekey pubbliche sono firmate e ruotate alla scadenza, mentre il fingerprint Ed25519 rimane stabile. Il boundary restituisce esclusivamente fingerprint, scadenza e invito pubblico `sylphy:`; il segreto del vault è device-bound e proviene dal secure storage della piattaforma.

## Veilid

`veilid-core` è una dipendenza opzionale del core. Con la feature `veilid`, `VeilidNode` avvia `VeilidAPI` con un callback che accetta soltanto `AppMessage` opachi entro 32 KiB e li conserva in una coda nativa limitata a 256 elementi. Gestisce inoltre attach, routing context, private route, import del route blob e shutdown. Il lifecycle dell'app usa il `program_name` stabile `sylphy`, parte da `VeilidConfig::default` e sostituisce soltanto le directory persistenti di protected, table e block store; i percorsi TLS rimangono quelli di default. Su Android usa NDK 28.2, Java 17 e AndroidX Security 1.1.0; `MainActivity` registra `Context`/JVM prima di `super.onCreate` e adatta i nomi JNI interni al formato binario richiesto da `ClassLoader`, così il protected store può caricare le classi AndroidX. Il core rifiuta lo startup con `platform_not_initialized` se questo contratto non è soddisfatto e classifica separatamente gli errori degli store senza esporne il testo interno.

I comandi ABI `start_veilid`, `veilid_status` e `stop_veilid` sono sincroni rispetto al boundary C ma usano un runtime Tokio dedicato. Lo stato restituito a Flutter è ridotto a attachment, readiness pubblica, numero aggregato di peer e quantità di envelope in attesa. NodeId, route blob, payload e dettagli della routing table non attraversano il boundary. `list_conversations` e `list_messages` partono vuoti e non generano dati campione.

`add_contact` usa il codice breve Veilid per recuperare una `PublishedIdentity` firmata. Il nome mostrato è sempre il display name autenticato contenuto nel profilo remoto (oppure un identificatore Sylphy deterministico se il proprietario ha scelto di non pubblicarlo): il client che importa non può più assegnare un alias arbitrario. Il core impone limiti di dimensione, versione e cardinalità, verifica firme, capability e scadenza e rifiuta record duplicati.

`create_group` aggiunge una directory `groups-v1.vault` cifrata nel vault locale. La modalità `group` rappresenta una chat classica; `channel` rappresenta un canale professionale in cui solo l'amministratore pubblica. Ogni invito contiene il gruppo, gli endpoint pubblici firmati dei membri e l'identità dell'amministratore, ed è trasportato come payload E2EE individuale. I messaggi di gruppo vengono cifrati separatamente per ogni membro e validati contro la membership prima della persistenza; gli inviti fuori ordine non vengono scartati.

Il layer di trasporto riceve esclusivamente `MessageEnvelope` già autenticati e cifrati. I bundle pubblici firmati non includono una chiave di scrittura mailbox condivisa: i messaggi tra contatti usano la route diretta, mentre la mailbox cifrata resta privata ai dispositivi dello stesso account. Identità firmate e riferimenti ad allegati cifrati sono gli altri record pubblicabili.

## Ratchet

La feature `signal-ratchet` integra `signalapp/libsignal` v0.100.0 tramite commit immutabile. Il percorso di produzione invoca direttamente `process_prekey_bundle`, `message_encrypt` e `message_decrypt`; il bundle pubblico contiene identity key, signed prekey EC e Kyber prekey Signal, tutte legate al fingerprint Sylphy dalla firma Ed25519. Root key, chain key, contatori e skipped-message keys non attraversano mai FFI.

Il ciphertext opaco Signal/PreKey viene inserito in un envelope Sylphy ibrido e autenticato. Il self-test ABI usa lo stesso provider ufficiale e verifica un round trip PreKey completo.

L'account Signal globale e ogni sessione per contatto sono file cifrati distinti e sostituiti atomicamente. Il backup account non esporta questi file: ogni dispositivo collegato crea un device ID e uno stato Signal indipendenti, mentre il record pubblico firmato elenca fino a quattro endpoint dell'account. Gli invii vengono prima registrati in un outbox cifrato e sono ritentati con lo stesso ciphertext e message ID. La cronologia usa `messages-v2.log`: ogni mutazione è un frame autenticato append-only, con compattazione occasionale e migrazione automatica da `messages-v1.vault`. Il segreto casuale di cifratura è conservato nell'identity vault Argon2id, evitando di rieseguire Argon2 per ogni messaggio. Le capability firmate negoziano `signal-libsignal-v1`; i bundle precedenti privi della prekey Signal vengono rifiutati senza fallback crittografico.
