# Core nativo e integrazione Veilid

## ABI

Il confine Flutter/Rust è una singola ABI C JSON. Le richieste sono UTF-8 e le risposte non riportano password, chiavi, plaintext o diagnostica crittografica. Ogni stringa restituita dal core viene liberata esclusivamente tramite `sylphy_core_free_string`.

## Veilid

`veilid-core` è una dipendenza opzionale del core. Con la feature `veilid`, `VeilidNode` riceve una `VeilidAPI` già avviata, gestisce attach, routing context e shutdown. Il lifecycle dell'app deve avviare il nodo usando un `program_name` stabile e uno storage directory specifico dell'app; non devono essere serializzati o scritti nei log i segreti di configurazione.

Il layer di trasporto riceve esclusivamente `MessageEnvelope` già autenticati e cifrati. Bundle pubblici firmati, mailbox cifrate e riferimenti ad allegati cifrati sono gli unici record pubblicabili.

## Ratchet

Le primitive di vault, identity, KEM e envelope sono presenti nel core. La Double Ratchet richiede invece un provider compatibile con Signal, auditato e dotato di persistenza cifrata delle sessioni. Non viene sostituita da una ratchet custom; finché il provider non è integrato, l'API non permette invii.
