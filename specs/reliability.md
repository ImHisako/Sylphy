# Correzioni di affidabilità — settembre 2026

## Correzioni del 27 ottobre 2026

Il commit delle sessioni Signal scrive prima un journal cifrato
`signal-transaction-v1.vault` con sessione e, quando necessario, stato globale
delle prekey. La sua sostituzione atomica conferma la transazione. Se uno dei
file finali non può essere sostituito, il messaggio rimane salvato e il journal
completa la scrittura prima della successiva operazione crittografica, anche
dopo un riavvio. Un errore precedente al journal ripristina lo stato in memoria
e lascia il pacchetto ritentabile. Non cambia il formato delle sessioni esistenti.

Il limite di 100.000 messaggi vale anche per invii, allegati, creazione di gruppi
e avvisi di gestione. Gli invii vengono fermati con `storage_full` prima della
cifratura e ricontrollati prima di modificare outbox e log, così la cronologia
non supera il limite previsto dal parser al riavvio.

Il refresh della schermata verifica nuovamente widget montato, bridge e
generazione dei servizi dopo ogni attesa, prima di notificare o applicare i dati.
La conferma applicativa della consegna diretta è descritta in
[offline-delivery.md](offline-delivery.md).

## Identificatori, invii e letture concorrenti

La deduplica della ricezione usa mittente autenticato e ID originale. Se due
mittenti usano lo stesso ID, il secondo messaggio riceve un ID locale distinto;
log, riavvio e sincronizzazione conservano entrambi. Gli ID già salvati restano
validi. Le ricevute usano l'ID originale; risposte, messaggi fissati e cancellazioni
portano anche un riferimento al mittente nei campi opzionali `qualified_*`.
I campi precedenti rimangono leggibili dai client vecchi, che non distinguono
queste collisioni. Una richiesta remota precedente con un riferimento ambiguo
viene rifiutata invece di selezionare un messaggio arbitrario.

L'invio salva prima `messaging/outgoing-transaction-v1.vault`, cifrato con la
chiave dell'archivio, contenente cronologia locale e consegne già cifrate.
Il recupero completa log e outbox prima di consentire altre scritture o invii.
Dopo il commit del journal, un errore di materializzazione lascia l'operazione
accettata e recuperabile; non annulla il messaggio. Le scritture di recupero
sono idempotenti. Eventuali ciphertext orfani prodotti dalle versioni precedenti
restano nella coda senza essere trasmessi: il loro testo locale non può essere
ricostruito retroattivamente dal ciphertext destinato al contatto.

Ogni mutazione delle conversazioni invalida anche la lettura in corso nel
bridge Dart. Un risultato superato attende i dati correnti e non ripopola cache
o UI con una chat eliminata; la sua conclusione non cancella la richiesta nuova.
Il cambio di account continua a scartare i risultati dell'account precedente.
Le regressioni coprono entrambi gli ordini di completamento, collisioni fra
mittenti reali, riferimenti di gruppo e interruzioni a ogni fase del commit.

## Scritture parziali e lettura dei backup — 11 settembre

Un append del log conserva l'offset iniziale e annulla la scrittura se fallisce
il corpo del frame o il flush. Se anche il troncamento o il suo flush falliscono,
il core conserva l'handle del file e blocca ulteriori append e snapshot finché
il recupero non riesce. L'handle identifica il vecchio file anche se un'importazione
installa un altro account nello stesso percorso. Non vengono aggiunti file
ausiliari o flush alle scritture riuscite. Le operazioni sul log sono serializzate.
Su Windows si usa un handle scrivibile con posizionamento alla fine: un handle
aperto solo per append non permette di troncare il file.

Al riavvio, il parser rimuove e sincronizza un frame finale incompleto prima di
accettare nuove scritture. Restano invariati formato del log, cifratura e ABI.
Questa correzione previene nuove concatenazioni dopo un frame parziale; non
ricostruisce automaticamente log già corrotti da versioni precedenti.

Il selettore dei backup controlla la dimensione dichiarata prima di aprire il
flusso e accumula al massimo 130 MiB. Un chunk che supererebbe il limite viene
rifiutato prima di aggiungerlo al buffer, interrompendo la lettura anche se il
file cresce o il provider dichiara una dimensione inferiore a quella effettiva.
I file vuoti vengono rifiutati; il contenuto viene validato come prima.

Le regressioni coprono errori di scrittura a ogni confine del frame, errori di
flush e rollback ripetuti, sostituzione dell'account, recupero della coda al
riavvio, dimensioni dichiarate e reali discordanti, cancellazione del flusso al
superamento del limite e lettura di un file reale.

## Ricezione e sincronizzazione

La capacità locale esaurita produce `storage_full`, distinto dai limiti del
contenuto ricevuto. Il log viene compattato includendo la mutazione richiesta,
così anche una cancellazione può riuscire a log pieno. Un pacchetto valido non
salvato rimane da ritentare; non viene confermato alla mailbox. La UI segnala
quando occorre liberare spazio. Rimangono i limiti di conservazione della rete.

Le repliche aggiornano gli ID già presenti: completano gli allegati mancanti e
fanno avanzare le spunte senza farle retrocedere se arriva una replica vecchia.
Lo stato di lettura locale resta separato. I segnaposto degli allegati prodotti
dalle vecchie versioni possono essere completati quando arriva il contenuto
originale autenticato; un file già scaduto dalla rete non viene ricostruito.

La capability firmata `device-sync-blob-v2` abilita repliche fino a 3 MiB tramite
blob cifrati. La mailbox trasporta un riferimento cifrato con dimensione e hash;
l'autenticazione del riferimento precede il download e quella del blob precede
la lettura del contenuto. I blob hanno conservazione di sette giorni. I messaggi
piccoli mantengono il formato v1. Per le repliche grandi tutti i dispositivi
destinatari devono annunciare v2: aggiornare tutte le installazioni collegate.

Un worker dedicato invia al massimo due eventi per blocco e ritenta gli errori
con backoff. Possiede una fotografia dell'account, non accede all'account attivo
durante la rete e i risultati di una vecchia generazione non modificano quella
nuova. Finché lavora, il polling non copia né serializza nuovamente il blocco.
La ricezione precede la raccolta/avvio degli invii. Non è una misura del consumo
energetico: autonomia e traffico vanno misurati su dispositivi fisici.

## Ripristino dell'account

Il journal `.account-transaction.json` descrive soltanto fase, suffisso delle
directory e presenza dei dati precedenti. Viene scritto prima delle rinomine;
all'avvio il recupero precede l'apertura o la creazione dell'identità. Un'importazione
non confermata ripristina i dati precedenti, una confermata conserva i nuovi e
completa la pulizia. Il recupero supporta anche interruzioni durante il rollback.
I test simulano gli stati del filesystem fra le rinomine; non simulano un guasto
fisico del disco o un'interruzione di corrente.

I nuovi backup includono la coda degli invii già cifrati e le scadenze dei blob.
Il retry usa gli stessi pacchetti: non copia le catene Signal attive. I backup
precedenti senza coda convertono `queued` in `not_restored`, visibile come invio
da riprendere. Per il testo è disponibile “Riprendi bozza”; gli allegati presenti
si possono scaricare e allegare nuovamente. Non viene effettuato un reinvio
automatico con un nuovo ID. La migrazione del vecchio percorso include
`groups-v1.vault` e conserva i file già presenti nella destinazione.

## Chat e indirizzi di rete

Le risposte della cronologia sono applicate soltanto alla conversazione e alla
generazione che le ha richieste. Le pagine vengono unite per ID con la cache
aggiornata durante l'attesa e restano disponibili dopo un refresh. Il fallimento
di un invio non sovrascrive una nuova bozza. Nome, avatar e altri dati del profilo
partecipano al rilevamento delle modifiche. Le date separano realmente i giorni
e l'archivio segue la paginazione fino alla fine, segnalando i mancati progressi.

Un'operazione nativa lenta resta pendente fino alla risposta effettiva: la soglia
temporale produce una segnalazione diagnostica, non un falso fallimento della
mutazione. Le operazioni successive rimangono serializzate.

I gruppi conservano gli inviti brevi dei membri quando disponibili e aggiornano
gli endpoint dalle identità firmate risolte periodicamente o dai pacchetti
autenticati. Gli eventi Veilid di route locale morta invalidano la cache e
richiedono una nuova pubblicazione del profilo. Per gruppi vecchi privi di un
invito breve e di contatti aggiornati, un endpoint già irraggiungibile può ancora
richiedere un nuovo invito. Il recupero con churn reale richiede prove di rete.

## Firma Android

Le build firmate richiedono `android/key.properties`. Le build CI su push e
avvio manuale preparano il file usando i secret `ANDROID_KEYSTORE_BASE64`,
`ANDROID_STORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`; la
build Android si ferma se ne manca uno. Va configurata la chiave compatibile
con gli APK già distribuiti, non una chiave nuova generata su ogni runner.

Per build di sviluppo è disponibile l'opt-in `SYLPHY_ALLOW_DEBUG_SIGNING=true`;
la CI lo usa solo per le pull request, senza usare i secret. Le build firmate e gli
aggiornamenti su Android non sono stati eseguiti in questa verifica locale.
