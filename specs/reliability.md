# Correzioni di affidabilità — settembre 2026

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

Le release di produzione richiedono `android/key.properties`. I tag `v*` della
CI preparano il file usando i secret `ANDROID_KEYSTORE_BASE64`,
`ANDROID_STORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`; la
pubblicazione si ferma se ne manca uno. Va configurata la chiave compatibile
con gli APK già distribuiti, non una chiave nuova generata su ogni runner.

Per build di sviluppo è disponibile l'opt-in `SYLPHY_ALLOW_DEBUG_SIGNING=true`;
la CI lo usa solo per build senza tag di release. Le build firmate e gli
aggiornamenti su Android non sono stati eseguiti in questa verifica locale.
