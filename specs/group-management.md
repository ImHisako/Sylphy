# Gestione dei gruppi · protocollo v1

## Canali e moderazione (ABI 13)

Il gruppo contiene sempre la chat Generale. Gli amministratori con `change_info`
possono creare e rinominare fino a 50 canali, con ID stabili e nomi univoci
ignorando maiuscole/minuscole. I canali ereditano membri, cifratura e permessi
del gruppo. La capability firmata `group-channels-v1` deve essere presente su
tutti gli endpoint prima di usare i canali o aggiungere nuovi membri a un gruppo
che li contiene.

La voce **Gestisci canali** nelle impostazioni apre una pagina dedicata a
creazione, rinomina, eliminazione e ordinamento. Il riordino è disponibile con
trascinamento e con i comandi Sposta su/Sposta giù; Generale rimane fisso.

`create_channel`, `rename_channel`, `move_channel` e `delete_channel` sono azioni
coordinate dal proprietario. `move_channel` usa un ID stabile e
`before_channel_id` (null per spostare in fondo), evitando di sovrascrivere
l'intero elenco con una copia potenzialmente obsoleta. Creazione, rinomina e
riordino richiedono `change_info`; eliminare richiede anche `delete_messages`.
La pagina chiede conferma prima di eliminare il canale e la sua cronologia.
Le azioni delegate rimangono visibilmente in attesa, senza anticipare una
modifica che il proprietario potrebbe rifiutare.

Eliminazione e riordino richiedono la capability firmata
`group-channel-management-v1` su tutti gli endpoint. Gli ID eliminati sono
conservati in `deleted_channels` nello snapshot e nel vault (default vuoto per
i gruppi precedenti): cronologia e allegati locali vengono rimossi, i messaggi
tardivi vengono confermati senza reinserirli e la sincronizzazione di vecchi
dispositivi non li ripristina. I nuovi membri di un gruppo con canali eliminati
devono supportare questa capability.

`send_channel_text`, `send_channel_attachment` e `mark_channel_read` completano
il bridge. Il testo ricco e i puntatori degli allegati hanno un `channel_id`
opzionale: assente significa Generale. Le risposte mantengono il canale
dell'originale; leggere un canale lascia non letti gli altri. Il log cifrato
conserva anche la lettura per canale. Snapshot amministrativi e messaggi possono
arrivare fuori ordine: il contenuto di un canale ancora sconosciuto resta in attesa.

`action_notices` permette a chi ha `manage_permissions` di impostare
`show_action_notices`, inizialmente attivo. Disattivarlo sopprime i nuovi avvisi
in chat sui client aggiornati; permessi, cancellazioni e fissaggi sono comunque
applicati e sincronizzati. La cronologia degli avvisi precedenti resta invariata.

Le richieste delegate equivalenti restano una sola richiesta persistente fino
allo snapshot o al rifiuto del proprietario. Ripetere una cancellazione già
applicata non produce un altro avviso. La conferma remota dipende ancora dalla
raggiungibilità del proprietario; il client distingue lo stato in attesa da una
modifica applicata e impedisce la ripetizione dal menu del messaggio.

Un membro rimosso non viene reinserito come “Tu” nell'elenco membri. Il
proprietario rimasto solo può conservare messaggi e allegati nel vault senza
destinatari di rete; l'assenza di membri non aggira i controlli sui gruppi chiusi
o sui partecipanti rimossi. Le anteprime delle chat decodificano il testo ricco
e mostrano autore e azione per le risposte, senza prefissi di protocollo.

Flutter e libreria nativa vanno ricompilati e distribuiti insieme (ABI 13).
La dipendenza Veilid rimane invariata.

## Comportamento e compatibilità

L'ABI 11 introduce `group_details`, `group_action`, `join_group`, `search_messages`
e `send_reply`. Flutter e libreria nativa devono essere aggiornati insieme.
I nuovi inviti pubblicano la capability firmata `group-management-v1`; creazione,
aggiunta di membri e amministrazione richiedono che tutti gli endpoint del gruppo
la supportino. I vecchi codici personali vanno rigenerati con il client aggiornato.
I record locali preesistenti ricevono permessi aperti grazie ai default Serde.

`group` e `channel` distinguono gruppo normale e aziendale: entrambi consentono
ai membri di scrivere per impostazione predefinita. Il proprietario o un admin
con `manage_permissions` può consentire o negare messaggi, allegati e link,
impostare un intervallo minimo tra messaggi e attivare l'antispam aggressivo.
Sylphy non espone permessi per sticker o sondaggi, che non sono tipi di messaggio
implementati. Le GIF seguono i permessi degli allegati.

Le restrizioni individuali si sommano a quelle del gruppo. Proprietario e admin
sono esenti dai limiti di scrittura; per limitare un admin va prima revocato il
ruolo. I privilegi delegabili sono eliminazione messaggi, gestione membri,
modifica informazioni, inviti, nomina admin, messaggi fissati e gestione permessi.
Un delegato non può conferire privilegi che non possiede né modificare un altro
admin; solo il proprietario può eliminare il gruppo per tutti.

La modalità lenta e le finestre temporali dell'antispam limitano anche il ritmo
di elaborazione in ricezione. Il superamento di queste finestre produce però
`inbound_deferred`: il pacchetto cifrato non viene confermato alla mailbox e viene
ritentato dalla normale sincronizzazione. La decifratura non ancora confermata
viene annullata, così il medesimo pacchetto può essere elaborato successivamente.
Questo consente di ricevere un arretrato arrivato in blocco o fuori ordine senza
scartarlo soltanto per il momento di arrivo. Non si usa l'orologio del mittente
per autorizzare gli invii. Si applicano ancora la retention e i limiti della rete.

I divieti su membership, messaggi, media, link e contenuti con troppe menzioni
restano rifiuti definitivi. L'invio locale conserva gli errori `slow_mode_active`
e `spam_rejected`. Non cambia il formato dei messaggi né la versione del protocollo.
Le regressioni verificano ricezione fuori ordine, rinvio e retry dello stesso
ciphertext, persistenza al riavvio, deduplicazione e distinzione tra limiti
temporanei e divieti di contenuto.

Il nome e l'avatar del gruppo nell'intestazione della chat aprono le impostazioni,
sia su desktop sia su mobile. Al ritorno dalla gestione viene aggiornata la chat.

Nella schermata di gestione, i comandi per informazioni, permessi e inviti mostrano
un lucchetto quando manca il privilegio necessario. Un clic spiega quale permesso
chiedere al proprietario, senza inviare azioni al core. Per un gruppo chiuso o
una membership revocata viene mostrato il relativo motivo; durante un'operazione
i comandi restano temporaneamente disabilitati.

## Trasporto e autorità

Il dispositivo creatore coordina le revisioni del gruppo. Le azioni dei delegati
sono richieste E2EE indirizzate al proprietario: l'interfaccia indica che restano
in attesa se quel dispositivo è offline. Il coordinatore ricontrolla membership
e privilegi prima di applicarle e distribuisce snapshot a revisione crescente.
I destinatari verificano la firma dell'endpoint e l'identità/dispositivo del
coordinatore; non accettano snapshot prodotti da un normale membro.

I controlli `Request`, `Snapshot`, `Join`, `Invite` e `Rejected` usano blob cifrati
e puntatori compatti autenticati nelle sessioni individuali esistenti. Nessuna
directory di gruppo viene pubblicata in chiaro. Il vault del gruppo persiste
atomicamente stato e consegne pendenti prima di trasferirle nell'outbox; gli
effetti locali vengono registrati per poterli ripetere dopo un'interruzione.
I backup validano anche le consegne di controllo prive di un messaggio visibile.

I messaggi normali e gli allegati usano lo stesso ID logico per la copia locale
e per tutte le consegne cifrate separatamente. Questo rende riferimenti di
risposta, pin e cancellazione coerenti tra destinatari. I vecchi messaggi inviati
con ID diversi non ricevono retroattivamente un ID condiviso.

## Membri, inviti e cancellazioni

L'aggiunta diretta verifica i codici personali firmati. I link di gruppo hanno
token casuale, scadenza di sette giorni e revoca; crearne uno nuovo invalida il
precedente. Chi entra tramite link conserva una richiesta pendente fino alla
risposta del proprietario. I nuovi membri ricevono la directory e i messaggi
successivi, non la cronologia pregressa.

Rimozione e chiusura vengono inviate anche ai membri appena rimossi. Una chiusura
è persistente e non viene annullata da inviti o sincronizzazioni precedenti. Gli
ID dei messaggi cancellati vengono conservati come tombstone; la ricerca, la
cronologia e la sincronizzazione dei dispositivi li escludono. I client aggiornati
eliminano le copie locali gestite dall'app, incluse quelle ancora in outbox.
La consegna ai dispositivi offline resta soggetta alla disponibilità e alla
retention della rete: non è una garanzia di cancellazione remota di esportazioni,
screenshot o client modificati.

## Ricerca, risposte e fissati

L'indice testuale locale usa trigrammi e liste per conversazione. Si aggiorna
incrementalmente con nuovi messaggi e si ricostruisce dopo cancellazioni o cambio
account. Rimane esclusivamente in memoria: nessun indice plaintext viene scritto
su disco. Le parole cercate sono combinate in AND, senza distinzione tra maiuscole
e minuscole; query brevi usano la lista della conversazione. I risultati sono
paginati a 50 elementi; `id:` risolve un messaggio nella sola chat richiesta.

Le risposte conservano un ID nel payload testuale versionato e cifrato.
Il selettore dei membri inserisce `@nome`, sostituendo spazi e punteggiatura con
underscore. Le menzioni sono cliccabili: aprono la scheda del membro attuale
corrispondente, con nome, ruolo e identificativo. Gli omonimi richiedono una scelta;
un nome non più presente mostra un avviso. Non sono tag d'identità immutabili.
Menzioni e hashtag restano ricercabili tramite la ricerca della chat.
I link HTTP/HTTPS nei messaggi, inclusi quelli dei video e i domini senza schema,
sono cliccabili. Un dialogo mostra la destinazione completa e richiede «Apri nel
browser» prima di passarla al gestore esterno del sistema. Annullamento e chiusura
non aprono nulla; schemi non web e URL con credenziali non vengono aperti. Non
vengono scaricate anteprime né inviato il testo del messaggio al browser.
I pin sono visibili in alto e nella gestione
del gruppo. Alla ricezione di nuovi pin viene mostrato un avviso specifico;
Android usa una notifica generica "Messaggio fissato", senza contenuto della chat.

Gli avvisi di messaggio e di pin sono soppressi per la conversazione effettivamente
visibile quando l'app è in primo piano. Una chat selezionata ma coperta da un'altra
pagina, oppure chiusa nella lista mobile, non viene considerata visibile. Su
Android il servizio lascia il polling e la decisione sugli avvisi a Flutter mentre
l'Activity è ripresa, evitando una seconda notifica indipendente dalla chat aperta.

Ogni messaggio di gruppo mostra il nome del mittente sopra testo e allegati.
Il core conserva nel log cifrato il nome del profilo autenticato alla ricezione,
così resta disponibile dopo un riavvio o la rimozione del membro. Per i record
precedenti recupera il nome dalla directory del gruppo o dai contatti; in assenza
di questi dati mostra un identificatore del membro. Il read model `author_name`
è opzionale e non cambia i pacchetti di rete esistenti.

## Antispam e limiti effettivi

La modalità lenta permette da 0 a 3.600 secondi. Il core verifica le restrizioni
sia all'invio sia alla ricezione. Per il rate limit in ricezione usa l'orario
locale di arrivo, non un timestamp scelto dal mittente. L'antispam aggressivo
blocca raffiche di almeno cinque messaggi recenti in dieci secondi, duplicati
entro un minuto e testi con più di cinque `@`. È un filtro euristico locale:
consegne accumulate offline possono attivarlo e client con storie diverse
possono avere decisioni diverse. Non è un classificatore centralizzato.

Questa implementazione conserva i limiti dell'archivio esistente: 100.000 messaggi
e log cifrato di 64 MiB, allegati di 700 KiB, al massimo 64 destinatari oltre al
creatore. Il gruppo ammette 50 pin, 512 richieste pendenti e 4.096 azioni applicate
registrate per deduplicazione. La ricerca è verificata su 100.000 messaggi sintetici;
**non è supportata né certificata la ricerca su milioni di messaggi**. Per quella
scala servono un archivio cifrato segmentato e una politica di compattazione dei
controlli distinta, con migrazione e benchmark dedicati.

## Verifica

I test Rust verificano invio dei membri in entrambe le modalità con crittografia
reale e ID condivisi, permessi e antispam, richieste non autorizzate, snapshot
contraffatti/fuori ordine, tombstone, backup e un ciclo completo di delega,
invito cifrato, ingresso, revoca, rimozione e chiusura. Nei test di gestione viene
sostituito soltanto il trasporto di rete dei blob; identità, pacchetti Signal e
vault sono reali. I test Flutter coprono impostazioni, aggiunta membri, conferma
di eliminazione, accessi senza privilegi e risposte di ricerca fuori ordine.
Questi test non sostituiscono una prova su dispositivi reali collegati a Veilid.
