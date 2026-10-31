# Riconnessione, ricezione in background e misure fisiche

## Confronto prima/dopo — ABI 21, 30 ottobre 2026

Le nuove build includono upload asincroni durabili, deposito offline anticipato,
watch DHT e misure locali. I controlli automatici non sostituiscono una prova
fra dispositivi: non è stato attribuito alcun guadagno fisico a queste modifiche.
Usare due account di test isolati e ripetere con stessi telefoni, reti, numero
di campioni e condizioni. I report includono versione/build, mai seriali,
contatti, contenuti, nomi dei file o riferimenti DHT.

Esempio in primo piano, dopo aver aperto e sbloccato le chat reciproche:

```powershell
py -3 tool/measure_message_latency.py --sender SERIAL_A --receiver SERIAL_B `
  --sender-chat-title "Test B" --receiver-chat-title "Test A" `
  --send-test-messages --scenario foreground --samples 20 --label before `
  --output build/latency-before.json
```

Ripetere sulla build successiva con `--label after` e un altro file. Confrontare:

```powershell
py -3 tool/compare_message_latency.py build/latency-before.json build/latency-after.json
```

Il delta è dopo meno prima: un intervallo completamente negativo indica una
riduzione osservata, mentre intervalli sovrapposti non consentono una conclusione
precisa. Considerare anche timeout e quantità di campioni; non confrontare
notifiche a schermo spento con visualizzazione in primo piano. Il confronto
rifiuta report incompleti e condizioni di osservazione differenti.

Gli altri scenari usano gli stessi parametri e un file distinto per ciascuno:

- `--scenario during-upload`: avviare un file sufficientemente grande nella
  chat del mittente. Lo strumento verifica l'indicatore “Invio allegato in corso”
  prima del messaggio di prova. Per confrontare una build precedente priva
  dell'indicatore usare `--confirm-upload-in-progress` su entrambe le build:
  la condizione viene dichiarata dall'operatore, non verificata automaticamente.
  `--pause-between-samples` permette di riavviare un upload fra campioni.
- `--scenario screen-off --allow-device-state-changes --samples 1`: il
  destinatario parte acceso con la chat aperta; lo strumento spegne lo schermo,
  osserva soltanto i metadati delle notifiche messaggi Sylphy attive e tenta di
  riaccenderlo in `finally`. Non sblocca il telefono. Per più campioni aggiungere
  `--pause-between-samples` e risbloccare manualmente la chat tra una prova e
  l'altra. Il report misura cambiamenti delle notifiche, non la comparsa del
  messaggio né un'associazione certa con il singolo probe: usare traffico isolato.
- `--scenario network-change --allow-device-state-changes`: il destinatario
  deve avere Wi-Fi attivo, SIM pronta e dati mobili già abilitati. Lo strumento
  disabilita temporaneamente il Wi-Fi prima dell'invio e tenta sempre di
  ripristinarlo. Non modifica i dati mobili né le impostazioni del vault.

Se ADB viene scollegato il ripristino può fallire: verificare manualmente
schermo e Wi-Fi. Gli invii richiedono sempre `--send-test-messages`; i probe
rimangono nella cronologia. Se la protezione blocca il vault a schermo spento,
il timeout è un risultato atteso: non viene aggirata. Per la prova di ricezione
sbloccata configurare esplicitamente un account di test con la policy voluta.

Impostazioni → Diagnostica → Prestazioni dei messaggi consente di azzerare e
copiare le misure delle singole fasi. I campioni restano in memoria, senza logging
dei contenuti. I tempi di fase non sono un benchmark end-to-end. Per analizzare
il rendering usare una build profile su hardware reale; per confrontare la
consegna mantenere la stessa modalità di build prima e dopo.

## Stato del 16 ottobre 2026

Sono implementati il monitor della rete predefinita Android, il riaggancio di
un nodo Veilid detached, la ripubblicazione della rotta e l'aggiornamento delle
rotte della coda verso lo stesso dispositivo autenticato. Il ciphertext dei
messaggi in attesa non viene ricreato. Un tentativo diretto ha un limite di 12
secondi; rimangono il deposito cifrato offline e la deduplica.

I cambi rete vengono accorpati per 500 ms. Le notifiche duplicate non creano
nuovi tentativi; una nuova transizione annulla i retry precedenti. Se il core è
occupato, il recupero riprova con attese crescenti fino a 16 secondi. I callback
non salvano indirizzi, SSID o identificativi di rete. Il ritorno della rete
anticipa i retry pendenti e il recupero dei contatti. Le modifiche a una rotta
accettano soltanto identità Sylphy, device ID e identità Signal corrispondenti.
La capacità Android INTERNET è soltanto un'indicazione: non viene richiesto
VALIDATED, i cui controlli possono essere bloccati da VPN o reti orientate alla
privacy. La connettività effettiva rimane verificata dal trasporto Veilid.

La ricezione nativa sveglia il servizio Android dopo un envelope o un risultato
di trasporto. Il fallback locale è di 30 secondi, 60 senza rete o a vault
bloccato; un core occupato viene riprovato dopo 750 ms. Il polling delle mailbox
rimane ogni 10 secondi con rete disponibile, ma si sospende quando manca e viene
risvegliato al ritorno della connessione. La perdita di rete interrompe anche il
passaggio alle mailbox successive. Un wake lock limitato a 10 secondi protegge
il lavoro del servizio; nessun wake lock accompagna il thread di attesa eventi.

La ripubblicazione in background usa solo la sessione già sbloccata, rispettando
le scelte esistenti di condivisione del profilo. La modalità di blocco in
background o a schermo spento continua a impedire la decifratura e le conferme
di ricezione locali. Il servizio non sblocca il vault e non riavvia un account
chiuso. Le restrizioni Android Doze e quelle del produttore possono comunque
rinviare la rete; il foreground service non le annulla.

Non sono disponibili telefoni collegati e l'utente ha confermato di non averne
disponibili per questa sessione. **Nessuna latenza fisica, percentuale di
consegna in background o variazione di autonomia è stata misurata.**

Verifiche automatiche: 203 test Flutter superati e analisi senza problemi;
58 test Rust superati (uno ignorato); compilazione Kotlin e test Android
superati; controllo Rust con feature Veilid e Signal per Android ARM64
superato. I test Python comprendono il flusso ADB simulato e i limiti temporali
del report: 12 test, di cui uno saltato. Non è stato prodotto un nuovo APK.

## Misurazione tra due telefoni

Lo strumento `tool/measure_message_latency.py` usa solo la libreria standard
Python e ADB. Richiede due telefoni autorizzati, account di test e le due chat
reciproche già aperte e sbloccate, senza bozze. Le build devono contenere il core
nativo aggiornato ABI 20. Non installa build e non seleziona automaticamente
contatti. L'opzione `--send-test-messages` autorizza esplicitamente gli invii.

```powershell
adb devices -l
python tool/measure_message_latency.py --sender SERIAL_A --receiver SERIAL_B `
  --sender-chat-title "Test B" --receiver-chat-title "Test A" `
  --send-test-messages --samples 10 --output build/latency-wifi.json
```

Lo script verifica le chat indicate, rifiuta campi di testo ambigui e bozze e
invia un identificativo casuale per ogni campione. Osserva la comparsa del
messaggio sulla UI del destinatario con un solo orologio monotono sul computer:
non assume che gli orologi dei telefoni siano sincronizzati. La gerarchia UI
viene letta soltanto in memoria, senza dump su memoria condivisa, screenshot o
contenuti delle conversazioni nel report. Non attiva il logging dell'app.

Il JSON riporta intervalli minimo/massimo, ampiezza dell'incertezza, costo
dell'ultimo campionamento, timeout e p50/p95 dei soli campioni osservati. I timeout
sono conteggiati separatamente e non diventano campioni con latenza zero. Il
tempo delle chiamate ADB e della cattura della gerarchia è compreso nei limiti:
non è un benchmark preciso del solo trasporto. I messaggi di prova restano nella
cronologia dei due account finché l'utente non li elimina.

Ripetere con i telefoni su Wi-Fi distinti e su reti mobili. Per un confronto
prima/dopo usare stessi telefoni, condizioni, build release e numero di campioni.
Non confrontare un limite superiore UI con una misura interna del solo core.

## Prove in background e cambio rete

Il recupero Android considera anche i cambi di validazione sulla stessa rete
mobile: perdere e ritrovare copertura può lasciare invariati il `Network` e la
capability `INTERNET`. La validazione resta un indizio per il recupero, senza
essere un requisito per usare VPN o reti che bloccano i probe Android.
Al cambio rete il core invalida la rotta privata e avvia un recupero asincrono:
richiede il distacco, aspetta lo stato realmente scollegato e solo dopo riaggancia.
Il semplice riaggancio condizionato a `detached` non recupera un nodo che risulta
ancora collegato con socket obsoleti. Durante il recupero la UI mostra connessione
in corso e i nuovi invii rimangono nella coda cifrata. Una nuova transizione o
la chiusura del nodo cancella il tentativo precedente. La ripubblicazione
dell'identità e la coda di invio conservano i meccanismi di retry esistenti.

I test automatici verificano la transizione di validazione sulla stessa rete,
l'attesa del distacco prima del riaggancio e l'interruzione se manca di nuovo la
rete. Rimane necessaria la prova di perdita e ritorno della copertura su Android.

Eseguire con account di test e traffico isolato, annotando versione Android e
impostazioni di batteria; non registrare ID, contatti o contenuti personali.

1. Con blocco in background disattivato esplicitamente, lasciare B nella Home,
   inviare da A e verificare notifica, una sola copia al ritorno e ricevuta.
2. Ripetere con schermo di B spento e poi con risparmio energetico attivo.
3. Ripetere con blocco in background/schermo spento attivo: nessuna apertura
   automatica del vault; il recupero decifrato avviene solo dopo lo sblocco.
4. Passare A da Wi-Fi a rete mobile durante invii in coda e fare il contrario;
   ripetere su B. Verificare riaggancio, nuova rotta, consegna senza ricifrature
   o duplicati e corrispondenza degli stati delle ricevute.
5. Togliere la rete per 60 secondi, inviare e ripristinarla. Gli invii pendenti
   devono riprendere senza riavviare l'app o cambiare account.
6. Simulare Doze su un dispositivo di test: `adb -s SERIAL_B shell dumpsys
   deviceidle force-idle`. Ripristinare sempre con `adb -s SERIAL_B shell dumpsys
   deviceidle unforce`, anche dopo un errore. Una sospensione della rete imposta
   dal sistema va registrata come tale, non come consegna istantanea garantita.
7. Osservare il servizio per almeno 30 minuti, prima inattivo e poi con lo stesso
   carico di messaggi. Confrontare batteria, durata dei wake lock e traffico con
   `dumpsys batterystats com.sylphy`. Le stime del sistema non sostituiscono una
   misura energetica controllata e non giustificano percentuali senza dati.

La UI automatizzata misura solo la chat visibile: non attribuisce una latenza
di visualizzazione a un messaggio mentre lo schermo è spento. Notifica,
persistenza e comparsa dopo riapertura sono verifiche distinte.

## Conferma diretta e blocco del vault

Con entrambi i client aggiornati e già presenti nelle rispettive rubriche:

1. Bloccare B mentre A invia. A deve conservare il ciphertext fino alla conferma
   applicativa o al deposito offline; il solo accodamento su B non basta.
   Riavviare B ancora bloccato, poi sbloccarlo: verificare una sola copia.
2. Ripetere con mailbox piena o rete DHT indisponibile: l'invio deve restare in
   coda su A e riprendere quando almeno un percorso torna disponibile.
3. Interrompere la rete dopo il salvataggio su B e prima della risposta ad A.
   Il retry deve usare lo stesso ID e produrre una sola riga e una sola notifica.

I test automatici coprono conferma legata al ciphertext, risposta mancante o
errata, fallback e recupero locale delle transazioni. Non sostituiscono queste
prove del callback Veilid e del lifecycle Android su telefoni reali.

Fonti Android: [stato della rete](https://developer.android.com/develop/connectivity/network-ops/reading-network-state),
[Doze e App Standby](https://developer.android.com/training/monitoring-device-state/doze-standby).
