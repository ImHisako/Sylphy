# Protezione locale e blocco dell’app (ABI 15)

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

## Blocco automatico

Ogni avvio richiede la passphrase. L’utente può scegliere inattività di 30 secondi,
1, 5 o 15 minuti, oppure disabilitare questa condizione, e può abilitare il blocco
quando l’app passa in background, incluso lo spegnimento dello schermo.
I valori predefiniti sono 5 minuti e blocco in background attivo.

Solo input dell’utente rinnova la scadenza: polling, notifiche e traffico di rete
non sono attività. Un watchdog nativo usa un orologio monotono, ricontrolla la
scadenza ogni secondo e attende la transazione nativa corrente prima della pulizia.
Il gate FFI controlla comunque la scadenza a ogni comando sensibile. Il servizio
Android controlla lo stesso gate; `MainActivity.onStop` applica anche la policy
nativa. La ricezione e la decifratura locali riprendono dopo lo sblocco.

## Pulizia della memoria

Ogni blocco, incluso **Pulisci RAM e blocca**, scarica l’identità, azzera con
`zeroize` il segreto di apertura, i buffer correnti delle sessioni libsignal,
messaggi, allegati e indice di ricerca, cancella le cache e invalida le generazioni
dei lavori pendenti. I download vengono annullati. Le operazioni già in rete
possono terminare; i loro risultati non riattivano l’account bloccato.

Flutter distrugge il sottoalbero del Navigator (incluse finestre, ricerca e bozze),
rimuove i riferimenti al profilo e alle conversazioni, azzera i buffer mutabili
degli allegati in cache e svuota la cache immagini. Android usa `FLAG_SECURE`
in modalità protetta per escludere screenshot e anteprime recenti.
I buffer Android di un’esportazione in attesa vengono azzerati e il salvataggio
viene annullato se l’app si blocca prima della scelta della destinazione.

È una pulizia **best effort**, non una garanzia di cancellazione di tutta la RAM:
stringhe immutabili Dart, copie temporanee di serializzazione, lavori di rete in
corso, allocator, GPU, tastiera e sistema operativo possono conservare copie.
`zeroize` protegge le allocazioni possedute dal core, non copie già create altrove.
La protezione non cancella i dati persistenti né i file esportati dall’utente.

## Verifica

I test coprono migrazione, assenza di passphrase/segreto in chiaro nel documento,
password errata, riavvio bloccato, vecchia chiave rifiutata via FFI, conservazione
dei dati cifrati, timeout, cambio policy, errori di configurazione, rimozione della
chiave dal secure storage e distruzione delle route sensibili. La validazione
su dispositivo Android/iOS reale rimane necessaria prima del rilascio.
