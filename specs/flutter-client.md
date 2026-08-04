# Contratto del client Flutter

## Responsabilità

Il client Flutter mostra solo dati già disponibili localmente e passa il testo appena composto al bridge di sicurezza. Non conserva password, chiavi private, root key, chain key, bundle di prekey non protetti o envelope decifrati più a lungo del necessario per il rendering.

## Implementazione richiesta del bridge

L'implementazione di produzione di `SecureMessagingBridge` deve essere un adapter minimo per il core Rust/FFI. Il core è responsabile di:

- sblocco e blocco del vault cifrato;
- verifica dell'identità e del bundle di prekey;
- handshake ibrido X25519 + ML-KEM-768;
- ratchet, replay window e deduplicazione;
- cifratura del payload e costruzione dell'envelope versionato;
- pubblicazione e ricezione Veilid di soli envelope opachi;
- persistenza dei messaggi e metadata nel vault cifrato.

## Vincoli di sicurezza

- Il bridge deve rifiutare l'invio se non esiste una sessione autenticata.
- Il bridge non deve fare fallback silenzioso dal profilo ibrido a quello classico.
- Gli errori esposti alla UI non devono includere plaintext, chiavi o serializzazioni dell'envelope.
- Le conversazioni e i messaggi consegnati alla UI provengono solo da record già validati, decrittati e limitati dal core.

## Stato attuale

`NativeCoreClient` carica opzionalmente l'ABI C del core Rust su Windows, Linux e Android ed espone stato del core, self-test del profilo ibrido, self-test Double Ratchet e lifecycle Veilid. `VeilidService` avvia il nodo nello storage applicativo e traduce la telemetria aggregata in stati UI neutrali. L'assenza della libreria non viene mai trasformata in un invio meno sicuro: la UI dichiara esplicitamente la modalità anteprima.

`LocalDemoMessagingBridge` è intenzionalmente un'implementazione in memoria per preview e test widget. Non è un vault e non deve essere usato oltre la fase di interfaccia. Il provider Signal è integrato e verificabile dal pannello Privacy; apertura sessione e invio UI restano bloccati fino alla persistenza cifrata degli store Signal.
