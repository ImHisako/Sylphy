# Core nativo e integrazione Veilid

## ABI

Il confine Flutter/Rust è una singola ABI C JSON. Le richieste sono UTF-8 e le risposte non riportano password, chiavi, plaintext o diagnostica crittografica. Ogni stringa restituita dal core viene liberata esclusivamente tramite `sylphy_core_free_string`.

## Veilid

`veilid-core` è una dipendenza opzionale del core. Con la feature `veilid`, `VeilidNode` avvia `VeilidAPI` con un callback senza contenuto, gestisce attach, routing context, private route, import del route blob e shutdown. Il lifecycle dell'app usa il `program_name` stabile `sylphy` e uno storage directory specifico dell'app; non devono essere serializzati o scritti nei log i segreti di configurazione. Su Android `MainActivity` registra prima `Context` e JVM nel core Veilid tramite JNI.

I comandi ABI `start_veilid`, `veilid_status` e `stop_veilid` sono sincroni rispetto al boundary C ma usano un runtime Tokio dedicato. Lo stato restituito a Flutter è ridotto a attachment, readiness pubblica e numero aggregato di peer. NodeId, route blob e dettagli della routing table non attraversano il boundary.

Il layer di trasporto riceve esclusivamente `MessageEnvelope` già autenticati e cifrati. Bundle pubblici firmati, mailbox cifrate e riferimenti ad allegati cifrati sono gli unici record pubblicabili.

## Ratchet

La feature `signal-ratchet` integra `signalapp/libsignal` v0.99.3 tramite commit immutabile. `SignalRatchetAccount` crea il dispositivo locale e gli store Signal, genera e firma il bundle di prekey EC/Kyber, stabilisce la sessione autenticata e delega cifratura, decrittazione, DH ratchet, ratchet post-quantum e skipped-message keys al provider ufficiale. Non esiste una ratchet crittografica sviluppata nel progetto.

`RatchetWireMessage` converte esclusivamente `SignalMessage` e `PreKeySignalMessage` in un ciphertext Base64 opaco, rifiuta tipi non ammessi e payload oltre 32 KiB. Il self-test ABI esegue bootstrap Alice/Bob, risposta di acknowledgement, rotazione della ratchet e consegna dei messaggi nell'ordine 3-1-2.

Lo store usato dall'adapter è attualmente in memoria. La UI di invio deve restare scollegata finché identity, prekey, signed prekey, Kyber prekey e session record non vengono caricati e salvati atomicamente nel vault cifrato. Questa condizione evita sessioni perse al riavvio e impedisce un fallback non dichiarato.
