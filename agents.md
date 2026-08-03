# AGENTS.md

## Scopo

Questo documento definisce come progettare e sviluppare una messenger privata, decentralizzata e mobile-first con **Flutter** come frontend, **Veilid** come core di rete, un layer di **Application E2EE** ispirato al Signal Protocol, e un profilo crittografico ibrido classico + post-quantum. Veilid fornisce un core P2P utilizzabile in applicazioni mobili e desktop, con API di routing pubblico e privato esposte dal core della libreria [cite:59]. Il protocollo Signal usa la Double Ratchet per derivare nuove chiavi a ogni messaggio e limitare l'impatto della compromissione delle chiavi nel tempo [cite:55][cite:56]. NIST raccomanda ML-KEM-768 come parametro predefinito per un buon equilibrio tra margine di sicurezza e costo prestazionale [cite:54].

## Obiettivo del progetto

L'applicazione deve offrire:

- messaggistica privata end-to-end;
- identità crittografiche forti e verificabili;
- trasporto decentralizzato attraverso Veilid;
- funzionamento mobile-first;
- resistenza a compromissioni future tramite meccanismi post-quantum ibridi;
- storage locale cifrato per profili, chiavi, allegati e cache di sincronizzazione.

## Principi architetturali

### Regole non negoziabili

- Il frontend Flutter non contiene logica crittografica sensibile se questa può vivere in un layer nativo isolato.
- Il plaintext dei messaggi non deve mai uscire dal boundary applicativo già cifrato.
- Veilid trasporta solo payload opachi già autenticati e cifrati a livello applicativo.
- La rete non deve avere accesso a chiavi di sessione, chiavi di ratchet o contenuto leggibile.
- Le chiavi persistenti devono essere custodite in un vault cifrato locale con KDF memory-hard.
- Ogni protocollo deve essere versionato e i messaggi devono essere forward-compatible.

### Stack logico

```text
┌──────────────────────────────────────────────────────────────┐
│ Flutter UI                                                   │
│ chat, contatti, onboarding, impostazioni, allegati          │
├──────────────────────────────────────────────────────────────┤
│ Dart domain layer                                            │
│ use cases, state management, repositories, protocol adapter │
├──────────────────────────────────────────────────────────────┤
│ Secure bridge                                                │
│ flutter_rust_bridge / FFI / platform channels minimi        │
├──────────────────────────────────────────────────────────────┤
│ Native security core                                         │
│ Veilid node + Signal-style session engine + PQ hybrid KEM   │
├──────────────────────────────────────────────────────────────┤
│ Encrypted vault                                              │
│ Argon2id + XChaCha20-Poly1305                                │
├──────────────────────────────────────────────────────────────┤
│ Veilid network core                                          │
│ routing, DHT/storage, private routes, peer operations       │
└──────────────────────────────────────────────────────────────┘
```

Veilid core è pensato per creare un nodo utilizzabile anche in applicazioni mobili e consente l'accesso a operazioni di routing pubblico e privato tramite la sua API [cite:59]. Questo rende sensato usarlo come rete sottostante, mantenendo la sicurezza del contenuto in un layer applicativo separato [cite:59].

## Profilo crittografico richiesto

### Vault locale cifrato

Il vault locale protegge chiavi, sessioni, cache, metadati sensibili e allegati locali.

| Componente | Scelta |
|---|---|
| Password KDF | Argon2id |
| Cifratura dati a riposo | XChaCha20-Poly1305 |
| Chiavi derivate | Distinte per vault master, metadata, attachments |
| Secret storage device-bound | Keystore/Keychain/StrongBox quando disponibile |

Argon2id è adatto come KDF memory-hard per vault locali perché rallenta attacchi offline a costo computazionale e di memoria elevato per l'attaccante. XChaCha20-Poly1305 è appropriato per cifrare grandi volumi di dati locali grazie al nonce esteso e all'AEAD moderno.

### Application E2EE

| Funzione | Scelta |
|---|---|
| Identità firma | Ed25519 |
| Scambio classico | X25519 |
| Scambio PQ | ML-KEM-768 |
| Session bootstrap | Handshake ibrido |
| Ratchet | Double Ratchet v3 |
| AEAD messaggi | XChaCha20-Poly1305 o ChaCha20-Poly1305 |
| HKDF | HKDF-SHA-256 o SHA-512 coerente con il profilo |

La Double Ratchet deriva nuove chiavi per ogni messaggio e integra valori Diffie-Hellman per ottenere forward secrecy e recupero nel tempo dopo una compromissione [cite:55][cite:56]. ML-KEM è standardizzato in FIPS 203 con tre parameter set, e ML-KEM-768 è indicato da NIST come default consigliato [cite:54].

## Handshake ibrido consigliato

### Obiettivo

La sessione iniziale deve essere sicura sia contro avversari classici sia contro raccolta oggi / decrittazione domani. L'handshake deve quindi combinare un contributo classico X25519 e un contributo post-quantum ML-KEM-768, fondendoli in un segreto radice usato per inizializzare la ratchet [cite:54][cite:56].

### Materiale chiavi per utente

Ogni identità utente deve mantenere almeno:

- `identity_ed25519`: firma di identità;
- `signed_prekey_x25519`: prekey classica firmata;
- `signed_prekey_mlkem768`: prekey PQ firmata o autenticata dal materiale Ed25519;
- `one_time_prekeys_x25519[]`: opzionali, per ridurre replay e migliorare unlinkability;
- `one_time_prekeys_mlkem768[]`: opzionali, per handshake ibridi one-shot.

### Flusso suggerito

1. Il mittente recupera il bundle pubblico del destinatario attraverso Veilid storage o record applicativi distribuiti.
2. Il bundle contiene identità Ed25519, prekey X25519 firmata e materiale ML-KEM-768 autenticato.
3. Il mittente verifica la firma Ed25519 sul bundle prima di usare le chiavi pubbliche [cite:59].
4. Il mittente esegue X25519 verso la signed prekey del destinatario.
5. Il mittente esegue encapsulation ML-KEM-768 verso la prekey PQ del destinatario [cite:54].
6. I segreti risultanti vengono concatenati e passati a HKDF per produrre `root_key_0`.
7. `root_key_0` inizializza la Double Ratchet v3.

### KDF di composizione

Formula concettuale:

\[
root\_key\_0 = HKDF( salt = transcript\_hash, ikm = X25519\_ss || MLKEM\_ss || context )
\]

Il transcript hash deve legare versione protocollo, identity keys, prekeys usate, timestamp logico e capability flags. Questo riduce downgrade e ambiguity attack nel bootstrap iniziale.

## Double Ratchet v3

La ratchet deve essere trattata come motore di sessione applicativo, non come dettaglio di trasporto. Il protocollo Signal descrive l'uso di un ratchet simmetrico e di un DH ratchet per aggiornare continuamente le chiavi e gestire messaggi persi o fuori ordine [cite:55][cite:56].

### Requisiti della ratchet

- una root key per sessione;
- sending chain e receiving chain separate;
- supporto a skipped message keys con limiti stretti;
- ri-key quando cambia il ratchet public key remoto;
- header cifrabili o almeno minimizzati per ridurre leakage;
- session reset controllato in caso di corruzione stato.

### Raccomandazioni pratiche

- Tenere il contatore massimo di skipped keys limitato per evitare memory abuse.
- Fare garbage collection delle sessioni inattive.
- Versionare i campi header per permettere upgrade futuri a un PQ ratchet pieno.
- Separare claramente session bootstrap, transport envelope e message payload.

## Ruolo di Veilid

Veilid deve essere il **core di rete**, non il meccanismo di confidenzialità del contenuto. Il core della libreria Veilid espone API per avviare un nodo e operare nel network tramite contesti di routing pubblico e privato [cite:59]. L'architettura dell'app deve quindi sfruttare Veilid per:

- discovery e routing di peer;
- pubblicazione di bundle pubblici e record applicativi;
- trasporto di envelope cifrati;
- eventuale mailbox distribuita per destinatari offline;
- sincronizzazione di metadati non sensibili o cifrati applicativamente.

### Cosa salvare su Veilid

Consentito:
- bundle pubblici firmati;
- prekey bundle con TTL breve;
- code di messaggi cifrati e autenticati;
- puntatori cifrati ad allegati.

Vietato:
- plaintext;
- chiavi private;
- session state ratchet non cifrato;
- rubrica in chiaro;
- mapping leggibili tra identità umana e chiavi senza opt-in.

## Envelope dei messaggi

Ogni messaggio applicativo deve viaggiare come envelope serializzato e autenticato.

### Campi minimi

```text
Envelope {
  version
  message_type
  conversation_id
  sender_identity_key_id
  recipient_identity_key_id_or_group_id
  session_id
  transport_hint
  timestamp_logical
  ratchet_header
  ciphertext
  aad_commitment
  attachment_refs[]
}
```

### Proprietà desiderate

- `version` per upgrade di protocollo;
- `message_type` per distinguere handshake, message, ack, retry, prekey-refresh;
- `conversation_id` random e non derivabile dall'identità;
- `timestamp_logical` per ordinamento debole, non per fiducia forte;
- `aad_commitment` per legare header e payload.

## Allegati

Gli allegati non vanno inseriti direttamente nella ratchet se superano dimensioni piccole o medie. Il payload deve contenere:

- chiave simmetrica per allegato derivata per-file;
- metadata minimi cifrati;
- chunking opzionale;
- riferimento distribuito o pointer Veilid già cifrato.

Schema consigliato:

1. derivare `file_key` casuale;
2. cifrare allegato con XChaCha20-Poly1305;
3. pubblicare il blob cifrato o i chunk;
4. inviare nel messaggio ratchettato solo reference, hash, size e `file_key` wrap o derivata.

## AGENT roles

Questo progetto può essere sviluppato da più agenti specializzati. Ogni agente deve rispettare i boundary sotto descritti.

### 1. Architecture Agent

Responsabilità:
- definire i protocolli;
- mantenere compatibilità di versione;
- disegnare envelope, bundle, handshake, error model;
- decidere cosa vive in Flutter, cosa in Rust/nativo.

Non deve:
- implementare UI senza specifica;
- cambiare primitive crittografiche senza security review.

### 2. Crypto Agent

Responsabilità:
- implementare vault locale;
- integrare Ed25519, X25519, ML-KEM-768, HKDF, AEAD;
- costruire handshake ibrido;
- implementare Double Ratchet v3;
- gestire zeroization, serialization sicura e key rotation.

Non deve:
- esporre chiavi raw a Dart se non strettamente necessario;
- riusare nonce;
- introdurre fallback silenziosi a profili meno sicuri.

### 3. Veilid Agent

Responsabilità:
- avvio e lifecycle del nodo Veilid;
- routing contexts;
- pubblicazione e recupero record;
- inbox distribuite e retry queue;
- politiche di replica, TTL, caching e peer trust.

Non deve:
- decrittare payload applicativi;
- conoscere password utente o master key.

### 4. Flutter Agent

Responsabilità:
- UI/UX;
- state management;
- sincronizzazione con repository astratti;
- rendering chat, media, settings, bootstrap account;
- gestione permessi e lifecycle app.

Non deve:
- custodire segreti ad alta sensibilità in memoria più del necessario;
- implementare primitive crittografiche custom in Dart puro senza review.

### 5. Storage Agent

Responsabilità:
- persistenza locale cifrata;
- schema database;
- indicizzazione locale;
- eviction policy e secure delete best effort.

Non deve:
- scrivere record sensibili in chiaro su log o cache temporanee.

### 6. Security Review Agent

Responsabilità:
- threat modeling;
- audit su downgrade, replay, impersonation, metadata leaks;
- fuzzing dei parser;
- review di FFI boundary e memory safety.

## Threat model minimo

Il sistema deve esplicitamente considerare questi avversari:

- relay o peer ostili;
- raccolta passiva di traffico a lungo termine;
- compromissione di un device dopo la ricezione di messaggi passati;
- replay di prekey bundle o envelope;
- deanonymization tramite metadati, timing e graph analysis;
- downgrade del profilo PQ a classico;
- estrazione di database locale da dispositivo rubato.

### Mitigazioni richieste

- envelope già cifrati prima del trasporto;
- root keys derivate da handshake ibrido X25519 + ML-KEM-768 [cite:54];
- password vault con Argon2id e secret wrapping in secure enclave quando disponibile;
- firme Ed25519 sui bundle pubblici;
- replay window e message id deduplicati;
- capability negotiation autenticata nel transcript iniziale;
- padding e batching opzionali per ridurre metadata leakage.

## Boundary Flutter / native core

### Da implementare nel core nativo

- generazione chiavi;
- serializzazione bundle pubblici;
- handshake ibrido;
- ratchet;
- cifratura/decifratura payload;
- accesso Veilid;
- vault encryption;
- secure wipe best effort.

### Da implementare in Flutter

- schermate e componenti;
- gestione stato applicativo;
- code di invio lato UX;
- preview media già decrittati localmente;
- notifiche e badge;
- import/export account con esplicito consenso.

### Bridge API suggerita

```text
createIdentity(profileName, password)
unlockVault(password)
lockVault()
getPublicBundle()
publishPublicBundle()
startNode(config)
openSession(recipientBundle)
sendMessage(conversationId, plaintext, attachments)
receiveEnvelope(rawEnvelope)
listConversations()
listMessages(conversationId)
rotatePrekeys()
backupAccount(target)
restoreAccount(source, password)
```

## Struttura repo consigliata

```text
/apps/flutter_app
  /lib
    /features
    /core
    /ui
    /state
  /test
/packages/protocol
  dart interfaces, DTO, schema versioning
/packages/bridge
  flutter_rust_bridge bindings
/native/core
  rust security core
/native/veilid_adapter
  node lifecycle, routing, records, inbox
/native/crypto
  vault, handshake, ratchet, attachments
/specs
  protocol.md
  envelope.md
  threat-model.md
  test-vectors.md
```

## Regole di implementazione

- Nessuna crypto inventata: solo primitive note e librerie mature.
- Nessun downgrade automatico da profilo ibrido a classico senza consenso esplicito e segnalazione UX.
- Nessun messaggio inviato se la sessione non è autenticata.
- Ogni deserializzazione deve validare lunghezze, tipi, versione e limiti.
- Tutte le chiavi private esportabili devono essere protette da ulteriore wrapping.
- Il logging deve essere disattivato o minimizzato nei path sensibili.
- I crash report non devono includere payload o chiavi.

## Test richiesti

### Crypto

- test vector handshake;
- test vector ratchet;
- replay tests;
- skipped message tests;
- corruption recovery tests;
- downgrade rejection tests;
- serialization round-trip tests.

### Network

- publish/fetch bundle;
- inbox offline;
- duplicate delivery;
- reorder delivery;
- peer churn;
- high latency mobile;
- cold start con rete intermittente.

### Mobile

- app kill/resume;
- lock/unlock vault;
- biometric unlock wrapping;
- database migration cifrata;
- background notification senza plaintext;
- attachment download parziale e resume.

## Roadmap suggerita

### Fase 1

- vault locale Argon2id + XChaCha20-Poly1305;
- identità Ed25519;
- nodo Veilid integrato;
- pubblicazione bundle pubblico;
- messaggi one-shot cifrati senza ratchet completa.

### Fase 2

- handshake ibrido X25519 + ML-KEM-768;
- sessioni persistenti;
- Double Ratchet v3;
- ack, retry, deduplica;
- allegati piccoli.

### Fase 3

- mailbox distribuite offline;
- allegati grandi chunked;
- gruppi;
- contact verification UX;
- backup sicuro account.

### Fase 4

- riduzione metadata leakage;
- padded envelopes;
- private contact discovery opzionale;
- hardening anti-abuse;
- audit esterno.

## Definition of done

Una feature è completa solo se:

- ha test unitari e integrazione;
- non introduce leakage di plaintext o chiavi;
- supporta versionamento protocollo;
- è documentata nel layer spec;
- è verificata su Android e iOS reali;
- non degrada silenziosamente il profilo PQ ibrido.

## Nota finale

La combinazione più sensata per questo progetto è usare Veilid come rete sottostante e trattare la privacy del contenuto come responsabilità dell'application layer. Veilid offre il nodo e i contesti di routing utili per un'app distribuita [cite:59], mentre la Double Ratchet e un bootstrap ibrido con X25519 + ML-KEM-768 forniscono forward secrecy, recupero dopo compromissione e una traiettoria più robusta verso la resistenza post-quantum [cite:55][cite:56][cite:54].
