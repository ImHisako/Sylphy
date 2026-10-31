# Prestazioni della messaggistica

## Invii indipendenti quando un messaggio fallisce

La selezione della outbox distingue messaggi nuovi e ritentativi già scaduti.
Preferisce fino a tre nuovi invii, poi dà un turno a un ritentativo disponibile;
il conteggio prosegue tra i cicli e avanza soltanto se il worker parte. Se una
delle due code non ha lavoro eseguibile, l'altra usa subito gli slot disponibili.
I ritentativi sono ordinati per scadenza, conservando il backoff persistente.

Restano quattro worker complessivi. Al massimo due consegne dello stesso
messaggio e tre della stessa destinazione possono occupare gli slot, contando
anche quelli già avviati. Un messaggio per molti dispositivi non può quindi
occupare l'intera coda; una destinazione non raggiungibile lascia almeno uno
slot alle altre. Il secondo messaggio della stessa chat può partire mentre il
primo è ancora in corso, senza aspettarne il successo. Se tutti gli slot utili
sono occupati si attende la conclusione o il timeout di un tentativo: non viene
promessa una consegna immediata quando manca la rete.

Ogni messaggio conserva ID, ciphertext e risultato indipendenti. Un errore
lascia soltanto quella consegna nella coda cifrata; un successo successivo può
diventare `sent` e rimanerlo dopo il riavvio. Restano invariati la conferma dopo
persistenza, la deduplica e il divieto di inviare messaggi privi di cronologia
locale. I test coprono fanout, destinatario lento, backlog di ritentativi,
equità tra cicli con un solo slot libero e fallimento/successo seguito da riavvio.
Una prova con cifratura ibrida e Signal reali riceve il secondo pacchetto di
una nuova sessione prima del primo, poi riavvia il destinatario e recupera il
primo pacchetto senza duplicare il secondo.

## Upload, consegna alternativa e mailbox a eventi — ABI 21

Gli allegati in uscita vengono prima salvati nella cronologia cifrata con uno
stato locale `pending_upload`. La risposta al comando conferma l'accodamento
durabile. Al massimo quattro file possono essere abilitati nella coda e due worker possono
caricare contemporaneamente: ricevono soltanto ciphertext e un segnale di
cancellazione, senza chiavi del file, credenziali o accesso al vault.
La rete non occupa il mutex dei comandi né l'isolate che accoda i messaggi.

Il thread dei comandi applica un risultato soltanto se account, generazione,
messaggio e permessi di gruppo sono ancora validi. Cifra il riferimento per i
destinatari e aggiorna messaggio/outbox con il journal esistente, conservando
lo stesso ID. Il worker conserva il blob solo dopo questa conferma locale.
Blocco, cambio account, cancellazione e risultati obsoleti distruggono le chiavi
in memoria e annullano il lavoro; i file pubblicati senza un commit vengono
rimossi per quanto consentito dalla rete. I worker mantengono il loro limite
anche durante la pulizia. Errori transitori riprendono con il backoff esistente;
riavvio e importazione ripristinano i file pendenti dall'archivio cifrato.
`attachment_state` distingue `upload_queued`, `uploading` e `upload_failed`
dai download. Si può sospendere e riprendere un invio; un errore definitivo di
permessi o verifica lo sospende, conservando il file locale. La ripresa ricontrolla
i permessi senza contare il messaggio pendente contro il proprio slow mode.

Ogni slot della outbox può avviare il deposito offline mentre la consegna
diretta è ancora in attesa, usando gli stessi byte già persistenti. La soglia
iniziale è di 2 secondi. Dopo otto consegne dirette riuscite viene stimata dal
95° percentile degli ultimi 128 campioni riusciti, raddoppiato più 250 ms,
con un limite di 750–4000 ms. Un errore diretto avvia subito il deposito;
un successo diretto prima della soglia non lo avvia. Vince la prima conferma
valida: risposta applicativa autenticata dopo persistenza oppure deposito DHT
verificato. Il fallimento di un percorso non annulla quello ancora in corso.
La deduplica resta necessaria perché un'operazione remota può completarsi anche
dopo l'annullamento della sua attesa locale. Non vengono aggiunti thread per
questo confronto; restano quattro slot, con al massimo due percorsi per slot.
Il percorso DHT ha un limite complessivo di 20 secondi. La scelta può aumentare
il traffico DHT quando un percorso diretto è lento.

Fino a 64 mailbox ricevono watch firmati tramite Veilid `ValueChange`. I record
rimangono aperti finché il watch è utile, vengono rinnovati e i watch decaduti
vengono ricreati. Tutti i destinatari, inclusi quelli oltre il limite dei watch,
mantengono un timer di recupero che accoda i controlli ogni 10 secondi; il
completamento dipende dal carico e dalla rete, non è un limite di latenza.
Un massimo di quattro letture
procede contemporaneamente. Gli eventi anticipano i contatti in coda e un
cambiamento durante una lettura ne programma una seconda senza duplicare lo
stesso lavoro in corso. La coda resta equa per gli altri contatti.
Le future sono possedute dal task del nodo: fermarlo rilascia anche le capacità
dei record in corso. Lease locali chiudono gli handle non osservati anche quando
la consegna anticipata o un cambio rete annullano un'operazione.

## Misure locali e confronto tra dispositivi

Impostazioni → Diagnostica → Prestazioni dei messaggi espone campioni limitati
in memoria: attesa degli invii nella coda Flutter, durata dei comandi di invio,
refresh delle conversazioni fino al frame successivo, attesa del core,
preparazione del testo, upload, consegna diretta, deposito offline, lettura DHT
e persistenza in ricezione. Ogni fase riporta mediana e 95° percentile, contatori
e capacità 128; una fase senza campioni espone valori nulli. Il report copiabile
non contiene messaggi, contatti, file, riferimenti DHT o chiavi e non viene
inviato automaticamente. Il comando `performance_snapshot` non attende il mutex
dei comandi, rispetta il gate dell'account e richiede un vault sbloccato.
Reset e cambi account invalidano anche i campioni delle operazioni già in corso,
che non possono ripopolare una nuova finestra di misura dopo il completamento.

Questi tempi di fase non sono sommabili per ricostruire una consegna e non
dimostrano un guadagno tra due telefoni. `tool/measure_message_latency.py`
misura intervalli con un unico orologio sul computer negli scenari foreground,
upload in corso, schermo spento e Wi-Fi → dati mobili. Il report distingue
visualizzazione e cambiamenti delle notifiche, conserva l'incertezza ADB e i
timeout e registra soltanto versione/build dei due client, senza seriali.
`tool/compare_message_latency.py` confronta scenari omogenei e produce intervalli
del delta, senza inventare percentuali di miglioramento. Procedura, consenso
agli invii di test e ripristino delle condizioni sono in
[network-background-validation.md](../docs/network-background-validation.md).

Riconnessione e ricezione in background (ABI 20), strumento di misura e prove
fisiche ancora da eseguire: [procedura](../docs/network-background-validation.md).

## Invio immediato e destinatari lenti — 16 ottobre 2026

`queue_outgoing` avvia i worker di trasporto appena ciphertext e messaggio
locale sono persistenti. Prima dipendeva da un successivo `sync_inbound`: la UI
lo richiedeva dopo la rilettura dei messaggi locali, oppure interveniva il timer
Flutter di tre secondi. L'avvio di rete ora precede questi aggiornamenti della
UI; non si deduce un risparmio fisso di tre secondi per ogni messaggio.
Un risveglio senza contenuti aggiorna poi gli stati nell'interfaccia. Le ricevute
autenticate continuano a distinguere invio al trasporto, consegna e lettura.

Il trasporto mantiene al massimo quattro invii contemporanei. Ogni destinazione
completa separatamente; uno slot libero può prendere un nuovo messaggio anche
mentre un peer precedente è ancora lento o offline. Gli ID in corso impediscono
la partenza di copie concorrenti dello stesso invio. Un risultato rimane in
memoria finché il thread dei comandi non salva la nuova outbox: un errore di
archiviazione non perde la conferma e non lascia il messaggio bloccato in coda.
Il controllo della generazione separa i risultati fra account e dopo il wiper.
Una saturazione di tutti e quattro gli slot richiede ancora il completamento
di un tentativo; non vengono creati thread illimitati.

Gli invii privati e gli allegati usano il record del destinatario già verificato
quando la sua firma è valida e il bundle non è scaduto. Non richiedono più una
lettura DHT sincrona per ogni messaggio. La directory continua ad aggiornare i
contatti in background; il completamento di una lettura sveglia subito il ciclo
di sincronizzazione. Un bundle scaduto deve essere recuperato dalla rete, avere
una firma valida, essere ancora valido nel tempo e mantenere la stessa identità
Ed25519 prima dell'uso. Non vengono accettate chiavi sostitutive o firme errate.
Un endpoint modificato può quindi richiedere l'aggiornamento in background e
un nuovo tentativo; non è garantito che il primo invio usi già la nuova rotta.

Nella coda Flutter gli invii restano prioritari; la ripubblicazione dell'identità
non passa più davanti agli invii interattivi già accodati. Un comando nativo già
iniziato mantiene comunque la sua posizione fino al completamento.

I test verificano avvio senza polling dopo il commit cifrato, prosecuzione con
un peer lento, limite dei worker, assenza di duplicati, ripetizione dei risultati
non ancora salvati, cambio account, errori di avvio dei thread e uso dei bundle
locali con rifiuto di scadenze, firme e identità non valide. Il test di restart
verifica ancora outbox cifrata, retry parziale e cancellazione persistente.
Questi controlli dimostrano la rimozione delle attese applicative; non misurano
la latenza end-to-end su Veilid o su telefoni reali. I parametri crittografici,
la persistenza prima dell'invio e il backoff dei tentativi falliti restano attivi.

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
