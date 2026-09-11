# Revisione Sylphy — 11 settembre 2026

Revisione originaria della copia di lavoro al commit `3d4a16a`, concentrata su persistenza, ricezione, gruppi, sincronizzazione e importazione dell'account. Le sezioni seguenti conservano la diagnosi precedente alle correzioni; i riferimenti di riga sono storici.

I tre interventi sono ora implementati: recupero degli append falliti anche dopo errori del rollback, rinvio dei messaggi bloccati dalle finestre temporali in ricezione e lettura dei backup con limite prima e durante l'accumulo dei byte. I dettagli sono in [affidabilità](../specs/reliability.md) e [gestione dei gruppi](../specs/group-management.md). Le prove della revisione originaria restano distinte dai test delle correzioni.

## Verifiche dopo le correzioni

- **84 test Flutter superati**, inclusi controllo preventivo della dimensione, file cresciuto, interruzione del flusso, file vuoto e lettura da filesystem.
- **44 test unitari Rust e 5 test di integrazione superati** con `signal-ratchet` su Windows GNU; un benchmark manuale ignorato. Le nuove regressioni coprono scritture parziali, errori del flush, rollback ripetutamente fallito, sostituzione del file dell'account, pacchetti cifrati fuori ordine e retry dopo i limiti temporali. La regressione del log esistente verifica anche recupero di una coda interrotta e successivo append.
- Analisi Dart senza segnalazioni; formattazione Dart e Rust e controllo del diff riusciti.
- `cargo check` con `veilid,signal-ratchet` riuscito.
- La suite con `veilid,signal-ratchet` è stata tentata, ma il linker Windows GNU ha fallito nella compilazione della DLL della dipendenza `veilid-core` con `export ordinal too large: 128029`. Quei test non sono stati eseguiti; il controllo di compilazione non equivale a una prova della rete reale.

I log delle correzioni sono `.dart_tool/fixes-2026-09-11-tests.log`, `.dart_tool/fixes-2026-09-11-analyze.log` e `native/core/target/fixes-2026-09-11-{tests,append,check,full-features}.log`. Le prove restano locali: nessuna verifica su dispositivi fisici o build release distribuita.

## 1. P1 — Un nuovo tentativo dopo una scrittura parziale può corrompere il log

**Riferimento:** [messaging_adapter.rs:3243](../native/core/src/messaging_adapter.rs#L3243), funzione `append_message_event_with_limit`.

Il codice aggiunge separatamente lunghezza e contenuto cifrato di un evento. Se `write_all` fallisce dopo aver scritto una parte del frame, restituisce un errore senza riportare il file alla lunghezza precedente. Con la cronologia già caricata, `ensure_messages_loaded` non rilegge il file e il tentativo successivo può aggiungere un evento completo dopo la coda incompleta. Al riavvio il parser interpreta insieme frammento e nuovo evento, fallendo prima di poter recuperare la cronologia.

**Prova:** su un log sintetico valido sono stati aggiunti due byte di un header interrotto, poi è stato chiamato normalmente `append_message_event`. La scrittura successiva è riuscita, ma `load_message_log` ha restituito un errore. La prova simula lo stato lasciato da un errore I/O; non riproduce un guasto fisico del disco.

**Modifica suggerita:** conservare l'offset precedente all'append e recuperarlo in caso di errore. Se il ripristino non riesce, impedire ulteriori append finché una procedura di recupero non ha validato la coda del file. Trattare esplicitamente anche il fallimento del flush. Aggiungere fault injection dopo ciascuna parte del frame, seguita da retry e riavvio.

## 2. P1 — La modalità lenta può scartare messaggi legittimi arrivati offline

**Riferimenti:** [groups.rs:615](../native/core/src/messaging_adapter/groups.rs#L615), [messaging_adapter.rs:1804](../native/core/src/messaging_adapter.rs#L1804).

Il controllo in ricezione confronta l'ora corrente con `received_at_ms` dei messaggi precedenti. Due messaggi inviati a distanza regolare possono arrivare nella stessa sincronizzazione dopo un periodo offline: il primo viene salvato, il secondo viene respinto con `SlowModeActive`. Questo errore è classificato come definitivo e il pacchetto viene confermato alla mailbox senza essere salvato. Anche il conteggio temporale dell'antispam usa il ritmo di ricezione locale.

**Prova:** con un messaggio sintetico inviato due minuti prima ma ricevuto ora, la policy di 30 secondi respinge un ulteriore messaggio dello stesso membro; la prova verifica anche che `should_discard_inbound` classifichi l'errore come definitivo. Il ramo non considera il timestamp del secondo messaggio. Non è stata eseguita una consegna reale fra dispositivi.

**Modifica suggerita:** separare la limitazione degli invii dal ritmo di elaborazione del backlog. Se serve rallentare la ricezione, differire i pacchetti anziché considerarli definitivamente invalidi. Non affidare l'autorizzazione al solo orologio dichiarato dal mittente. Aggiungere test con consegna in blocco e fuori ordine di messaggi inviati a intervalli consentiti.

## 3. P2 — Il limite dei backup viene applicato dopo l'allocazione completa

**Riferimento:** [account_transfer_service.dart:131](../lib/core/identity/account_transfer_service.dart#L131), funzione `pickBackupDocument`.

`selected.readAsBytes()` carica tutto il file prima del controllo del limite di 130 MiB. Se si seleziona un file molto grande con l'estensione prevista, l'app può esaurire la memoria prima di poter mostrare `limit_exceeded`, soprattutto su mobile.

**Modifica suggerita:** controllare prima `selected.length()` e leggere con un limite effettivo sui byte accumulati, così da gestire anche file che cambiano o provider con dimensioni imprecise. Il difetto è confermato dall'ordine delle operazioni nel codice; non è stato provocato un esaurimento della memoria.

## Verifiche

- Flutter: **80 test superati**.
- Analisi statica Dart: **nessuna segnalazione**.
- Rust, feature `signal-ratchet`, target Windows GNU: **41 test unitari e 5 di integrazione superati**, un benchmark manuale ignorato.
- Prova diagnostica Rust aggiuntiva: superata, conferma i punti 1 e 2 su stato sintetico. Il codice temporaneo è stato rimosso dopo l'esecuzione.
- Un sospetto sulle cancellazioni replicate è stato escluso: il normale completamento della sincronizzazione applica già gli effetti di moderazione prima di restituire il controllo alla UI.

I log locali sono in `.dart_tool/review-2026-09-11-tests.log`, `.dart_tool/review-2026-09-11-analyze.log`, `native/core/target/review-2026-09-11-tests.log` e `native/core/target/review-2026-09-11-probe.log`. Il launcher Flutter inizialmente non partiva nell'ambiente ristretto; i test sono stati eseguiti tramite il runtime e lo snapshot Flutter già installati, con accesso alle cache locali.

Non sono state eseguite prove su rete Veilid reale, dispositivi fisici, build release o un audit delle dipendenze. Prima correggere integrità del log e scarto dei messaggi; poi limitare la lettura dei backup.
