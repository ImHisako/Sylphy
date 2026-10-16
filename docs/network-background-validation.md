# Riconnessione, ricezione in background e misure fisiche

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

Fonti Android: [stato della rete](https://developer.android.com/develop/connectivity/network-ops/reading-network-state),
[Doze e App Standby](https://developer.android.com/training/monitoring-device-state/doze-standby).
