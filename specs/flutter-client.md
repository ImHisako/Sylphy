# Contratto del client Flutter

## Responsabilità

Il client Flutter mostra solo dati già disponibili localmente e passa il testo appena composto al bridge di sicurezza. Non conserva password, chiavi private, root key, chain key, bundle di prekey non protetti o envelope decifrati più a lungo del necessario per il rendering.

Al primo avvio `ProfileOnboarding` richiede un display name limitato a 64 caratteri e consente una foto facoltativa entro 5 MiB. Lo stesso form viene riaperto dal pannello “Il mio profilo” per modificare i campi già salvati. Questi campi sono metadati di presentazione scelti dall'utente; non costituiscono l'identità Ed25519 e non contengono chiavi. `IdentityService` conserva una chiave di sblocco casuale nel secure storage della piattaforma e chiede al core soltanto fingerprint pubblico e invito firmato. La home espone l'import contatto su mobile e desktop, ma consegna il codice invito opaco al core senza interpretarne il materiale crittografico in Dart.

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

`NativeCoreClient` carica opzionalmente l'ABI C v7 del core Rust su Windows, Linux e Android. Un isolate persistente possiede la libreria nativa e serve una coda che dà priorità a messaggi e allegati rispetto al refresh periodico, evitando la creazione di un isolate e il caricamento della DLL per ogni comando. `VeilidService` avvia il nodo nello storage applicativo persistente, ritenta startup e attachment falliti e distingue feature assente, bootstrap Android, protected/local store, configurazione e rete senza esporre dettagli interni.

`main.dart` non seleziona alcun bridge dimostrativo. Senza core usa `UnavailableMessagingBridge`, che restituisce un inbox vuoto e rifiuta import e invio; con il core usa `SylphyMessagingBridge`, che accetta soltanto read model nativi validi. Il refresh scambia prima una revisione numerica e rilegge conversazioni o messaggi soltanto quando il core segnala una mutazione, eliminando il polling della cronologia completa ogni 700 ms. L'invio appare subito nella conversazione come elemento ottimistico; un errore lo rimuove e ripristina il testo nel composer. I fake restano confinati ai test widget.
