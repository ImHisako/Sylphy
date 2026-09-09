# Revisione del codice Sylphy — 9 settembre 2026

Revisione dei sorgenti applicativi Flutter/Dart, core Rust, integrazione Android, launcher desktop, script di compilazione e CI, con lettura dei test e delle specifiche. Sono esclusi dall'audit delle implementazioni i sorgenti delle dipendenze, i file generati, gli artefatti compilati e gli asset grafici. I riferimenti indicano la copia di lavoro, che comprende le correzioni e ottimizzazioni precedenti.

Questo documento conserva la diagnosi precedente agli interventi; i riferimenti di riga storici possono essere cambiati. Le correzioni successive sono descritte in [specs/reliability.md](../specs/reliability.md). Sono implementati gli interventi sui punti 1–3 e 5–14 e sui tre difetti minori. Per il punto 4 il codice impedisce le release senza firma stabile e la CI è predisposta: resta da configurare la chiave esistente nei secret e verificare l'aggiornamento di un APK distribuito. “Confermato nel codice” nelle sezioni storiche non implica una prova su rete Veilid o dispositivi fisici.

## Verifiche dopo gli interventi

- Suite Flutter: **59 test superati**, incluse le due riproduzioni convertite in regressioni, paginazione concorrente, cache degli allegati, operazione nativa lenta e migrazione dei gruppi.
- Analisi Flutter: **nessuna segnalazione**.
- Suite Rust con `signal-ratchet`: **25 test unitari e 5 di integrazione superati**; un benchmark manuale ignorato. Le prove includono recupero del journal, log pieno e compattazione, backup della coda cifrata, aggiornamento delle repliche e degli endpoint dei gruppi, riferimento cifrato per allegati grandi e worker già occupato.
- Controllo di compilazione Rust con `veilid,signal-ratchet`: riuscito, usando il toolchain Windows GNU disponibile.
- I test usano dati sintetici e trasporti controllati. Non sono state eseguite installazioni su telefoni, misure di batteria/traffico o una release firmata. Per la firma occorre configurare i secret della CI con la chiave esistente.

## Verifiche precedenti agli interventi

- Suite Flutter completa: **53 test superati**.
- Analisi Flutter completa, incluso il nuovo file diagnostico: **nessuna segnalazione**.
- Due riproduzioni widget aggiuntive: **entrambi i difetti riprodotti**, con risposte asincrone controllate e dati fittizi.
- Nella precedente fase di questo lavoro: analisi Flutter senza segnalazioni; 23 test Rust superati con `signal-ratchet`, un benchmark manuale escluso dalla suite e poi eseguito separatamente; compilazione di controllo con `veilid,signal-ratchet` riuscita.
- Non eseguiti in questa revisione: test di interruzione del processo durante importazione, prove fra dispositivi fisici, misure di batteria/traffico, build release Android/Linux/Windows e analisi delle vulnerabilità delle dipendenze.

Le riproduzioni sono state convertite in test del comportamento corretto in [test/review_regressions_test.dart](../test/review_regressions_test.dart). Si eseguono con:

```text
flutter test --no-pub test/review_regressions_test.dart
```

Questi test ora appartengono alla suite normale e falliscono se ricompaiono la cronologia nella chat sbagliata o la sovrascrittura della nuova bozza.

## Problemi prioritari

### 1. P1 — Un vault pieno può provocare lo scarto definitivo di messaggi validi

**Condizione:** il log dei messaggi raggiunge il limite locale di 64 MiB e arriva un nuovo messaggio.

`append_message_event` restituisce `LimitExceeded` per esaurimento dello spazio consentito. Lo stesso errore è classificato da `should_discard_inbound` come pacchetto definitivamente invalido. Il ricevitore conferma quindi alla mailbox un messaggio che non ha salvato; lo slot può essere riutilizzato. Liberare spazio successivamente non garantisce più il recupero.

**Intervento:** distinguere gli errori del contenuto dagli errori di capacità dello storage; compattare quando utile, mostrare il problema e non confermare il messaggio finché non è persistito.

Riferimenti: [limite del log](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/native/core/src/messaging_adapter.rs:2696), [classificazione degli errori](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/native/core/src/messaging_adapter.rs:1525), [conferma dei pacchetti scartati](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/native/core/src/messaging_adapter.rs:1351). Confermato nel codice.

### 2. P1 — La sincronizzazione può rendere irrecuperabile un allegato sul secondo dispositivo

**Condizione:** il dispositivo A riceve un allegato e il dispositivo B riceve prima la replica di A, poi il pacchetto originale.

Per allegati con Base64 maggiore di 20 KiB, la replica elimina sia contenuto sia nome, mantenendo lo stesso ID del messaggio. B salva questa copia incompleta. Quando arriva il pacchetto originale, la deduplicazione per ID termina prima della decifratura e del recupero del file. Il messaggio può restare una semplice indicazione testuale dell'allegato.

**Intervento:** replicare un riferimento recuperabile e distinguere messaggio completo da segnaposto; consentire di completare lo stesso ID con i dati autenticati mancanti.

Riferimenti: [rimozione dell'allegato dalla replica](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/native/core/src/messaging_adapter.rs:1720), [deduplicazione anticipata](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/native/core/src/messaging_adapter.rs:1556), [inserimento della replica](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/native/core/src/messaging_adapter.rs:2202). Confermato nel codice; l'ordine di arrivo va verificato anche su rete reale.

### 3. P1 — Il ripristino dell'account non recupera automaticamente un'importazione interrotta

Il vecchio account viene spostato in una directory di rollback, poi `identity` e `messaging` nuovi vengono installati con rinomine separate. Il rollback gestisce gli errori restituiti mentre il processo è vivo. Manca invece una transazione persistente da recuperare all'avvio.

Un arresto fra le rinomine può lasciare l'identità assente o solo parte del nuovo account installata. All'avvio, `ensure_identity` genera una nuova identità se il file non esiste. I vecchi dati possono ancora trovarsi nel rollback, ma l'app non li ripristina automaticamente.

**Intervento:** journal dell'importazione con recupero prima dell'inizializzazione, oppure directory account complete e cambio atomico del riferimento all'account attivo.

Riferimenti: [installazione in più passaggi](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/native/core/src/account_backup.rs:199), [generazione quando l'identità manca](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/native/core/src/identity.rs:313). Confermato nel codice; non simulato spegnendo il processo.

### 4. P1 — Le release Android della CI non hanno una chiave di firma stabile configurata

Gradle usa la chiave debug se manca `key.properties`. Il workflow Android compila e pubblica gli APK senza predisporre una chiave release persistente. Su runner nuovi la chiave debug non è garantita uguale a quella delle release precedenti: un aggiornamento può essere rifiutato da Android per certificato diverso.

**Intervento:** configurare una chiave release persistente nella CI e impedire la pubblicazione quando non è disponibile. Occorre conservare la chiave compatibile con gli APK già distribuiti.

Riferimenti: [fallback alla firma debug](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/android/app/build.gradle.kts:118), [workflow Android e pubblicazione](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/.github/workflows/ci.yml:169). Confermato nella configurazione; non confrontati i certificati di APK distribuiti.

## Altri difetti funzionali e di prestazioni

### 5. P2 — Una risposta tardiva mostra la cronologia di A dentro la chat B

Aprire “Carica messaggi precedenti” in A e passare a B prima del completamento applica comunque la risposta di A alla schermata corrente. Il caricamento della cronologia controlla soltanto `mounted`; il caricamento ordinario controlla invece anche conversazione e generazione.

**Intervento:** applicare la stessa verifica a caricamento e completamento delle pagine precedenti.

Riferimento: [_loadOlderMessages](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/lib/features/messenger/messenger_home.dart:1363). **Riprodotto con widget test.** È un errore di visualizzazione locale; la prova non dimostra un invio dei messaggi a B.

### 6. P2 — Il refresh elimina dalla vista le pagine precedenti già caricate

`loadOlderMessages` aggiunge i messaggi precedenti alla cache. Il refresh successivo richiede soltanto l'ultima pagina nativa e `_parseMessages` sostituisce l'intera lista. Un nuovo messaggio o un aggiornamento delle spunte può quindi far sparire la cronologia appena caricata e spostare la vista.

Inoltre, il caricamento delle pagine precedenti unisce la risposta a una fotografia della cache presa prima dell'attesa: un refresh concorrente può essere sovrascritto.

**Intervento:** mantenere un intervallo caricato per conversazione e unire i record per ID, con una gestione coerente delle richieste concorrenti.

Riferimenti: [unione delle pagine](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/lib/core/messaging/sylphy_messaging_bridge.dart:172), [sostituzione della cache](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/lib/core/messaging/sylphy_messaging_bridge.dart:234). Confermato nel codice.

### 7. P2 — Un invio fallito sovrascrive la nuova bozza

Dopo aver inviato un messaggio, è possibile scriverne un altro mentre il primo è in corso. Se il primo fallisce, il gestore dell'errore rimette incondizionatamente il vecchio testo nel composer, cancellando la nuova bozza.

**Intervento:** ripristinare il testo solo se il composer è ancora vuoto, oppure conservare il messaggio fallito nella chat con un'azione di reinvio.

Riferimento: [ripristino del testo dopo errore](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/lib/features/messenger/messenger_home.dart:1497). **Riprodotto con widget test.**

### 8. P2 — Le repliche ignorano gli aggiornamenti di stato dei messaggi esistenti

Gli eventi `UpsertMessage` e `UpsertGroupMessage` aggiungono un messaggio solo se l'ID non esiste. Non aggiornano il record esistente. Una copia importata come `queued` rimane quindi tale anche quando arriva la replica `sent` dal dispositivo sorgente.

**Intervento:** aggiornare i campi replicabili in modo monotono, conservando lo stato di lettura locale ed evitando regressioni con eventi fuori ordine.

Riferimenti: [repliche delle chat](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/native/core/src/messaging_adapter.rs:2202), [repliche dei gruppi](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/native/core/src/messaging_adapter.rs:2243), [emissione dello stato sent](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/native/core/src/messaging_adapter.rs:1995). Confermato nel codice.

### 9. P2 — Alcune repliche superano sempre il limite del trasporto e vengono ritentate senza backoff

La replica dello stato `sent` include il `StoredMessage` completo, con l'allegato Base64. Un file di 100 KiB produce già oltre 133 KiB di Base64, prima degli altri campi e della cifratura. Il trasporto diretto ammette 32 KiB e la mailbox legacy al massimo 16 KiB di payload. Queste repliche non possono riuscire tramite questo percorso.

La coda viene ripercorsa integralmente, senza scadenza o ritardo progressivo, a ogni sincronizzazione. Prima di accorgersi del limite viene anche risolta l'identità dell'account sulla rete. Questo aggiunge lavoro e richieste inutili; con una coda lunga può rallentare anche la ricezione, perché il flush precede la lettura dell'inbox.

**Intervento:** usare riferimenti cifrati ai blob, limiti coerenti prima dell'accodamento, tentativi a lotti con backoff e un esecutore di replica che non preceda la ricezione in modo bloccante.

Riferimenti: [evento con messaggio completo](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/native/core/src/messaging_adapter.rs:2012), [serializzazione e invio](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/native/core/src/messaging_adapter.rs:1762), [ripetizione dell'intera coda](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/native/core/src/messaging_adapter.rs:1840), [limite mailbox](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/native/core/src/veilid_adapter.rs:420), [limite diretto](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/native/core/src/veilid_adapter.rs:704). Confermato nel codice; impatto energetico non misurato.

### 10. P2 — Il timeout del worker perde l'esito di operazioni che possono ancora riuscire

Dopo 30 secondi, o due minuti per import/export, Dart chiude la porta di risposta e restituisce un errore. Il comando nativo continua. La coda Dart si dichiara libera anche se il worker è ancora occupato.

Un invio lento può quindi essere salvato dopo che l'interfaccia lo ha presentato come fallito; un reinvio genera un nuovo ID. Un'importazione tardiva può completarsi senza attivare il normale aggiornamento delle cache dell'account.

**Intervento:** mantenere un identificatore dell'operazione e uno stato “in corso”, conservare o interrogare l'esito finale e rendere idempotenti le mutazioni. Terminare forzatamente un comando durante la scrittura del vault non è una soluzione sufficiente.

Riferimenti: [timeout e chiusura della risposta](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/lib/core/native/native_core.dart:526), [rilascio della coda](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/lib/core/native/native_core.dart:513), [comando sincrono nel worker](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/lib/core/native/native_core.dart:663). Confermato nel codice; non provocato con una rete lenta.

### 11. P2 — I membri dei gruppi mantengono chiavi e percorsi di rete vecchi

L'invio di testi e allegati usa direttamente `member.identity` conservata nel gruppo. Il refresh periodico aggiorna la rubrica, ma non aggiorna i membri dei gruppi; anche i messaggi ricevuti nel gruppo non aggiornano questi endpoint.

Dopo un cambio di percorso l'invio diretto può fallire. Dopo la rotazione delle prekey e la rimozione di quelle ritirate, anche il recupero offline con le vecchie chiavi può smettere di funzionare. I dispositivi collegati successivamente non vengono aggiunti a questo insieme di destinazioni dal normale refresh dei contatti.

**Intervento:** risolvere e validare gli endpoint correnti dei membri senza cambiare l'identità dell'account o la membership autorizzata.

Riferimenti: [invio gruppo](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/native/core/src/messaging_adapter.rs:937), [allegati gruppo](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/native/core/src/messaging_adapter.rs:1057), [refresh dei soli contatti](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/native/core/src/messaging_adapter.rs:1499), [ricezione gruppo senza aggiornamento](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/native/core/src/messaging_adapter.rs:1676). Confermato nel codice; rotazione e cambi di rete da provare fra dispositivi.

### 12. P2 — Una private route invalidata viene riutilizzata fino al riavvio del nodo

Il callback Veilid tratta soltanto `AppMessage`. La private route viene memorizzata e restituita senza invalidazione. Ripubblicare l'identità non garantisce quindi la creazione di una route nuova dopo che quella locale è diventata inutilizzabile.

**Intervento:** gestire gli eventi di invalidazione delle route, liberare la cache interessata, creare una nuova route e ripubblicare il bundle.

Riferimenti: [callback degli aggiornamenti](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/native/core/src/veilid_adapter.rs:110), [riuso della route](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/native/core/src/veilid_adapter.rs:184). Assenza della gestione confermata nel codice; scenario di guasto da verificare con Veilid attivo.

### 13. P2 — Il backup conserva i messaggi in attesa, ma non la coda necessaria a inviarli

Il backup della messaggistica contiene contatti, gruppi e messaggi. Non contiene `PendingDelivery`. Importando una copia con messaggi `queued`, questi appaiono ancora in attesa ma il nuovo dispositivo non ha il lavoro di consegna corrispondente.

Se il dispositivo sorgente resta disponibile può completare l'invio; se il backup serve a recuperare un dispositivo perso, il messaggio non riparte automaticamente. Anche nel caso del sorgente disponibile resta il difetto di aggiornamento dello stato descritto al punto 8.

**Intervento:** definire esplicitamente la semantica dei messaggi pendenti per collegamento e ripristino, con recupero o reinvio controllato e senza clonare sessioni Signal attive.

Riferimenti: [campi esportati](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/native/core/src/messaging_adapter.rs:365), [importazione dei record](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/native/core/src/messaging_adapter.rs:377). Confermato nel codice.

### 14. P2 — La migrazione del vecchio storage omette i gruppi

L'elenco dei file copiati da `veilid/messaging` a `native/messaging` include messaggi e contatti, ma non `groups-v1.vault`. Un'installazione che ha gruppi nella vecchia directory può ritrovarsi con i messaggi migrati e le definizioni dei gruppi mancanti.

**Intervento:** migrare anche i gruppi e aggiungere il caso ai test della migrazione, controllando la coerenza dell'account di destinazione.

Riferimento: [elenco dei file migrati](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/lib/core/veilid/veilid_service.dart:226). Confermato nel codice; condizionato alla presenza di quel file nel vecchio percorso.

## Problemi minori e limiti aggiuntivi

- **P3 — Data della cronologia:** il separatore mostra sempre “OGGI”, anche per messaggi di giorni precedenti; non esiste un raggruppamento effettivo per data. [Separatore](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/lib/features/messenger/messenger_home.dart:3153).
- **P2 — Nome e foto aggiornati possono restare vecchi nella UI:** la firma usata per decidere se aggiornare le conversazioni omette nome, avatar, descrizione e altri dati del profilo. Un refresh che cambia soltanto questi dati può essere ignorato fino a un refresh forzato. [Firma delle conversazioni](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/lib/features/messenger/messenger_home.dart:3669).
- **P2 — Archivio non completo per cronologie molto grandi:** l'archivio interrompe la paginazione dopo 100 pagine anche se ne restano altre, senza segnalare l'incompletezza. Con pagine da 120 elementi copre al massimo 12.120 messaggi per chat, mentre il core può contenere fino a 100.000 messaggi complessivi. [Limite delle pagine](C:/Users/Hisako/Desktop/App-di-Messaggistica-Kerberus/Sylphy/Sylphy/lib/features/messenger/encrypted_file_archive_page.dart:81).
- **Da misurare — Consumi residui:** restano timer di polling in Flutter, servizio Android e mailbox Rust. Non basta contarli per quantificare la batteria: servono misure a schermo spento, app in primo piano, rete assente e con più contatti. Il punto 9 è già un lavoro evitabile dimostrabile dal codice.

## Ordine proposto per gli interventi

Prima impedire perdita dei messaggi e copie incomplete degli allegati, rendere recuperabile l'importazione e assicurare continuità della firma delle release. Poi correggere concorrenza della UI, semantica degli aggiornamenti e gestione delle operazioni lente. Infine aggiornamento degli endpoint, migrazioni e ottimizzazione misurata su dispositivi.

Le correzioni precedenti dell'icona di invio e del formato degli inviti ai gruppi non esauriscono questi casi: in particolare le copie `queued` importate o replicate hanno un percorso distinto dal normale invio locale.
