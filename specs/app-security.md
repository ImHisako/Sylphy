# Protezione locale e blocco dell’app (ABI 18)

La protezione con passphrase si attiva da **Impostazioni → Sicurezza locale**.
Usa il vault Argon2id/XChaCha20-Poly1305 esistente, senza introdurre SQLite o
primitive nuove. Il riferimento funzionale è la
[protezione dei dati a riposo di Molly](https://github.com/mollyim/mollyim-android/wiki/Data-Encryption-At-Rest).

## Migrazione e persistenza

`configure_security` legge `native/app-security-v1.json` prima che Flutter apra
profilo, preferenze, identità o rete. Un file illeggibile blocca l’accesso.
Il documento versionato contiene esclusivamente policy pubblica e il segreto
casuale preesistente cifrato con la passphrase, tramite Argon2id (64 MiB,
3 passaggi, parallelismo 4) e XChaCha20-Poly1305 con salt e nonce casuali.
La passphrase non viene salvata.

`enable_passphrase` verifica il round trip e sostituisce atomicamente il file.
Solo dopo il commit Flutter elimina il vecchio segreto dal secure storage.
Un’interruzione fra queste operazioni viene completata al riavvio eliminando
la copia residua, senza sblocco automatico. Un errore di pulizia mantiene il
gate chiuso e permette di riprovare. Identità e messaggi non vengono riscritti:
le chiavi casuali esistenti e tutti i dati cifrati rimangono validi.
La protezione non retroagisce su copie del segreto o snapshot del dispositivo
creati prima dell’attivazione.

Una volta attivata la protezione, Dart passa un marcatore vuoto al core al posto
del segreto. `ensure_identity`, import account e cifratura del profilo/preferenze
risolvono la chiave esclusivamente dalla sessione nativa sbloccata. Anche fornire
il vecchio segreto a questi comandi quando il vault è bloccato viene rifiutato.
Non esistono recupero della passphrase o disattivazione automatica della protezione.
I backup account esportati conservano la propria password di trasferimento.

## Rimozione volontaria della passphrase

Toccando la protezione attiva si può disattivarla confermando la passphrase
attuale. I dati restano cifrati: viene ripristinata la chiave casuale originale
nel secure storage del dispositivo, senza riscrivere identità, chat o allegati.
`prepare_disable_passphrase` verifica la passphrase e restituisce la chiave
soltanto per questa transizione esplicita, a vault sbloccato. Flutter la salva
nel campo temporaneo `sylphy_pending_unprotect_secret_v1` e ne verifica la rilettura
prima di invocare `disable_passphrase` con la medesima chiave e passphrase.
Il core ricontrolla entrambe e sostituisce atomicamente il documento con `null`.
Flutter promuove poi la chiave al campo ordinario del secure storage.

Al riavvio un documento ancora protetto mantiene la richiesta di passphrase e
rimuove la copia temporanea. Un documento `null` fa recuperare la chiave temporanea
prima di aprire i dati. Una risposta persa dopo il commit richiede una nuova
lettura del documento dal disco, senza cancellare alla cieca la chiave residua.
La passphrase e questa risposta speciale non sono inserite nei log. Durante la
transizione il plugin secure storage richiede una copia temporanea della chiave
in Dart, soggetta ai limiti di azzeramento delle stringhe immutabili.

## Blocco automatico

Con la protezione attiva ogni avvio richiede la passphrase. L’utente può scegliere inattività di 30 secondi,
1, 5 o 15 minuti, oppure disabilitare questa condizione, e può abilitare il blocco
quando l’app passa in background. Android offre una condizione indipendente per
lo spegnimento dello schermo, anche con il blocco in background disattivato.
I valori predefiniti sono 5 minuti, blocco in background e a schermo spento attivi.
I documenti v1 esistenti ricevono `lock_on_screen_off: true` se il campo manca.

Solo input dell’utente rinnova la scadenza: polling, notifiche e traffico di rete
non sono attività. Un watchdog nativo usa un orologio monotono, ricontrolla la
scadenza ogni secondo e attende la transazione nativa corrente prima della pulizia.
Il gate FFI controlla comunque la scadenza a ogni comando sensibile. Il servizio
Android controlla lo stesso gate. Un executor seriale indipendente da Flutter
applica gli eventi di `onStop`, spegnimento schermo, distruzione dell’Activity e
rimozione del task. Avvio e ripresa attendono gli eventi già accodati prima di
riaprire una sessione. La ricezione e la decifratura locali riprendono dopo lo sblocco.

## Chiusura dell’app

La pulizia alla chiusura è sempre attiva, anche senza passphrase e con tutte le
condizioni di blocco automatico disabilitate. `close_vault` sospende prima la
sessione e poi esegue il wiper. Anche il percorso con chiave nel secure storage
viene rifiutato mentre la sessione è sospesa: il servizio Android non può
ricaricare identità e cache dopo la pulizia. I dati persistenti restano cifrati.

Senza passphrase, un nuovo avvio o ritorno in primo piano chiama `resume_vault`
e ricarica i dati. Con passphrase, `resume_vault` non sblocca nulla: occorre
`unlock_vault`. Le risposte asincrone precedenti alla chiusura vengono invalidate.

Flutter attende la pulizia nelle richieste di uscita e la richiede anche a
`detached`/dispose. Windows e Linux richiamano inoltre l’export C
`sylphy_core_close_vault()` dalla libreria già caricata prima della distruzione
del runner. Il richiamo nativo attende la transazione corrente e le letture di
gruppo in corso, senza dipendere dalla consegna di un messaggio a Flutter.
Arresti forzati, crash, spegnimenti improvvisi e kill del sistema possono evitare
tutti i callback; nessun hook di chiusura ne garantisce l’esecuzione.

## Pulizia della memoria

Ogni blocco, incluso **Pulisci RAM e blocca**, scarica l’identità, azzera con
`zeroize` il segreto di apertura, i buffer correnti delle sessioni libsignal,
messaggi, allegati e indice di ricerca, cancella le cache e invalida le generazioni
dei lavori pendenti. I download vengono annullati. Le operazioni già in rete
possono terminare; i loro risultati non riattivano l’account bloccato.
Sono inclusi nomi dei canali, inviti e token dei gruppi, richieste amministrative
pendenti e copie delle credenziali delle mailbox nei contatti e nei gruppi.
I poller delle mailbox vengono annullati e attesi prima di svuotare le relative
chiavi e code; ripartono dopo lo sblocco. Una pulizia fallita di un sottosistema
non impedisce il tentativo sugli altri sottosistemi principali.

Flutter distrugge il sottoalbero del Navigator (incluse finestre, ricerca e bozze),
rimuove i riferimenti al profilo e alle conversazioni, azzera i buffer mutabili
degli allegati in cache e svuota la cache immagini. Android usa `FLAG_SECURE`
all'avvio, al blocco e in background. In **Privacy del profilo → Consenti
screenshot dell’app** l'utente può autorizzare le catture soltanto a sessione
sbloccata e in primo piano; la preferenza è cifrata e disattivata per default.
La finestra resta protetta finché il sistema non conferma la preferenza.
La notifica di avvio pulizia viene richiesta insieme alla revoca nativa,
senza ritardarla aspettando prima la risposta della piattaforma.
I buffer Android di un’esportazione in attesa vengono azzerati e il salvataggio
viene annullato se l’app si blocca prima della scelta della destinazione.

La cache nativa dell’identità autenticata, introdotta in ABI 17 per le
ripubblicazioni, viene distrutta insieme al record e alla sua credenziale
`Zeroizing`. I nuovi buffer degli allegati su richiesta sono posseduti dal
lettore e azzerati al termine dell’uso; il bridge li raggiunge tramite riferimenti
deboli per azzerarli anche al blocco. Gli eventi nativi contengono soltanto un
contatore e non riaprono il gate né prolungano la scadenza di inattività.

È una pulizia **best effort**, non una garanzia di cancellazione di tutta la RAM:
stringhe immutabili Dart, copie temporanee di serializzazione, lavori di rete in
corso, allocator, GPU, tastiera e sistema operativo possono conservare copie.
`zeroize` protegge le allocazioni possedute dal core, non copie già create altrove.
La protezione non cancella i dati persistenti né i file esportati dall’utente.

### Passaggio aggiuntivo sulle pagine libere Android

Il riferimento è [`WipeMemoryService` di Molly, commit 892d6264](https://github.com/mollyim/mollyim-android/blob/892d6264ba007b5458a8b74cf9183c665f1f17a1/app/src/main/java/org/thoughtcrime/securesms/service/WipeMemoryService.java).
Dopo la revoca e l’azzeramento dei buffer del core, Sylphy avvia
`MemoryWipeService` nel processo separato `:ram_wiper`. Il servizio mantiene
blocchi diretti da massimo 4 MiB, ne sovrascrive esplicitamente i byte e conserva
una riserva pari a due volte la soglia di memoria bassa indicata da Android.
Si ferma per pressione di memoria, errori di allocazione o dopo 20 secondi.
Una wake lock scade comunque dopo 30 secondi. La distruzione del solo processo
wiper rilascia tutte le allocazioni; il processo messenger non viene terminato.
È un adattamento del passaggio sulle pagine libere di Molly, non una garanzia di
cancellazione di heap ancora allocati, copie GPU o di tutta la RAM del dispositivo.

La notifica mostra prima un caricamento durante la pulizia dei buffer, poi un
avanzamento basato sui byte trattati rispetto alla memoria libera iniziale e lo
stato finale con i MiB trattati. Interruzioni e mancato avvio del servizio vengono
indicati senza dichiarare completata la pulizia approfondita. Se Android vieta
l’avvio di un foreground service in background, resta eseguita la pulizia dei
buffer nel processo principale. Il permesso notifiche non condiziona la revoca
né il tentativo di pulizia; senza tale permesso la notifica può non comparire.
Anche la schermata di blocco mostra il caricamento mentre il core lavora.

## Verifica

I test coprono migrazione, assenza di passphrase/segreto in chiaro nel documento,
password errata, riavvio bloccato, vecchia chiave rifiutata via FFI, conservazione
dei dati cifrati, timeout, cambio policy, errori di configurazione, rimozione della
chiave dal secure storage, chiusura senza passphrase, priorità della chiusura su
un blocco pendente, risposte di ripresa tardive, blocco a schermo spento e
distruzione delle route sensibili. Prima del rilascio verificare su Android reale
Back, rimozione dai recenti, spegnimento schermo con background disabilitato e
riapertura rapida durante invio/download. Verificare anche la chiusura dei runner
Windows e Linux con una transazione nativa in corso.
