# Consegna offline v1

## Contratto utente

Il destinatario può essere offline al momento dell'invio. Dopo il deposito
confermato nella DHT anche il mittente può disconnettersi. Il recupero richiede
client aggiornati, un contatto già conosciuto dal destinatario, accesso alla
rete Veilid e record ancora disponibili entro la conservazione di sette giorni.
Il primo contatto sconosciuto non è individuabile autonomamente nella DHT:
serve importare l'ID del mittente oppure ricevere un primo messaggio diretto.

La coda locale conserva lo stesso message ID e ciphertext tra tentativi e
riavvii. Le operazioni di rete avvengono in un worker nativo; la sincronizzazione
applica i risultati solo se appartengono ancora alla stessa generazione dello
storage account. Un invio parziale a più dispositivi resta `queued` finché
tutte le consegne sono completate. Il backoff cresce da 5 secondi a 5 minuti.

`sent` significa affidato al trasporto, non ricevuto o letto. Le conferme DHT
liberano capacità ma non costituiscono ricevute di lettura. Cancellare una
conversazione elimina i suoi tentativi ancora nella coda locale; non ritira
pacchetti già inviati o depositati.

## Capability per coppia

`offline-mailbox-v1` è negoziata nel bundle contenuto nella `PublishedIdentity`
firmata. Per una direzione A/device → B/device, entrambi i peer calcolano un
segreto X25519 dalle prekey autenticate. Si rifiutano i risultati non
contributivi. HKDF-SHA-256 usa come salt l'hash di dominio
`sylphy/offline-mailbox/v1`, identità Ed25519 del mittente e destinatario e i
due device ID, in ordine. Le etichette `dht-owner` e `packet-wrapper` derivano
chiavi distinte per firma del record DHT e wrapping del pacchetto.

La chiave Ed25519 del proprietario DHT nasce dal seed derivato. Lo schema DFLT
ha 96 subkey: 32 slot, ciascuno con primo segmento, continuazione e conferma.
L'indirizzo opaco viene calcolato con `get_dht_record_key`. Nessuna capability
di scrittura viene pubblicata nel profilo o passata a Flutter. Solo i due peer
possono derivarla: un contatto ostile può alterare il proprio canale, non
quelli degli altri contatti. Le firme Sylphy interne restano necessarie, perché
la capability DHT da sola non autentica il mittente del messaggio.

Veilid 0.5.7 aggiunge un segreto di cifratura casuale a `create_dht_record`, anche
quando l'owner è deterministico. Il writer riapre quindi il record usando la
chiave opaca deterministica prima di scrivere, esattamente come il lettore.
Il wrapping applicativo protegge il pacchetto completo. Il protocollo usa le
[API DHT ufficiali](https://docs.rs/veilid-core/0.5.7/veilid_core/struct.VeilidAPI.html)
e le [operazioni del routing context](https://docs.rs/veilid-core/0.5.7/veilid_core/struct.RoutingContext.html).

## Payload e conferme

Il `SecurePacket` Signal + X25519/ML-KEM-768 rimane invariato e viene cifrato
nuovamente con il formato XChaCha20-Poly1305 già usato dal vault a chiave casuale.
Questo wrapping nasconde identità e profilo contenuti nel pacchetto; non
sostituisce o riduce la protezione ibrida del contenuto. La protezione aggiuntiva
dei metadati e della capability è classica, non post-quantum. Dimensioni, tempi
di scrittura e attività del record possono ancora essere osservabili.

Il primo segmento contiene `SOM1`, timestamp di deposito u64 big-endian,
lunghezza cifrata u32 big-endian, SHA-256 dell'intero ciphertext e fino a 24 KiB
di ciphertext. La continuazione contiene il resto: anche i pacchetti massimi
da 32 KiB rientrano nei limiti Veilid senza serializzare byte come array JSON.
Si scrive prima la continuazione, poi il primo segmento. Lunghezze, versione,
clock skew, scadenza, hash e AEAD sono verificati prima di accettare il frame.

Il lettore mantiene il frame in volo fino alla validazione del pacchetto,
salvataggio locale e commit della ratchet. Scrive quindi `SOA1 || SHA256(primo
segmento)` nella subkey di conferma. La conferma è separata dai dati: una
conferma ritardata non può cancellare un nuovo messaggio che riutilizza lo slot.
Il mittente riutilizza uno slot solo se scaduto o confermato per quel preciso
frame. Una mailbox piena lascia il messaggio nella coda locale.

Le letture duplicate non creano nuove righe né nuove notifiche. Gli errori
temporanei rilasciano il marcatore in volo, così il polling può ritentare. Gli
inviti e messaggi di gruppo fuori ordine vengono conservati fino alla presenza
della membership. I messaggi invalidi sono scartati senza far avanzare la
ratchet; gli errori di decifratura ripristinano lo stato precedente.

Le operazioni sullo stesso record sono serializzate localmente e ogni record
aperto viene chiuso anche in caso di timeout della scansione. Il polling ha
una coda limitata e fa ruotare lo slot iniziale per evitare che una rete lenta
impedisca sistematicamente di leggere gli ultimi slot. La DHT resta a
consistenza eventuale: non viene promessa una latenza massima né disponibilità
permanente dei record.

## Rotazione e compatibilità

Le prekey private precedenti restano nel vault cifrato fino a sette giorni
dopo la loro scadenza, per aprire i pacchetti già depositati. La rubrica conserva
un numero limitato di bundle precedenti e aggiorna gli ID brevi in background,
così un utente che riceve soltanto può scoprire nuove prekey del mittente.
Il ritorno dell'app in primo piano forza la ripubblicazione del proprio endpoint.

L'ABI C resta v10. Gli outbox precedenti senza capability vengono caricati e
ritentati sul percorso diretto; non possono essere ricifrati retroattivamente
senza alterare la sessione. Per questi invii preesistenti è ancora necessario
che il mittente torni online con il destinatario raggiungibile. Il journal
multi-dispositivo mantiene il proprio schema distinto.

## Verifiche

I test automatici coprono accordo e isolamento delle chiavi, rifiuto di chiavi
non contributive, dimensioni massime, scadenza, corruzione, scritture parziali,
conferme obsolete, cifratura ibrida reale con libsignal, riavvio del destinatario,
deduplica persistente, invio parziale, backoff, migrazione della coda e annullamento.
La CI Linux esegue i test con entrambe le feature `veilid,signal-ratchet`.

Verifica su dispositivi reali prima di una release:

1. Installare build aggiornate su due dispositivi e importare reciprocamente gli ID.
2. Chiudere B; inviare da A testo e un allegato, attendendo la spunta singola.
3. Chiudere A; riaprire B, collegarsi a Veilid e verificare contenuto e assenza di duplicati.
4. Riavviare B e verificare che la cronologia non raddoppi.
5. Interrompere la rete di A prima del deposito, riavviare A e verificare il retry.
6. Superare 32 messaggi con B offline: gli eccedenti devono restare in coda;
   riaprire B e verificare che le conferme consentano di proseguire.

Non è stata eseguita in questa revisione una prova end-to-end su due dispositivi
reali attraverso la DHT pubblica. Gli allegati mantengono il limite di 700 KiB
e la loro conservazione di sette giorni; la disponibilità del relativo blob
resta necessaria per completare la ricezione.
