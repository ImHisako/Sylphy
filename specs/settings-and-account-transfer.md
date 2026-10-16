# Impostazioni e trasferimento dell’account — ottobre 2026

## Navigazione

Le impostazioni mostrano lo stato della rete e il comando di riconnessione sopra
l’indice ricercabile. Le pagine sono dedicate ad account e dispositivi, sicurezza
locale, privacy del profilo, aspetto, aggiornamenti e diagnostica. Privacy del
profilo raccoglie anche messaggi e spunte e contatti e richieste; Aspetto include
le opzioni di accessibilità insieme a tema e tastiera. Le sezioni
notifiche e vibrazione e condivisione schermo compaiono solo sulle piattaforme
che le supportano. Indietro torna all’indice conservando la ricerca. Le preferenze
continuano a usare lo stesso archivio cifrato.

Privacy del profilo include **Consenti screenshot dell’app** su Android e
Windows. Android parte con le catture disabilitate, conserva la scelta nelle
preferenze cifrate e protegge comunque blocco e background. Windows condivide
lo stato con Stream proof: consentire le catture disattiva quella protezione.
Linux non espone l'interruttore. Android e Windows attendono la conferma nativa
prima di mostrare il contenuto durante una modifica; un errore richiede una
nuova applicazione della policy anche quando si ripristina la scelta precedente.

## Rotazione dell’ID Sylphy

Privacy del profilo include **Cambio automatico dell’ID** e **Cambia ID adesso**.
Il valore predefinito è “Solo manualmente”; sono disponibili 1 o 6 ore, un giorno,
una settimana, 30 giorni e un intervallo personalizzato intero da 1 a 8760 ore.
La preferenza è salvata nello stesso archivio cifrato delle altre impostazioni.
Il profilo distingue l’ID da condividere dall’impronta crittografica stabile.
Il cambio manuale riavvia il conteggio dall’ultimo rinnovo; disattivare il timer
conserva l’ID corrente e lascia disponibile il cambio immediato.

Un ID breve è ora un record DHT casuale separato, contenente
`kind: sylphy-invitation-v1`, `version: 1`, il puntatore di discovery, la chiave
pubblica Ed25519 dell’account, la scadenza e la firma su dominio dedicato.
Il core Rust verifica la firma e che il record di destinazione appartenga alla
stessa identità. Rifiuta versioni, chiavi, firme e scadenze non valide; non segue
catene di inviti. Contatti e gruppi conservano il puntatore di discovery stabile:
non cambiano chat, chiavi Signal, prekey, mailbox o verifica dei contatti.
I client precedenti continuano a usare i contatti esistenti; per aggiungere un
nuovo ID di questo formato serve la versione aggiornata dell’app.

L’identità cifrata conserva descrittore dell’invito, intervallo, ultimo cambio e
revoche pendenti. Una rotazione pubblica un nuovo record, salva atomicamente
nuovo descrittore e vecchia revoca e poi sostituisce il vecchio invito con una
revoca firmata. Le revoche fallite restano persistenti e vengono ritentate:
la UI segnala quando il nuovo ID è pronto ma la revoca non è ancora confermata.
La coda è limitata a 16 descrittori; oltre il limite si blocca un ulteriore cambio,
conservando quello corrente. Il backup conserva l’identità, mentre l’importazione
azzera invito e revoche della sorgente per assegnare un ID locale al nuovo dispositivo.

Il timer usa la scadenza nativa, si cancella al blocco e alla chiusura e riprende
alla successiva inizializzazione. Un’app chiusa, sospesa dal sistema o bloccata
non garantisce un rinnovo puntuale: aggiorna l’ID alla ripresa con rete disponibile.
Gli inviti automatici scadono comunque all’ora firmata; un codice scaduto disabilita
il pulsante di copia nel profilo. Gli errori di rete mantengono l’ultimo stato visibile,
riportano il fallimento e ritentano dopo 60 secondi, senza generare nuovi ID a vuoto.

Il rinnovo dell’ID non garantisce anonimato né revoca l’accesso di una persona
che conosce già il riferimento stabile: l’identità firmata e il puntatore sono
correlabili. I vecchi ID legacy condivisi prima dell’aggiornamento erano essi
stessi riferimenti di discovery e rimangono risolvibili. La DHT può servire
copie obsolete; la revoca manuale si propaga secondo la rete e non costituisce
una cancellazione garantita né sostituisce i controlli sulle richieste di contatto.

I test coprono firma e scadenza, sostituzione del puntatore firmato, identità
invariata, fallimento offline senza perdita dell’account, separazione degli
inviti fra dispositivi importati, timer, cambio manuale, privacy del profilo,
interruzione al blocco, revoche pendenti e UI per gli intervalli personalizzati.
La pubblicazione e la propagazione fra due nodi Veilid e le prove su dispositivi
fisici rimangono da verificare prima del rilascio.

## Logging diagnostico

Diagnostica espone un interruttore per il logging di base, disattivato per impostazione
predefinita. Disattivandolo `AppLog` non raccoglie nuovi eventi in memoria, non
scrive nuovi log su file e non stampa in console, anche per errori o chiamate
`force`. Il logging dettagliato è subordinato a questo interruttore. La scelta
viene salvata in `diagnostics/developer-options.json` insieme alla preferenza
del logging dettagliato, che viene conservata per una successiva riattivazione.
All’avvio non vengono raccolti eventi prima della lettura delle preferenze.
Anche i log applicativi Android restano spenti fino all’abilitazione esplicita.
I log già presenti restano consultabili e possono essere cancellati con il
comando esistente; la cancellazione non genera un nuovo evento quando il logging
è disattivato.

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
