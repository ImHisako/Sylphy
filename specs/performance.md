# Prestazioni della messaggistica

## Avvio e ripubblicazione dell’identità (ABI 17)

La sessione nativa conserva l’identità già autenticata, il percorso del suo vault
e una credenziale in `Zeroizing`. `ensure_identity` riusa il record soltanto se
percorso e credenziale coincidono (confronto costante per i byte della credenziale).
Una credenziale differente deve ancora superare Argon2id e l’autenticazione del
file. Non vengono ridotti i parametri della KDF. Una ripubblicazione della stessa
identità non riconfigura la ratchet, evitando di scaricare e rileggere sessioni
già aperte. Rotazione, scadenze e persistenza delle modifiche restano attive.

Il wiper distrugge anche questa cache e la sua credenziale: la prima apertura
dopo blocco/chiusura richiede nuovamente il vault su disco. Il test con un file
temporaneamente illeggibile verifica il riuso durante la sessione, il rifiuto di
una credenziale errata e il ritorno all’autenticazione su disco dopo il wiper.

## Letture locali durante la sincronizzazione

`read_conversations`, `read_messages`, `read_search` e `read_attachment` usano
l’isolate delle letture locali e non entrano nella coda dei comandi di rete.
Il core prende il gate condiviso dell’account e controlla il blocco prima di
leggere. I cambi account e il wiper mantengono il gate esclusivo. I dati freddi
restituiscono `feature_unavailable`: il client riprova una volta nella coda
seriale con `allow_load: true`, che può caricare il log cifrato e applicare i
risultati dei download. Le letture calde non avviano né persistono trasferimenti.

La ricerca mantiene l’indice volatile esistente. Il test FFI tiene occupato il
mutex dei comandi e verifica che le letture locali terminino comunque, e che
vengano rifiutate quando è in corso un cambio account.

## Allegati caricati su richiesta

Le nuove pagine e i risultati di ricerca includono nome, dimensione e stato
dell’allegato, senza il suo Base64. `read_attachment` recupera un solo allegato
già presente nell’archivio, vincolandolo a conversazione, messaggio e stato del
gruppo. Non avvia download di rete. I comandi storici rimangono disponibili per
compatibilità del core; il client ABI 17 usa i nuovi percorsi.

Solo le anteprime montate nell’elenco, la finestra immagine aperta o l’azione
Salva richiedono i byte. L’archivio dei file può paginare i metadati senza caricare
tutti i contenuti. Ogni lettore possiede un buffer mutabile che azzera alla fine
dell’uso. Il bridge conserva riferimenti deboli per azzerare anche i buffer ancora
visibili al blocco, senza trattenerli in una cache forte. Le risposte di una
generazione chiusa vengono rifiutate.
La distruzione della radice dell’app azzera i buffer anche senza una precedente
notifica di blocco. Il salvataggio desktop ricontrolla la validità della sessione
dopo il selettore file, annullando la scrittura se nel frattempo l’app si blocca
o la schermata viene chiusa.

Il test con un allegato da 2 MiB verifica che la pagina serializzata resti sotto
2 KiB e che il contenuto completo sia recuperabile soltanto tramite la lettura
separata. È un controllo sulla quantità di dati, non una misura dei tempi su telefono.

## Aggiornamenti guidati dagli eventi

Il core incrementa un contatore senza contenuti quando accoda un envelope o
completa un download, un invio o una replica. `wait_for_activity` attende una
variazione con `Condvar`, fino a 30 secondi, senza occupare i gate dei comandi o
dell’account. Un contatore evita di perdere eventi arrivati fra due attese.

Un isolate dedicato inoltra i risvegli a Flutter. L’interfaccia accorpa quelli
ravvicinati in 40 ms e richiede una sincronizzazione immediata; un evento durante
una sincronizzazione ne programma una successiva. Android usa un thread di
attesa distinto dal worker che persiste i messaggi. I timer precedenti restano
come recupero, e il polling DHT delle mailbox continua a essere necessario.
Il watcher viene fermato alla distruzione dell’app/servizio e non può sbloccare
un account. Il test widget verifica l’arrivo in chat prima del timer di tre secondi.

## Selezione delle pagine

Il core seleziona riferimenti ai messaggi della conversazione e applica una
selezione parziale prima di ordinare la sola pagina richiesta. Il percorso
precedente clonava tutti i record corrispondenti, inclusi i contenuti base64
degli allegati, e li ordinava prima di troncare la lista a 120 elementi.

La selezione costa O(n), seguita dall'ordinamento O(k log k) della pagina.
La memoria temporanea per la selezione contiene riferimenti, senza copie
dei contenuti fuori pagina. La serializzazione JSON riguarda solo i record
restituiti. Restano invariati limiti, ordine per timestamp e ID, cursore e
indicatore `has_more`. I test attraversano pagine di dimensioni diverse con
timestamp uguali, record disordinati e conversazioni mescolate, verificando
che nessun messaggio venga perso o duplicato.

Per riprodurre il confronto sintetico:

```powershell
cargo test --locked --manifest-path native/core/Cargo.toml --features signal-ratchet benchmark_message_page_selection -- --ignored --nocapture --test-threads=1
```

Rilevazione locale del 9 settembre 2026, Windows x64, profilo debug:

- 25.000 messaggi sintetici, di cui 20.000 nella conversazione selezionata;
- testo di 256 byte e un allegato base64 di 8 KiB ogni otto record;
- dieci selezioni della pagina più recente da 120 messaggi;
- precedente: 299,94 ms complessivi; ottimizzato: 33,68 ms complessivi.

Il confronto misura la selezione in memoria, escludendo lettura del vault,
JSON, rete e rendering Flutter. Non è una misura end-to-end né una soglia
automatica di successo: i tempi dipendono dalla macchina e dal profilo build.

## Sincronizzazione e consumo

La chat mobile usa le notifiche del refresh principale al posto di un secondo
timer di rete. Il test widget verifica una sola richiesta per intervallo di
tre secondi con chat aperta e controlla l'arrivo del messaggio. Un altro test
controlla l'aggiornamento delle spunte desktop senza cambiare l'anteprima.
La frequenza del refresh principale rimane invariata.

Nella configurazione delle mailbox, le chiavi locali di ricezione vengono
recuperate una volta per ciclo. I bundle remoti ripetuti tra rubrica e gruppi
vengono deduplicati prima della derivazione delle mailbox, distinguendo
identità, dispositivo e prekey. I controlli delle identità firmate e le chiavi
precedenti necessarie alla consegna offline restano attivi.

Queste modifiche riducono operazioni duplicate, copie e calcoli crittografici.
Il risparmio energetico e i byte trasferiti devono essere misurati su
dispositivi reali: non vengono dedotte percentuali di autonomia dai benchmark.
