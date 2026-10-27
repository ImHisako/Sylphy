# Core nativo e integrazione Veilid

## ABI

Il recupero transazionale del profilo durante l’importazione è documentato in
[settings-and-account-transfer.md](settings-and-account-transfer.md). Non cambia
il formato del backup né il numero ABI.

Il confine Flutter/Rust è una singola ABI C JSON, attualmente alla versione 20. Le richieste sono UTF-8; le risposte di stato non riportano password, chiavi, plaintext o diagnostica crittografica. I comandi messaging possono restituire soltanto read model già autenticati e decrittati dal core. Ogni stringa restituita viene liberata esclusivamente tramite `sylphy_core_free_string`.

ABI 20 aggiunge il segnale JNI Android di cambio rete, gli esiti busy/locked
separati per il servizio di ricezione e il recupero della rotta dalla sessione
nativa già sbloccata. Non introduce sblocco automatico né esporta credenziali.
Le richieste JSON di messaggistica restano compatibili. La procedura di verifica
e i limiti delle misure fisiche sono in
[network-background-validation.md](../docs/network-background-validation.md).

ABI 19 estende `ensure_identity` con `rotation_interval_seconds` (0 oppure
3600–31536000) e `rotate_invitation`; la risposta aggiunge
`invitation_changed_at_ms`, `next_rotation_at_ms` e `revocation_pending`.
Le chiavi dell'account restano stabili. I nuovi record di invito firmati versione
1 puntano al record di discovery persistente: i contatti e i membri dei gruppi
memorizzano il puntatore stabile dopo aver verificato firma, scadenza e identità.
La risoluzione ammette un solo livello di indirezione. Un vecchio client continua
a comunicare con i contatti già importati, ma deve essere aggiornato per importare
il nuovo formato di ID. Dettagli e limiti in
[settings-and-account-transfer.md](settings-and-account-transfer.md#rotazione-dellid-sylphy).

ABI 18 aggiunge `prepare_disable_passphrase` e `disable_passphrase`, accessibili
solo a vault sbloccato e con verifica della passphrase attuale. La prima risposta
restituisce eccezionalmente il segreto di apertura per il solo salvataggio
verificato nel secure storage; non viene registrata nei log. Il bridge Android
restituisce inoltre esiti distinti per pulizia eseguita, non richiesta o fallita.

ABI 17 aggiunge `read_conversations`, `read_messages`, `read_search`,
`read_attachment` e `wait_for_activity`. Le letture locali calde possono
affiancare un comando di rete; `allow_load: true` sulle prime tre richiede invece
la coda seriale. Le nuove pagine e la ricerca omettono il contenuto degli allegati.
`read_attachment` restituisce `bytes_base64` per una coppia conversazione/messaggio
valida e già caricata. `wait_for_activity` riceve `after` e `timeout_ms` (0–30000)
e restituisce solo `sequence`; non espone dati dell’account e non prende i suoi
gate. Vedere [performance.md](performance.md) per lifecycle e buffer.

ABI 16 aggiunge `close_vault`, `resume_vault`, l’export C sincrono
`bool sylphy_core_close_vault(void)` per i runner e `lock_on_screen_off` nella
policy. La chiusura sospende anche gli account senza passphrase; solo una ripresa
esplicita in primo piano riabilita quel percorso. ABI 15 aveva introdotto
configurazione sicurezza, passphrase, blocco/sblocco e policy di inattività.
Il contratto e la migrazione sono descritti in [app-security.md](app-security.md).

`ensure_identity` crea o riapre un record Argon2id/XChaCha20-Poly1305 contenente la chiave Ed25519 stabile, la prekey privata X25519 e il seed ML-KEM-768. Le prekey pubbliche sono firmate e ruotate alla scadenza, mentre il fingerprint Ed25519 rimane stabile. Il boundary restituisce esclusivamente fingerprint, scadenza e invito pubblico `sylphy:`. Nella modalità standard il segreto del vault proviene dal secure storage; con la protezione opzionale viene custodito soltanto nella sessione nativa sbloccata con passphrase.

## Verifica del bundle Android

`native/build-android.ps1` registra ABI 20 e hash SHA-256 in `sylphy-core.properties`.

ABI 14 aggiunge `request_attachment` (`conversation_id`, `message_id`, `cancel`)
per avviare o annullare un download esplicito senza attendere la rete. I read
model espongono `attachment_state` (`pending`, `queued`, `downloading`, `failed`,
`ready`, `unavailable`) e `attachment_size`, mai chiavi o riferimenti DHT.
Il riferimento completo resta nel log cifrato e nei backup cifrati. Un worker
separato recupera i chunk; solo il thread dei comandi applica un risultato
autenticato dopo aver ricontrollato account, messaggio e riferimento.
Prima del packaging, `verifySylphyNativeCore` verifica ABI, sorgenti e librerie per
le tre architetture Android. Entrambi i passaggi calcolano l'impronta su `Cargo.toml`,
`Cargo.lock` e i file `src/**/*.rs`, ordinati con confronto ordinale case-sensitive
dei percorsi relativi con separatore `/`. L'impronta è lo SHA-256 UTF-8 della
concatenazione degli hash dei file, espressi in esadecimale minuscolo senza separatori.
L'ordinamento non dipende dalla lingua del sistema. Dopo modifiche ai sorgenti o
al formato dei metadati, le librerie vanno ricompilate prima di generare l'APK.

## Veilid

`veilid-core` è una dipendenza opzionale del core. Con la feature `veilid`, `VeilidNode` avvia `VeilidAPI` con un callback che accetta `AppCall` e i precedenti `AppMessage` opachi entro 32 KiB e li conserva in una coda nativa limitata a 256 elementi. Gli invii diretti aggiornati richiedono una risposta `AppCall` dopo la persistenza, come descritto in [offline-delivery.md](offline-delivery.md). Gestisce inoltre attach, routing context, private route, import del route blob e shutdown. Il lifecycle dell'app usa il `program_name` stabile `sylphy`, parte da `VeilidConfig::default` e sostituisce soltanto le directory persistenti di protected, table e block store; i percorsi TLS rimangono quelli di default. Su Android usa NDK 28.2, Java 17 e AndroidX Security 1.1.0; `MainActivity` registra `Context`/JVM prima di `super.onCreate` e adatta i nomi JNI interni al formato binario richiesto da `ClassLoader`, così il protected store può caricare le classi AndroidX. Il core rifiuta lo startup con `platform_not_initialized` se questo contratto non è soddisfatto e classifica separatamente gli errori degli store senza esporne il testo interno.

I comandi ABI `start_veilid`, `veilid_status` e `stop_veilid` sono sincroni rispetto al boundary C ma usano un runtime Tokio dedicato. Lo stato restituito a Flutter è ridotto a attachment, readiness pubblica, numero aggregato di peer e quantità di envelope in attesa. NodeId, route blob, payload e dettagli della routing table non attraversano il boundary. `list_conversations` e `list_messages` partono vuoti e non generano dati campione.

`add_contact` usa il codice breve Veilid per recuperare una `PublishedIdentity` firmata. Il nome mostrato è sempre il display name autenticato contenuto nel profilo remoto (oppure un identificatore Sylphy deterministico se il proprietario ha scelto di non pubblicarlo): il client che importa non può più assegnare un alias arbitrario. Il core impone limiti di dimensione, versione e cardinalità, verifica firme, capability e scadenza e rifiuta record duplicati.

Le identità serializzate entro 32 KiB mantengono la pubblicazione inline. Quelle
più grandi, fino a 512 KiB, usano un blob con chunk da 24 KiB e un riferimento
`sylphy-identity-blob-v1` nel record di discovery stabile. Il riferimento contiene
versione, dimensione, numero di chunk, chiave del blob e SHA-256; tutti i limiti
sono controllati prima del download. I byte ricostruiti devono corrispondere
all'hash e superare la normale verifica della firma originale. Gli inviti possono
quindi risolvere anche profili con quattro dispositivi e avatar. Il formato della
firma e il codice di discovery restano invariati. I client precedenti leggono
ancora le identità inline; per quelle grandi devono essere aggiornati.
Il descrittore privato conserva il riferimento per riusare un blob invariato;
il vecchio record locale viene ritirato solo dopo la pubblicazione del nuovo.

`create_group` aggiunge una directory `groups-v1.vault` cifrata nel vault locale. La modalità `group` rappresenta una chat classica; `channel` rappresenta un gruppo aziendale: in entrambe le modalità tutti possono scrivere per impostazione predefinita; i permessi sono configurabili. Ogni invito contiene il gruppo, gli endpoint pubblici firmati dei membri e l'identità dell'amministratore. Gli inviti v2 usano un blob cifrato con un puntatore trasportato via E2EE individuale, evitando il limite dei normali messaggi; formato e compatibilità sono descritti in [group-invitations.md](group-invitations.md). I messaggi di gruppo vengono cifrati separatamente per ogni membro e validati contro la membership prima della persistenza; gli inviti fuori ordine non vengono scartati.

Il layer di trasporto riceve esclusivamente pacchetti già autenticati e cifrati. I bundle pubblici firmati non includono una chiave di scrittura mailbox condivisa. La capability `offline-mailbox-v1` abilita mailbox per coppia di contatti, direzione e dispositivo, oltre alla route diretta. Il journal di sincronizzazione account conserva la propria capability privata. Il protocollo, i limiti e le conferme sono descritti in [offline-delivery.md](offline-delivery.md).

## Ratchet

La feature `signal-ratchet` integra `signalapp/libsignal` v0.106.0 tramite commit immutabile `fc90b90fa2b9c37822fa47ba0e0dcdf387a0c071` (SPQR v1.6.0). Il percorso di produzione invoca direttamente `process_prekey_bundle`, `message_encrypt` e `message_decrypt`; il bundle pubblico contiene identity key, signed prekey EC e Kyber prekey Signal, tutte legate al fingerprint Sylphy dalla firma Ed25519. Root key, chain key, contatori e skipped-message keys non attraversano mai FFI.

Gli aggiornamenti dalla v0.102.1, dalla v0.105.0 e dalla v0.105.1 mantengono il formato v2 dello stato Signal e la capability `signal-libsignal-v1`. Il test `native/core/tests/libsignal_compat.rs` usa record e ciphertext sintetici generati separatamente con le tre versioni originali: verifica la lettura di identità e prekey, bootstrap pendenti, sessioni persistenti con skipped-message keys, rifiuto dei replay e scambio bidirezionale dopo il caricamento. Non occorre azzerare identità o conversazioni. La verifica su dispositivi reali resta distinta dai test automatici e dalla compilazione Android.

La gestione Tahini della v0.106.0 non riattiva le sessioni archiviate e conserva
al massimo tre sessioni nell'archivio di ogni record. Il core verifica la presenza
di una catena di invio utilizzabile con i requisiti ufficiali `NotStale`,
`EstablishedWithPqxdh` e `Spqr`: se manca, crea una nuova sessione dal bundle
autenticato disponibile, preservando le sessioni archiviate per la ricezione.
Gli aggiornamenti delle identità apprese durante cifratura o decifratura sono
persistiti nella stessa transazione del record di sessione. Il wrapper v2 del
vault e il formato dei pacchetti Sylphy restano invariati; i nuovi campi Tahini
sono gestiti dalla serializzazione ufficiale libsignal.

Il ciphertext opaco Signal/PreKey viene inserito in un envelope Sylphy ibrido e autenticato. Il self-test ABI usa lo stesso provider ufficiale e verifica un round trip PreKey completo.

La transazione fra sessione e prekey globale usa un journal cifrato recuperabile,
descritto in [reliability.md](reliability.md). Un commit già nel journal non viene
annullato se il filesystem rifiuta la sostituzione di uno dei file finali.

L'account Signal globale e ogni sessione per contatto sono file cifrati distinti e sostituiti atomicamente. Il backup account non esporta questi file: ogni dispositivo collegato crea un device ID e uno stato Signal indipendenti, mentre il record pubblico firmato elenca fino a quattro endpoint dell'account. Gli invii registrano cronologia e outbox tramite il journal cifrato recuperabile `outgoing-transaction-v1.vault`; soltanto dopo la materializzazione di entrambi vengono ritentati con lo stesso ciphertext e message ID. La cronologia usa `messages-v2.log`: ogni mutazione è un frame autenticato append-only, con compattazione occasionale e migrazione automatica da `messages-v1.vault`. Il segreto casuale di cifratura è conservato nell'identity vault Argon2id, evitando di rieseguire Argon2 per ogni messaggio. Le capability firmate negoziano `signal-libsignal-v1`; i bundle precedenti privi della prekey Signal vengono rifiutati senza fallback crittografico.
