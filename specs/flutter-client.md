# Contratto del client Flutter

## Preferenze e chat (settembre 2026)

- Il titolo della chat privata apre il profilo del contatto. Su desktop ampio
  il pannello dei dettagli si chiude con la X e si riapre dal titolo o dal pulsante
  del profilo; sulle finestre più strette i dettagli si aprono in un foglio.
- I messaggi fissati mostrano una puntina nella bolla e restano ricercabili.
- “Mostra spunte ricevute” controlla `send_read_receipts`: disattivandolo gli altri
  non ricevono conferme di lettura. Le proprie spunte di consegna restano visibili.
  Un precedente `show_read_receipts: false` migra all'invio delle letture disattivato.
- `incognito_keyboard` imposta `enableIMEPersonalizedLearning: false` nel campo
  dei messaggi. Gboard e altre tastiere compatibili possono rispettare questa
  richiesta; la preferenza non forza il comportamento di tastiere esterne.
- `theme_name` seleziona Sylphy, Black, Cyan, Pink, AMOLED o White. Tema e preferenza
  della tastiera sono salvati nel record cifrato delle impostazioni.
- Le notifiche Android in primo piano hanno un tag per conversazione e vengono
  cancellate dopo la lettura. La notifica riepilogativa del servizio viene rimossa
  quando non rimangono messaggi non letti; la notifica del servizio resta attiva.

## Responsabilità

Il client Flutter mostra solo dati già disponibili localmente e passa il testo appena composto al bridge di sicurezza. Non conserva password, chiavi private, root key, chain key, bundle di prekey non protetti o envelope decifrati più a lungo del necessario per il rendering.

Al primo avvio `ProfileOnboarding` richiede un display name limitato a 64 caratteri e consente una foto facoltativa entro 5 MiB. Lo stesso form viene riaperto dal pannello “Il mio profilo” per modificare i campi già salvati. Questi campi sono metadati di presentazione scelti dall'utente; non costituiscono l'identità Ed25519 e non contengono chiavi. `IdentityService` conserva una chiave di sblocco casuale nel secure storage della piattaforma e chiede al core soltanto fingerprint pubblico e invito firmato. La home espone l'import contatto su mobile e desktop, ma consegna il codice invito opaco al core senza interpretarne il materiale crittografico in Dart.

## Implementazione richiesta del bridge

L'implementazione di produzione di `SecureMessagingBridge` deve essere un adapter minimo per il core Rust/FFI. Il core è responsabile di:

- sblocco e blocco del vault cifrato;
- verifica dell'identità e del bundle di prekey;
- handshake ibrido X25519 + ML-KEM-768;
- ratchet, replay window e deduplicazione;
- cifratura del payload e costruzione dell'envelope versionato;
- pubblicazione e ricezione Veilid di soli envelope opachi;
- persistenza dei messaggi e metadata nel vault cifrato.

## Vincoli di sicurezza

- Il bridge deve rifiutare l'invio se non esiste una sessione autenticata.
- Il bridge non deve fare fallback silenzioso dal profilo ibrido a quello classico.
- Gli errori esposti alla UI non devono includere plaintext, chiavi o serializzazioni dell'envelope.
- Le conversazioni e i messaggi consegnati alla UI provengono solo da record già validati, decrittati e limitati dal core.

## Stato attuale

`NativeCoreClient` carica opzionalmente l'ABI C v14 del core Rust su Windows, Linux e Android. Un isolate persistente possiede la libreria nativa e serve una coda che dà priorità a messaggi e allegati rispetto al refresh periodico, evitando la creazione di un isolate e il caricamento della DLL per ogni comando. `VeilidService` avvia il nodo nello storage applicativo persistente, ritenta startup e attachment falliti e distingue feature assente, bootstrap Android, protected/local store, configurazione e rete senza esporre dettagli interni.

`main.dart` non seleziona alcun bridge dimostrativo. Senza core usa `UnavailableMessagingBridge`, che restituisce un inbox vuoto e rifiuta import e invio; con il core usa `SylphyMessagingBridge`, che accetta soltanto read model nativi validi. Il refresh scambia prima una revisione numerica e rilegge conversazioni o messaggi soltanto quando il core segnala una mutazione, eliminando il polling della cronologia completa ogni 700 ms. L'invio appare subito nella conversazione come elemento ottimistico; un errore lo rimuove e ripristina il testo nel composer. I fake restano confinati ai test widget.

## Consegna e ripresa della connessione

`SylphyMessagingBridge` espone `InboxRevisionNotifications`: le chat aperte
ascoltano la revisione completata dal refresh della schermata principale,
senza avviare un secondo polling di rete. Vale anche per gli aggiornamenti
delle spunte che non cambiano l'anteprima della conversazione. Le notifiche
non cambiate non causano nuove letture; il listener viene rimosso alla chiusura
o alla sostituzione del bridge. Il timer preesistente resta solo per gli
adapter che non espongono questa capability. Una risposta in volo del vecchio
account non può pubblicare una revisione dopo l'import di un altro account.

Gli invii vengono confermati al composer appena registrati nell'outbox cifrato.
Il trasporto lavora in un worker nativo e aggiorna successivamente `queued` o
`sent`, anche dopo un riavvio; il log deve applicare gli aggiornamenti delle
righe esistenti. Il tooltip delle spunte distingue attesa, invio, consegna e
lettura. La ricezione duplicata non genera nuove notifiche. Il ritorno in primo
piano forza la ripubblicazione dell'endpoint, anche quando il profilo non cambia.
Per requisiti e limiti della consegna offline vedere [offline-delivery.md](offline-delivery.md).

## Gruppi e canali

`GroupMessagingBridge.createGroup` crea due modalità di conversazione: `group` per una chat classica e `channel` per uno gruppo aziendale con permessi configurabili. I codici invito vengono passati opachi al core Rust, che verifica le identità firmate, cifra la directory locale e invia un invito E2EE a ogni membro. I messaggi successivi sono cifrati tramite la sessione individuale di ciascun membro e contengono soltanto un identificatore casuale di gruppo e il testo autenticato; la rete non riceve una rubrica o un plaintext di gruppo.
