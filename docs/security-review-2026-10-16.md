# Controllo di sicurezza — 16 ottobre 2026

## Esito

La scansione iniziale ha trovato advisory su quattro dipendenze Rust: `rustls`,
`time`, `hickory-proto` e `hickory-resolver`. Sono stati aggiornati nel lockfile
`rustls` da 0.23.43 a 0.23.46 e `time` da 0.3.45 a 0.3.47, insieme alle dipendenze
necessarie. Una seconda scansione non segnala più advisory per questi due pacchetti.
Le correzioni avranno effetto nei binari ricompilati dal nuovo lockfile.

Restano due advisory di possibile esaurimento delle risorse in Hickory, due
advisory DNSSEC non applicabili alle funzionalità attualmente abilitate e due
avvisi di manutenzione. Il risultato non è una certificazione dell'assenza di
vulnerabilità.

## Copertura e metodo

- 504 componenti/versioni crates.io da `native/core/Cargo.lock`.
- 81 componenti/versioni Pub da `pubspec.lock`.
- 95 componenti/versioni Maven risolti localmente con Gradle, configurazione
  `releaseRuntimeClasspath`, senza produrre un APK.
- Due revisioni Git delle dipendenze native interrogate separatamente.
- Confronto con l'[API OSV](https://google.github.io/osv.dev/post-v1-querybatch/),
  con lettura degli advisory completi, controllo dei ritiri e raggruppamento
  degli identificativi equivalenti RustSec/GHSA/CVE.
- Revisione dei percorsi di cattura schermo, blocco/sblocco, trasferimento della
  chiave durante la rimozione della passphrase, logging e pulizia RAM.
- Ricerca di pattern ad alta confidenza per chiavi private PEM, token GitHub e
  access key AWS: nessun riscontro nei 203 file non ignorati esaminati. Questo
  controllo non copre ogni possibile formato di segreto.

La risoluzione Maven usa l'SDK Flutter locale 3.44.6. Il workflow di rilascio
è configurato con Flutter 3.35.5: la composizione dei binari prodotti dalla CI
deve essere verificata anche con quella toolchain. Gli SDK Flutter/Android e il
sistema operativo non sono interamente coperti dai due lockfile o dal database.

I risultati grezzi locali sono in `build/security-audit-osv-before.json`,
`build/security-audit-osv.json`, `build/security-audit-summary-after.txt` e
`build/gradle-release-dependencies.txt`. I file in `build/` non sono versionati.

## Correzioni delle dipendenze

| Componente | Correzione | Segnalazioni rimosse nella seconda scansione |
| --- | --- | --- |
| `rustls` | 0.23.43 → 0.23.46 | Confini di cifratura nell'handshake TLS 1.3, esposizione di segreti tramite `Debug`, allocazioni nella decompressione Brotli dei certificati e downgrade dello scambio di chiavi nelle connessioni successive. |
| `time` | 0.3.45 → 0.3.47 | Esaurimento dello stack durante il parsing di input RFC 2822 costruito appositamente. |

Fonti: [RUSTSEC-2026-0285](https://rustsec.org/advisories/RUSTSEC-2026-0285.html),
[RUSTSEC-2026-0346](https://rustsec.org/advisories/RUSTSEC-2026-0346.html),
[RUSTSEC-2026-0348](https://rustsec.org/advisories/RUSTSEC-2026-0348.html),
[RUSTSEC-2026-0349](https://rustsec.org/advisories/RUSTSEC-2026-0349.html),
[RUSTSEC-2026-0009](https://rustsec.org/advisories/RUSTSEC-2026-0009.html).

## Segnalazioni residue

| Componente e advisory | Gravità dell'advisory | Valutazione nel progetto |
| --- | --- | --- |
| `hickory-proto 0.25.2` — [compressione dei nomi DNS con costo quadratico](https://github.com/advisories/GHSA-q2qq-hmj6-3wpp) | Moderata | Aperta. Possibile esaurimento CPU; lo sfruttamento completo attraverso Sylphy non è stato riprodotto. Correzione indicata nella linea 0.26.1 e successive. |
| `hickory-resolver 0.25.2` — [CNAME non pertinenti](https://github.com/advisories/GHSA-6f2x-v7q7-m7m5) | Moderata | Aperta. Possibile consumo di risorse durante la risoluzione DNS. Correzione indicata dalla 0.26.2. |
| `hickory-proto 0.25.2` — [ciclo nella verifica NSEC3](https://github.com/advisories/GHSA-3v94-mw7p-v465) | Alta | La verifica DNSSEC non è compilata nei grafi delle funzionalità controllati per Windows, Android e Linux. Non risulta applicabile alla configurazione attuale. Rivalutare se vengono abilitate funzionalità DNSSEC. |
| `hickory-resolver 0.25.2` — [errori DNSSEC nascosti dalle API di lookup](https://github.com/advisories/GHSA-5j98-2g5x-46v6) | Alta | Stessa esclusione per assenza di DNSSEC. Non viene presentata come una compromissione DNSSEC attiva di Sylphy. |

La dipendenza è introdotta da `veilid-core 0.5.7 → veilid-tools 0.5.7`, che richiede
Hickory 0.25.2 con `default-features = false` e `system-config`; il profilo Tokio
aggiunge `tokio`. I grafi risolti con `cargo tree -e features` non includono
DNSSEC. Il resolver di Veilid usa Hickory su Android/Linux e le API di sistema su
Windows. Non è stato dimostrato che tutti i percorsi problematici siano
raggiungibili da input remoto attraverso Sylphy.

La migrazione a Hickory 0.26.2 richiede un aggiornamento compatibile di
`veilid-tools`/Veilid oppure un backport mantenuto. Non è una sostituzione
compatibile effettuabile modificando soltanto la versione del lockfile. Prima
del prossimo rilascio va pianificata e verificata con test di bootstrap e DNS
sulle piattaforme supportate.

Avvisi distinti, senza una vulnerabilità runtime specifica dimostrata:

- [`paste 1.0.15` non mantenuto](https://rustsec.org/advisories/RUSTSEC-2024-0436.html).
- [`proc-macro-error2 2.0.1` non mantenuto](https://rustsec.org/advisories/RUSTSEC-2026-0173.html).

La scansione non ha restituito advisory per i componenti Pub e Maven interrogati.
Questo descrive la copertura del database, non prova l'assenza di vulnerabilità.

## Screenshot e gestione degli errori

È stata aggiunta l'opzione **Privacy del profilo → Consenti screenshot dell'app**.
Su Android è disattivata per impostazione predefinita e viene salvata nelle
preferenze cifrate. Se abilitata consente le catture solo a sessione sbloccata
e in primo piano. Avvio, pausa, spegnimento dello schermo e blocco mantengono
`FLAG_SECURE`; il ritorno in primo piano attende il controllo della sessione.
L'UI privata resta coperta fino alla conferma della preferenza da parte nativa.
Il [flag Android](https://developer.android.com/security/fraud-prevention/activities)
blocca anche registrazioni e display non sicuri compatibili.

Su Windows il controllo in Privacy usa lo stesso stato dello Stream proof,
evitando preferenze in conflitto. Linux non espone l'opzione perché il progetto
non dispone di un meccanismo equivalente affidabile per tutti i compositor.

È stata inoltre rinforzata la gestione di una chiamata nativa di cattura fallita:
il suo stato viene considerato sconosciuto. La scelta di ripristinare la
protezione precedente deve riapplicarla realmente prima di mostrare il contenuto.
Un test simula una modifica nativa seguita dalla perdita della conferma e
verifica che il ripristino non usi soltanto lo stato conservato in Dart.

Non è stata eseguita una verifica su dispositivi Android fisici o con strumenti
di cattura Windows. Nessun meccanismo impedisce una fotografia esterna o offre
una garanzia contro un sistema operativo compromesso.

## Verifiche eseguite

- `flutter analyze --no-pub lib test`: nessun problema.
- `flutter test --no-pub`: **192 test superati**.
- `:app:compileDebugKotlin -x :app:preBuild`: compilazione riuscita. Escluso il
  controllo di freschezza dei binari nativi locali; non è una build APK completa.
- `cargo check --locked --features veilid,signal-ratchet`: riuscito con Rust
  1.93.1, toolchain GNU Windows, dopo gli aggiornamenti di sicurezza.
- Seconda interrogazione OSV dopo gli aggiornamenti e controllo delle
  funzionalità Hickory per Windows, Android e Linux.

Non sono stati eseguiti penetration test, fuzzing esteso, una revisione formale
del protocollo crittografico o test completi di rete su dispositivi reali.
