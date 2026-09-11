# Aggiornamenti dalle release GitHub

## Flusso utente

Le build di produzione per Android, Windows x64 e Linux x64 controllano
`ImHisako/Sylphy` otto secondi dopo l'avvio e ogni sei ore mentre l'app è in
primo piano. Il ritorno in primo piano rispetta lo stesso intervallo; gli errori
consentono un nuovo tentativo dopo quindici minuti. Il controllo non blocca
avvio, messaggi o inizializzazione Veilid. Nelle build di sviluppo è manuale.

Una versione stabile più recente mostra un solo popup con versione, dimensione
e note. “Più tardi” chiude il popup; “Salta versione” persiste la scelta. “Scarica
aggiornamento” avvia un download con avanzamento e annullamento. Al termine,
“Aggiorna” è una seconda azione esplicita. Nessun installer viene eseguito dal
solo controllo delle release o dal completamento del download.

Le impostazioni permettono di disattivare i controlli automatici, verificare
manualmente e riaprire un aggiornamento già scaricato. Il controllo manuale
ignora l'opzione di salto. Un file già presente viene riutilizzato soltanto
dopo averne nuovamente verificato dimensione e SHA-256.

## Origine, integrità e limiti

Il client usa esclusivamente HTTPS verso l'API GitHub e gli asset del repository
fisso. I redirect dei file possono raggiungere solo i domini CDN GitHub previsti;
i redirect dell'API sono rifiutati. Non vengono inviati token GitHub, messaggi,
identità o informazioni dell'account. Sono richieste dirette a GitHub, che vede
l'IP del dispositivo: l'impostazione consente di disabilitarle.

La fiducia è quella del repository GitHub, di HTTPS e dei certificati del sistema.
SHA-256 verifica integrità e coerenza con la release, non costituisce una firma
indipendente del manutentore. Un repository compromesso resta nel threat model.

Il client richiede il digest `sha256:` fornito da GitHub per manifest e installer.
Il manifest `sylphy-update.json`, schema 1, contiene `version` e `build` e deve
corrispondere al tag. La versione semantica e il build devono entrambi aumentare.
Draft, prerelease, downgrade, asset mancanti/ambigui e URL di altri repository
non sono aggiornamenti installabili. Una release viene pubblicata soltanto dopo
aver caricato tutti i file e una release già pubblica non può essere sovrascritta
dal workflow: le correzioni richiedono una nuova versione.

Limiti: risposta API 2 MiB, manifest 16 KiB, installer 1 GiB, 5 redirect,
timeout di connessione/lettura e 30 minuti per il download. Il file viene scritto
a blocchi in una directory privata, con estensione `.part`, verificato e poi
rinominato. Errori e annullamenti eliminano il parziale. L'installazione verifica
nuovamente il file. I pacchetti delle versioni già installate vengono rimossi
all'avvio; la pulizia è limitata ai nomi del formato updater.

## Android

L'asset universale è `sylphy-vVERSION-android.apk`. Restano invariati
`applicationId = com.example.sylphy`, storage, account e dati dell'app.
`versionCode` deriva dal numero dopo `+` in `pubspec.yaml` e cresce ad ogni
release. La stessa chiave di firma deve essere usata sempre.

I secret CI richiesti restano `ANDROID_KEYSTORE_BASE64`, `ANDROID_STORE_PASSWORD`,
`ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`. Devono contenere la chiave degli APK
già distribuiti. `tool/verify_android_release.py` verifica la firma effettiva
con `apksigner`, confronta package e versioni con `pubspec.yaml` e confronta
certificati e versionCode con l'APK della release pubblica precedente. Errori
di rete o impossibilità di stabilire la compatibilità fermano la pubblicazione.
Le build senza tag possono usare la firma debug; non sono aggiornamenti di
produzione compatibili e non vanno distribuite come tali.

Il bridge Android accetta solo APK dalla sottodirectory privata
`files/updates/packages`, verifica package, versione annunciata, versionCode e
certificati rispetto all'app installata. Un FileProvider non esportato espone
solo quel percorso, con un permesso temporaneo di lettura all'installer.
Se necessario, l'utente autorizza Sylphy in “Installa app sconosciute”, torna
nell'app e preme nuovamente “Aggiorna”. L'installer Android mantiene la conferma
di sistema. Un annullamento non modifica l'app e consente un nuovo tentativo.

Una vecchia installazione firmata con un'altra chiave non è aggiornabile con la
chiave nuova: nessun cambio di versionCode o updater può aggirare questa regola
Android. Occorre recuperare la chiave originale. Il client segnala il problema
senza proporre di disinstallare o cancellare i dati. La rotazione delle chiavi
non è implementata: questa versione richiede lo stesso certificato attuale.

## Windows

`tool/windows-installer.iss` genera `sylphy-vVERSION-windows-x64-setup.exe` con
Inno Setup 6, AppId stabile e installazione per utente in
`%LOCALAPPDATA%\Programs\Sylphy`. Non modifica AppData dell'account né elimina
chat o chiavi. Il client avvia l'installer normale, senza flag silenziosi,
richiesta di elevazione o terminazione forzata. Quando richiesto dal programma
di installazione, l'utente chiude Sylphy e prosegue.

App e installer condividono un mutex; copie portabili della nuova app e versioni
installate non possono avviare due istanze contemporaneamente nella sessione.
Il setup crea il collegamento nel menu Start. I vecchi ZIP restano disponibili
per uso portabile; il primo passaggio al setup installa il percorso gestito.

## Linux

`tool/release.py linux` genera `sylphy-vVERSION-linux-x64.run`. È un installer
per utente senza sudo, basato su strumenti GNU/Linux standard (`sh`, `tar`,
`sha256sum`, `flock`, `ldd`, `sed`). L'app deve avere le dipendenze runtime GTK 3
e libsecret previste anche dal bundle esistente. Da terminale si può installare
con `sh sylphy-vVERSION-linux-x64.run`, che chiede conferma.

L'installer verifica il payload incorporato, ripristina il bit eseguibile perso
dal trasporto degli artifact e prepara una directory di versione sotto
`~/.local/opt/sylphy`. Un lock impedisce installazioni concorrenti. Il collegamento
`current` viene sostituito atomicamente solo alla fine; la directory precedente
resta disponibile e i dati applicativi non vengono toccati. Vengono creati
`~/.local/bin/sylphy` e una voce nel menu applicazioni. Il primo aggiornamento da
un tar portabile passa a questo percorso gestito.

Dopo l'installazione il popup offre “Riavvia Sylphy”. Il client arresta Veilid
e termina; un helper attende l'uscita senza uccidere il processo e avvia la nuova
versione. GTK registra una sola istanza per sessione e riattiva la finestra già
aperta, anche se lanciata da un percorso di versione differente. I vecchi tar
rimangono pubblicati come alternativa portabile.

## Pubblicazione e verifica

1. Aumentare versione e build in `pubspec.yaml`.
2. Conservare i quattro secret Android con la chiave originale.
3. Creare un tag `vVERSION` coerente con pubspec. Il workflow valida l'incremento
   rispetto ai tag precedenti, esegue test, genera installer e manifest, carica
   tutto in una draft e soltanto allora la rende pubblica.

I test Dart coprono selezione per piattaforma, metadati alterati, digest, URL,
versioni, download corrotti/troncati/eccessivi, annullamento, cache, preferenze,
conferme separate e popup singolo. I test Python verificano packaging e permessi;
su Linux eseguono anche installazione, aggiornamento e rifiuto di un payload
corrotto, controllando che dati e vecchia versione siano conservati.

La validazione locale su Windows non sostituisce l'installazione end-to-end di
due release firmate su Android né la prova degli installer su Windows e Linux.
Nessuna release viene pubblicata dalla sola modifica del codice.
