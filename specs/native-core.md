# Core nativo e integrazione Veilid

## ABI

Il confine Flutter/Rust è una singola ABI C JSON. Le richieste sono UTF-8 e le risposte non riportano password, chiavi, plaintext o diagnostica crittografica. Ogni stringa restituita dal core viene liberata esclusivamente tramite `sylphy_core_free_string`.

## Veilid

`veilid-core` è una dipendenza opzionale del core. Con la feature `veilid`, `VeilidNode` avvia `VeilidAPI` con un callback senza contenuto, gestisce attach, routing context, private route, import del route blob e shutdown. Il lifecycle dell'app usa il `program_name` stabile `sylphy` e uno storage directory specifico dell'app; non devono essere serializzati o scritti nei log i segreti di configurazione. Su Android `MainActivity` registra prima `Context` e JVM nel core Veilid tramite JNI.

Il layer di trasporto riceve esclusivamente `MessageEnvelope` già autenticati e cifrati. Bundle pubblici firmati, mailbox cifrate e riferimenti ad allegati cifrati sono gli unici record pubblicabili.

## Ratchet

Le primitive di vault, identity, KEM e envelope sono presenti nel core. La Double Ratchet richiede invece un provider compatibile con Signal, auditato e dotato di persistenza cifrata delle sessioni. Non viene sostituita da una ratchet custom; finché il provider non è integrato, l'API non permette invii.
