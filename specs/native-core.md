# Core nativo e integrazione Veilid

## ABI

Il confine Flutter/Rust è una singola ABI C JSON, attualmente alla versione 4. Le richieste sono UTF-8; le risposte di stato non riportano password, chiavi, plaintext o diagnostica crittografica. I comandi messaging possono restituire soltanto read model già autenticati e decrittati dal core. Ogni stringa restituita viene liberata esclusivamente tramite `sylphy_core_free_string`.

`ensure_identity` crea o riapre un record Argon2id/XChaCha20-Poly1305 contenente la chiave Ed25519 stabile, la prekey privata X25519 e il seed ML-KEM-768. Le prekey pubbliche sono firmate e ruotate alla scadenza, mentre il fingerprint Ed25519 rimane stabile. Il boundary restituisce esclusivamente fingerprint, scadenza e invito pubblico `sylphy:`; il segreto del vault è device-bound e proviene dal secure storage della piattaforma.

## Veilid

`veilid-core` è una dipendenza opzionale del core. Con la feature `veilid`, `VeilidNode` avvia `VeilidAPI` con un callback che accetta soltanto `AppMessage` opachi entro 32 KiB e li conserva in una coda nativa limitata a 256 elementi. Gestisce inoltre attach, routing context, private route, import del route blob e shutdown. Il lifecycle dell'app usa il `program_name` stabile `sylphy` e uno storage directory persistente specifico dell'app; non devono essere serializzati o scritti nei log i segreti di configurazione. Su Android `MainActivity` carica la libreria e registra `Context`/JVM prima di `super.onCreate`, quindi prima che Dart possa chiamare `start_veilid`. Il core rifiuta esplicitamente lo startup con `platform_not_initialized` se questo contratto non è soddisfatto.

I comandi ABI `start_veilid`, `veilid_status` e `stop_veilid` sono sincroni rispetto al boundary C ma usano un runtime Tokio dedicato. Lo stato restituito a Flutter è ridotto a attachment, readiness pubblica, numero aggregato di peer e quantità di envelope in attesa. NodeId, route blob, payload e dettagli della routing table non attraversano il boundary. `list_conversations` e `list_messages` partono vuoti e non generano dati campione.

`add_contact` accetta un alias locale e un codice Base64 senza padding contenente un `PublicBundle` JSON. Il core impone limiti di dimensione, versione e cardinalità, verifica entrambe le firme Ed25519, richiede la capability ibrida e rifiuta bundle scaduti o duplicati. Il bundle pubblico e l'alias vengono conservati soltanto nella directory applicativa nativa e non sono pubblicati su Veilid. Il contatto esposto alla UI è sempre `pending`: l'import non crea una sessione, non marca il contatto come verificato e non abilita l'invio.

Il layer di trasporto riceve esclusivamente `MessageEnvelope` già autenticati e cifrati. Bundle pubblici firmati, mailbox cifrate e riferimenti ad allegati cifrati sono gli unici record pubblicabili.

## Ratchet

La feature `signal-ratchet` integra `signalapp/libsignal` v0.99.3 tramite commit immutabile. `SignalRatchetAccount` crea il dispositivo locale e gli store Signal, genera e firma il bundle di prekey EC/Kyber, stabilisce la sessione autenticata e delega cifratura, decrittazione, DH ratchet, ratchet post-quantum e skipped-message keys al provider ufficiale. Non esiste una ratchet crittografica sviluppata nel progetto.

`RatchetWireMessage` converte esclusivamente `SignalMessage` e `PreKeySignalMessage` in un ciphertext Base64 opaco, rifiuta tipi non ammessi e payload oltre 32 KiB. Il self-test ABI esegue bootstrap Alice/Bob, risposta di acknowledgement, rotazione della ratchet e consegna dei messaggi nell'ordine 3-1-2.

Lo store usato dall'adapter è attualmente in memoria. La UI di invio deve restare scollegata finché identity, prekey, signed prekey, Kyber prekey e session record non vengono caricati e salvati atomicamente nel vault cifrato. Questa condizione evita sessioni perse al riavvio e impedisce un fallback non dichiarato.
