# Impostazioni e trasferimento dell’account — ottobre 2026

## Navigazione

Le impostazioni hanno un indice ricercabile e pagine dedicate ad account e
dispositivi, sicurezza locale, privacy del profilo, messaggi e spunte, contatti,
aspetto e tastiera, accessibilità, rete, aggiornamenti e diagnostica. Le sezioni
notifiche e vibrazione e condivisione schermo compaiono solo sulle piattaforme
che le supportano. Indietro torna all’indice conservando la ricerca. Le preferenze
continuano a usare lo stesso archivio cifrato.

## Collegamento e ripristino

“Collega un altro dispositivo” e “Usa un account esistente” aprono la stessa
procedura guidata in modalità invio o ricezione. Quest’ultima è accessibile
anche al primo avvio, senza creare prima un nuovo profilo.

Sul dispositivo di origine si sceglie e conferma una password di trasferimento
di almeno 10 caratteri, distinta dalla passphrase di blocco. Si può salvare il
backup, condividerlo oppure mostrare un QR sulla rete locale. Su Android il
salvataggio usa il selettore documenti di sistema; la condivisione specifica
`fileNameOverrides`, perché `XFile.fromData.name` non conserva il nome effettivo
sulle piattaforme native. Il file risultante si chiama `Sylphy-account.sylphy-account`.

Sul destinatario si sceglie prima il file o si riceve il documento dal QR, poi
si inserisce la password. Il selettore non impone estensioni/MIME: i provider e
le app di condivisione possono rinominare un backup valido. La verifica del
contenuto richiede ancora `format: sylphy-account-backup`, versione 1 e un
Base64 valido; padding e spazi nel Base64 vengono normalizzati per il core.
La dimensione effettiva del documento rimane limitata a 130 MiB. La verifica
autenticata, Argon2id e la decifratura restano esclusivamente in Rust.

Una password errata lascia selezionato il file per un nuovo tentativo e non
modifica l’account di destinazione. Se sul dispositivo esiste già un account,
una conferma esplicita spiega che l’importazione sostituisce i dati locali e
non unisce due account. Gli errori mostrano istruzioni e un codice diagnostico
stabile, mai password o contenuti del documento. Lo stesso codice, senza dati,
viene registrato nei log.

## Blocco e interruzioni

Il blocco automatico resta attivo anche durante i selettori di sistema. Se il
blocco elimina la schermata mentre arriva il risultato del selettore, la radice
conserva soltanto il documento cifrato e ripropone la procedura dopo lo sblocco.
La password non viene conservata e l’importazione non riparte automaticamente.
La chiusura dell’app azzera la selezione e invalida i risultati tardivi.

La transazione nativa installa anche `native/identity/imported-profile.vault`,
un record cifrato con il segreto del dispositivo destinatario, contenente il
profilo nello schema locale versione 2. Il file viene preparato nella directory
di staging e segue gli stessi commit/rollback dell’identità. Se il processo
termina o si blocca dopo il commit e prima del salvataggio Flutter, il successivo
avvio/sblocco recupera quel profilo, preferendolo ai dati del vecchio account.
Il recupero viene rimosso dopo il salvataggio del profilo cifrato ordinario;
un salvataggio fallito lo lascia disponibile per un nuovo tentativo.

Il formato del backup nativo rimane versione 2. Non vengono clonate catene
Signal vive: il nuovo dispositivo conserva l’identità dell’account e genera
uno stato Signal proprio. I dispositivi tornano a pubblicare i rispettivi
endpoint tramite i meccanismi di sincronizzazione esistenti.

## QR e codice copiato

Il QR trasporta soltanto indirizzi IPv4 privati e un token casuale monouso,
mai password o chiavi. È disponibile anche copiando il codice per un computer
senza fotocamera. Il documento servito sulla LAN è già cifrato e autenticato
con la password di trasferimento. Non sono seguiti redirect HTTP; una risposta
di rete non può spostare il download su un host diverso. Il QR scade dopo cinque
minuti, accetta un solo trasferimento concorrente e segnala il trasferimento
solo dopo il completamento della risposta. L’invio del file non significa che
il destinatario abbia già completato il ripristino.

## Verifiche

I test coprono nome effettivo della condivisione, file rinominati, envelope non
validi, normalizzazione Base64, errori nativi, profilo già importato con errore
di persistenza/cleanup, recupero del profilo dopo riavvio, retry senza ripetere
il selettore, conferma di sostituzione, selezione durante blocco e chiusura,
riapertura della procedura dopo sblocco, QR locale monouso e ricerca/navigazione
delle impostazioni su viewport mobile e desktop.

Il test Rust esegue un export/import reale fra due archivi con segreti diversi,
controlla l’identità invariata, lo stato Signal distinto, il profilo di recupero
cifrato e la conservazione dell’account precedente con una password sbagliata.
Rimangono i test delle interruzioni a ogni confine del commit e del rollback.
Le prove automatizzate non sostituiscono un trasferimento fra due dispositivi
fisici e provider documenti diversi.
