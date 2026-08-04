# Sylphy Veilid-Ready Messaging Design

**Data:** 2026-08-04  
**Stato:** approvato per pianificazione  
**Piattaforme:** Windows, Linux, Android  
**Licenza del progetto:** compatibile con AGPL-3.0

## Obiettivo

Consentire a due persone di stabilire un contatto privato tramite QR code o link verificabile e di scambiarsi messaggi uno-a-uno, in tempo reale oppure dopo un periodo offline, senza directory pubblica né server centrale.

## Decisioni vincolanti

- Veilid è il trasporto P2P: route private per consegna in tempo reale e DHT per discovery esplicita e mailbox offline.
- L'integrazione Veilid usa la binding ufficiale `veilid-flutter`, che contiene i target Windows, Linux e Android.
- Flutter gestisce UI, lifecycle e stato di rete; un core Rust separato custodisce vault, identità, sessioni e plaintext.
- Le sessioni usano un bootstrap ibrido X25519 + ML-KEM-768 e una Double Ratchet fornita da `libsignal` tramite un adapter nativo verificato.
- `libsignal` è AGPL-3.0; distribuzione, sorgenti e dipendenze devono restare compatibili con tale licenza.
- Non esiste ricerca per username, rubrica pubblica o directory degli utenti.
- Nessuna funzione di invio è abilitata senza vault sbloccato, nodo Veilid attached, invito verificato e sessione autenticata.

## Riferimenti esterni

- [Veilid: lifecycle applicativo](https://veilid.gitlab.io/developer-book/apps/api/index.html)
- [Veilid: route private](https://veilid.gitlab.io/developer-book/concepts/private-routing.html)
- [Veilid: DHT e schema SMPL](https://veilid.gitlab.io/developer-book/concepts/dht.html)
- [Veilid: messaggi di callback](https://veilid.gitlab.io/developer-book/apps/api/callback-messages.html)
- [Signal: Double Ratchet](https://signal.org/docs/specifications/doubleratchet/)
- [Signal libsignal](https://github.com/signalapp/libsignal)

## Architettura

```text
Flutter UI
  -> MessagingCoordinator
    -> VeilidGateway (binding ufficiale veilid-flutter)
    -> SecureCore FFI (Rust)
      -> vault, identità, inviti, sessioni, envelope, persistenza
      -> adapter libsignal
```

### VeilidGateway

`VeilidGateway` inizializza il core Veilid una sola volta, applica la configurazione per piattaforma, esegue `startup`, `attach`, `detach` e `shutdown`, e pubblica uno stream tipizzato di aggiornamenti. Deve usare routing context sicuri e target private route per tutti gli `AppMessage`.

Riceve e tratta questi eventi:

- `Attachment`: aggiorna lo stato rete visibile nell'interfaccia;
- `AppMessage`: inoltra byte opachi al `SecureCore`;
- `RouteChange`: sospende la route interessata, richiede al coordinatore il nuovo blob dal DHT e reimporta la route;
- `ValueChange`: sincronizza solo i subkey della mailbox o del record di contatto osservato;
- `Shutdown`: porta lo stato UI a nodo non disponibile e conserva la coda locale cifrata.

`VeilidGateway` non interpreta envelope, non calcola chiavi di sessione e non registra payload o capability nei log.

### SecureCore

Il core Rust espone comandi FFI asincroni per:

- creare e sbloccare identità e vault;
- creare, firmare, verificare, importare e revocare inviti;
- derivare e confrontare il codice di sicurezza;
- creare e aprire sessioni ibride;
- ratchettare, sigillare, aprire, deduplicare e persistere envelope;
- creare e ruotare i descrittori di mailbox;
- elencare conversazioni, messaggi e azioni Veilid senza dati segreti.

Il core conserva in un vault Argon2id + XChaCha20-Poly1305 le chiavi Ed25519, X25519, ML-KEM-768, stato Double Ratchet, chiavi di scrittura DHT, messaggi e code. Il plaintext esce dal core soltanto come messaggio già validato da renderizzare oppure come testo appena composto da cifrare.

### Capacità DHT

La binding Veilid richiede una capability di scrittura per aggiornare un subkey DHT. Le capability sono per-contatto e per-epoch, persistite solamente dal `SecureCore`, consegnate al gateway solo per la singola chiamata FFI e mai registrate. Questa eccezione limitata al boundary della binding deve avere un audit di memoria e logging dedicato prima del rilascio.

## Protocollo di invito

### Formato

Un invito è un URI `sylphy://invite/v1/<base64url-cbor>` con campi versionati:

```text
InviteV1 {
  protocol_version,
  invite_id,
  expires_at,
  inviter_public_bundle,
  contact_record_key,
  reply_writer_capability,
  fingerprint_commitment,
  signature_ed25519
}
```

`reply_writer_capability` è un token di scrittura DHT monouso e con TTL breve. L'invito è un bearer secret: chi lo riceve può tentare l'accettazione, ma il contatto diventa attivo solo dopo verifica reciproca del codice di sicurezza fuori banda.

### Creazione

1. L'invitante crea o sblocca il vault e avvia Veilid.
2. Il core crea un `ContactRecord` DHT con schema `SMPL`, owner dell'invitante e un writer con un solo range per la risposta dell'invitato.
3. L'invitante alloca una private route, salva blob e bundle pubblico firmato nel record, e inserisce nel link solo il record key e la capability di risposta.
4. Il core firma il contenuto dell'invito, calcola il commitment della fingerprint e imposta una scadenza breve.
5. Flutter mostra QR e link copiabile senza visualizzare chiavi private.

### Importazione e verifica

1. L'invitato scansiona il QR o incolla il link.
2. Il core rifiuta versione non supportata, firma non valida, invito scaduto, invito già consumato o limiti fuori specifica.
3. Il gateway legge il `ContactRecord`; il core verifica bundle e firma, quindi calcola un codice di sicurezza breve derivato da `invite_id`, identità e bundle.
4. Le due persone confrontano e confermano manualmente il codice tramite un canale esterno.
5. Solo dopo entrambe le conferme, il core consuma la capability monouso e pubblica l'accettazione cifrata.

## Contact record, mailbox e consegna

### ContactRecord

Il `ContactRecord` contiene solo dati pubblici firmati o ciphertext:

- bundle pubblico firmato dell'owner;
- blob della private route attuale;
- descrittore dell'ultima mailbox inbound dell'owner;
- stato di revoca o scadenza dell'invito;
- versione del record e contatore di rotazione.

Quando Veilid segnala la morte di una route locale, l'owner crea una nuova route e aggiorna lo stesso record. Il consumer sospende gli invii, rilegge il record, importa il nuovo blob e riprende solo dopo import riuscito.

### Mailbox unidirezionale

Ogni coppia stabilita mantiene due mailbox, una per ciascuna direzione. Una mailbox è un record DHT `SMPL` con:

- owner: destinatario della mailbox;
- member writer: mittente del contatto;
- subkey separati per messaggi, receipt e rotazione;
- capacità di scrittura e numero di epoch limitati;
- payload esclusivamente envelope cifrati applicativamente.

Un nuovo epoch viene creato prima dell'esaurimento dei subkey o della dimensione del record. Il descrittore e la nuova capability viaggiano in un envelope ratchettato; l'epoch precedente resta in sola lettura fino a svuotamento e poi è rimosso localmente. Ogni write è idempotente: la stessa coppia `(conversation_id, message_id)` può essere ritentata senza creare un messaggio UI duplicato.

### Flusso di consegna

1. Il core trasforma plaintext e metadata in un envelope ratchettato e autenticato.
2. Se la private route importata è attiva, `VeilidGateway` invia l'envelope con `AppMessage` sul routing context sicuro.
3. In caso di nodo non attached, route non importabile, timeout o errore di delivery, il coordinatore inserisce lo stesso envelope nella mailbox DHT dell'epoch corrente.
4. Il destinatario processa `AppMessage` o `ValueChange`, passa bytes al core e mostra il messaggio solo dopo autentica, deduplica e decifratura riuscite.
5. Una receipt ratchettata conferma la sincronizzazione; non sono previsti read receipt nel primo rilascio.

## Sessioni e sicurezza

### Bootstrap

Il core verifica l'Ed25519 bundle del contatto e rifiuta capability che non includono il profilo ibrido. Esegue X25519 e ML-KEM-768, calcola un transcript hash che include versione, identità, prekey, `invite_id` e capability, e deriva la root key con HKDF-SHA-256.

### Double Ratchet

L'adapter nativo usa `libsignal` AGPL-3.0, fissato a commit o release, per ratchettare chiavi e gestire messaggi fuori ordine. L'integrazione è un gate di rilascio: deve dimostrare, con un test a due processi, che la root key ibrida inizializza una sessione senza downgrade e che key, header, skipped key e stato non attraversano il boundary Dart. Se l'API pubblica di `libsignal` non permette questa inizializzazione in modo supportato, Sylphy non viene dichiarata pronta e non viene sostituita da una ratchet custom.

### Rifiuti obbligatori

- bundle non firmato, non valido o senza ML-KEM-768;
- invito revocato, scaduto, riutilizzato o oltre limite;
- mismatch di fingerprint o conferma mancante;
- sessione non autenticata, header non valido, replay o superamento della finestra skipped-key;
- envelope oltre i limiti, nonce non valido o AAD non corrispondente;
- downgrade del profilo, versione o capability;
- tentativo di invio a NodeId diretto anziché a private route.

## UX

### Stati dell'app

```text
VaultLocked
  -> NodeStarting
  -> NodeAttached
  -> InvitePendingVerification
  -> ContactActive
  -> DeliveryQueued | DeliverySynced
  -> ContactRevoked
```

### Schermate e comportamenti

- onboarding: crea o sblocca il vault e indica in modo neutro lo stato del nodo;
- contatti: crea invito, mostra QR/link, importa da fotocamera o clipboard;
- verifica: mostra codice breve, avvisa di confrontarlo fuori banda e richiede conferma esplicita;
- chat: mostra stati `in coda`, `sincronizzato`, `errore sicuro`; disabilita il composer quando la sessione non è attiva;
- dettagli contatto: fingerprint, data verifica, stato route/mailbox e revoca;
- privacy: non mostra NodeId, chiavi o payload nei log, notifiche o crash report.

## Gestione errori e retry

- Veilid detached: conserva l'envelope cifrato in coda locale e riprova dopo `Attachment` attached;
- private route morta: blocca l'invio, ricarica contact record, reimporta e tenta una sola volta prima della mailbox;
- write DHT non conclusa: mantiene lo stesso `message_id` e ritenta con backoff limitato;
- ValueChange duplicato o fuori ordine: il core confronta `message_id`, epoch, sequence e ratchet header;
- errore crittografico: scarta l'input, espone errore generico, non tenta fallback;
- revoca: interrompe sessione e mailbox, elimina capability locali e richiede un nuovo invito.

## Compatibilità e packaging

- `veilid-flutter` è fissato alla stessa release Veilid per tutte le piattaforme e aggiornato come singola operazione con test di regressione;
- il core Rust è distribuito come libreria FFI per Windows, Linux e Android ABI supportati;
- Android include le librerie Veilid e `libsignal` richieste per ogni ABI supportata;
- Windows e Linux distribuiscono le DLL o shared library con il bundle Flutter;
- la pipeline di build fallisce se manca una libreria nativa prevista o se le versioni Veilid non coincidono.

## Verifica e definition of done

### Test obbligatori

- unit test e vector test per vault, invito, bundle, handshake, envelope, deduplica e ratchet adapter;
- integrazione a due nodi: Windows↔Linux, Windows↔Android e Linux↔Android;
- importazione invito, fingerprint mismatch, scadenza, riuso e revoca;
- consegna realtime, consegna offline, retry DHT, duplicate delivery, messaggi riordinati e rotazione route;
- restart app, vault lock/unlock, rete intermittente e mailbox epoch rollover;
- test FFI che verificano assenza di chiavi e plaintext nelle risposte di stato e nei log.

### Condizioni per dichiarare il rilascio pronto

- i test obbligatori passano sulle tre piattaforme;
- due utenti reali completano QR/link, verifica fingerprint e invio reciproco con uno dei due offline;
- le mailbox tornano a zero dopo sync senza duplicati;
- il gate `libsignal` dimostra compatibilità della root key ibrida;
- sono presenti SBOM, licenze AGPL, versioni bloccate e istruzioni di build riproducibili;
- nessun invio reale usa `LocalDemoMessagingBridge` o fallback non autenticati.

## Fuori dal primo rilascio

- chat di gruppo;
- allegati grandi e download chunked;
- notifiche push;
- directory, username o contact discovery globale;
- read receipt;
- backup o migrazione multi-device;
- supporto web, macOS e iOS.
