# Prestazioni della messaggistica

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
