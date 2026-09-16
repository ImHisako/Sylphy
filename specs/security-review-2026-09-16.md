# Review di sicurezza — 16 settembre 2026

Review del codice locale dopo l'estensione degli allegati a 2 MiB. Sono stati
esaminati ricezione/invio, riferimenti DHT, cifratura, persistenza e backup,
sincronizzazione dispositivi, rendering degli allegati e aggiornamenti.
Si tratta di analisi statica con test di regressione locali, non di un audit
indipendente o di un penetration test della rete pubblica. Non è stata eseguita
una scansione aggiornata delle CVE delle dipendenze.

## Rilievi iniziali e stato delle correzioni

### 1. P2 — Download automatici possono monopolizzare il worker dei messaggi

**Evidenza:** `native/core/src/messaging_adapter.rs:2107` scarica l'allegato prima
di salvare il messaggio; il ciclo a riga 1708 tratta i payload in sequenza.
`native/core/src/veilid_adapter.rs:793` legge i chunk con chiamate di rete
sincrone consecutive. L'operazione FFI conserva `COMMAND_LOCK`
(`native/core/src/ffi.rs:221`). Non esiste un budget complessivo del download,
una coda separata per gli allegati o una quota per mittente.
I contatti sconosciuti sono ammessi per impostazione iniziale
(`lib/core/privacy/privacy_settings.dart:18`).

**Scenario:** un mittente ammesso può inviare riferimenti formalmente validi a
blob lenti/incompleti, oppure molti allegati. Ogni tentativo ritarda l'elaborazione
degli altri messaggi e dei comandi accodati; gli errori di rete vengono ritentati.
Anche allegati validi riempiono automaticamente l'archivio globale da 64 MiB.
Il limite per file impedisce allocazioni illimitate di un singolo blob, ma non
risolve la monopolizzazione del worker o l'esaurimento cumulativo dello spazio.

**Correzione proposta:** salvare prima un riferimento autenticato con stato
"da scaricare", usare una coda dedicata con concorrenza, deadline, cancellazione
e quote per mittente; richiedere l'accettazione degli allegati da sconosciuti.
Verificare che un riferimento indisponibile non impedisca la ricezione di un
messaggio di testo successivo.

**Stato: corretto.** La ricezione valida e salva il riferimento autenticato nel
log cifrato e completa la transazione Signal senza leggere i chunk. Il file
viene recuperato solo premendo «Scarica allegato», anche per i contatti noti.
Un worker nativo separato esegue al massimo un download per volta, con massimo
quattro richieste in totale e una per mittente. I comandi della chat non
attendono il worker. Ogni fetch ha una deadline complessiva di 30 secondi per
le operazioni di rete, più la chiusura limitata dei record (massimo un secondo
per record). L'annullamento rifiuta immediatamente il risultato e interrompe
la lettura prima del chunk successivo; una richiesta di rete già avviata
termina entro la deadline.

Gli errori richiedono un nuovo tentativo esplicito e non producono cicli di
download automatici. Risultati di un altro account, riferimenti sostituiti e
messaggi cancellati vengono ignorati. I riferimenti restano disponibili dopo
un riavvio; i trasferimenti pendenti non ripartono senza richiesta. I test
verificano la ricezione di testo dopo un allegato indisponibile, il riavvio,
la persistenza del risultato, le quote e l'annullamento. Il limite globale
dell'archivio resta attivo.

### 2. P2 — Anteprime immagini senza limite ai pixel decodificati

**Evidenza:** `lib/features/messenger/messenger_home.dart:3762` usa `Image.memory`
per l'anteprima e riga 3668 per l'immagine ingrandita. Il codice non verifica
dimensioni/pixel o numero di frame e non imposta una dimensione di decodifica.
I parametri `width` e `height` dell'anteprima limitano il layout del widget.

**Scenario:** un allegato compresso piccolo può descrivere un'immagine molto
grande; aprendo la conversazione il client ne avvia automaticamente la
decodifica. Il budget del file non limita la memoria necessaria al bitmap e
un'immagine scelta ad hoc può causare elevato consumo di memoria o chiusura
del processo. L'effetto esatto dipende dal codec e dalla piattaforma; non è
stato provocato un crash durante questa review.

**Correzione proposta:** controllare dimensioni e budget totale dei pixel prima
della decodifica, limitare i frame animati e generare anteprime con dimensioni
di decodifica limitate. Applicare lo stesso budget alla vista ingrandita.

**Stato: corretto.** Anteprima e vista ingrandita usano `SafeAttachmentImage`.
Il descrittore legge i metadati prima di creare un bitmap: limite di 8.192 pixel
per lato e 16.777.216 pixel complessivi, oltre al limite del file compresso.
Sono ammesse solo immagini con un frame; GIF/WebP animati restano salvabili
come file. La decodifica produce al massimo 600 pixel sul lato maggiore per
l'anteprima e 2.048 per la vista ingrandita. Le decodifiche sono serializzate e
buffer, codec e immagini vengono rilasciati esplicitamente, anche chiudendo
la vista durante il caricamento. Gli avatar remoti usano lo stesso controllo,
con anteprima limitata a 128 pixel.

I test usano un PNG con metadati da 10.000×10.000 pixel e contenuto compresso
inferiore a 1 KiB, un GIF con due frame, dati corrotti e immagini valide.
Verificano rifiuto, ridimensionamento, recupero dopo errore e distruzione del
widget durante la decodifica.

## Verifiche che non hanno prodotto una vulnerabilità confermata

La struttura `PublishedIdentity` può contenere una mailbox con credenziale di
scrittura, ma `identity.rs:392` costruisce il documento pubblico passando `None`
per la mailbox. La presenza del campo nel modello non dimostra un'esposizione
nel percorso attuale. Questa ipotesi è stata esclusa dai rilievi.

L'updater limita host e redirect HTTPS, verifica dimensione e SHA-256 del
pacchetto e ricontrolla il file prima dell'installazione. Su desktop la radice
di fiducia resta l'account/repository GitHub: checksum e asset arrivano dalla
stessa origine. Una firma di release con chiave separata sarebbe un ulteriore
rafforzamento; non è stata dimostrata una possibilità di bypass dei controlli
esistenti da parte di un normale mittente della chat.

## Modifiche effettuate sugli allegati

- Limite condiviso di 2 MiB nel client e nel core, inclusi gruppi e canali.
- Suddivisione del cifrato in record da massimo 768 KiB e chunk da 24 KiB:
  evita il tetto reale di 1 MiB per record di Veilid 0.5.7. La stessa suddivisione
  serve i blob di sincronizzazione, che conservano il tetto di 3 MiB.
- Riferimenti multipli versionati e limitati a quattro record, senza duplicati
  o riferimenti annidati; lettura dei vecchi riferimenti singoli mantenuta.
- Limite Base64 verificato prima della decodifica in invio; dimensione dichiarata,
  numero di chunk, chiave e nonce controllati prima del fetch in ricezione.
- Verifica della lunghezza del cifrato e dell'autenticazione AEAD prima di
  rendere disponibile il file; chiave ricevuta azzerata al rilascio.
- Pulizia dei record già pubblicati in caso di pubblicazione incompleta e
  cancellazione idempotente dei record già rimossi.
- Il tetto degli inviti ai gruppi resta 700 KiB; quello dell'archivio resta 64 MiB.

I file sopra 700 KiB richiedono client aggiornati a entrambe le estremità,
inclusi i dispositivi collegati. Ricompilare la libreria nativa insieme a Flutter.
La correzione richiede ABI 14: il client e il controllo di build Android rifiutano
le vecchie librerie native, per evitare un aggiornamento dell'interfaccia che
lasci attivo il precedente percorso vulnerabile.
Non è stato eseguito un trasferimento reale fra due dispositivi sulla DHT pubblica.

## Verifiche precedenti (estensione a 2 MiB)

- Suite Flutter completa: 137 test superati; analisi statica senza problemi.
- Test Rust senza feature di rete: 34 superati, 1 benchmark ignorato.
- Suite Rust con `signal-ratchet`: 50 unit test e 5 test del contratto di
  sicurezza superati; 1 benchmark ignorato.
- Test aggiunti per file da 1 MiB e 2 MiB, cifrato alterato, metadati malformati,
  rifiuto dei file oltre limite, rollback di pubblicazione, suddivisione dei blob
  di sync e persistenza/backup degli allegati grandi.
- `cargo check` con `veilid,signal-ratchet` superato.
- Test mirato con Signal: backup, riapertura del log e applicazione della
  sincronizzazione di un allegato da 2 MiB superati.
- La suite con `veilid,signal-ratchet` non è arrivata all'esecuzione: il linker
  GNU Windows fallisce nella DLL della dipendenza `veilid-core` con
  `export ordinal too large: 127999`. La verifica di compilazione con le stesse
  feature passa; il test completo va eseguito sulla toolchain supportata/CI.

## Verifiche delle correzioni

- Suite Flutter completa dopo l'introduzione dei controlli: 145 test superati.
- Dopo l'estensione agli avatar remoti: 47 test mirati Flutter superati;
  `flutter analyze --no-pub` senza problemi.
- Tre test nativi dedicati a riferimenti differiti, isolamento del worker,
  cancellazione, quote e protezione dal cambio account: superati con Signal.
- Suite Rust completa con `signal-ratchet`: 53 unit test e 5 test del contratto
  di sicurezza superati, nessun errore; 1 benchmark ignorato.
- `cargo check --features veilid,signal-ratchet --tests`, `cargo fmt --check`
  e `git diff --check`: superati. Resta il limite del linker GNU sopra descritto
  per l'esecuzione dei test con Veilid.
- Resta da eseguire il trasferimento end-to-end su due dispositivi reali;
  nessuna release o libreria nativa distribuibile è stata generata.
