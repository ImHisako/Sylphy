# Inviti di gruppo v2

Le identità firmate dei partecipanti includono prekey post-quantum, profili
e dispositivi collegati. Serializzarle tutte nel testo dell'invito v1 poteva
superare il limite di 16 KiB già con un solo invitato; aumentare quel limite
non risolve il vincolo di 32 KiB del pacchetto di trasporto.

Il creatore serializza la membership v1 in un blob di massimo 700 KiB,
cifrato con il formato XChaCha20-Poly1305 del vault e una nuova chiave casuale.
Il blob usa pubblicazione a chunk e conservazione di sette giorni degli
allegati. Nessuna identità o membership viene pubblicata in chiaro.

Il controllo `sylphy-group-invite-v2:` contiene un puntatore JSON in base64
senza padding: versione 2, dimensione plaintext, record key, numero di chunk
e chiave del blob. Il puntatore viaggia dentro il normale pacchetto ibrido
Signal + X25519/ML-KEM-768, separatamente per ciascun dispositivo invitato.
Non cambiano né l'ABI C né il formato SecurePacket.

Il ricevente valida versione, limiti e lunghezza della chiave prima di
scaricare il blob. Verifica autenticazione e dimensione del plaintext, quindi
le identità firmate, l'amministratore e la propria presenza tra gli invitati.
Salva solo i membri remoti, evitando conteggi duplicati e invii a sé stesso.
Un download temporaneamente fallito non avanza la ratchet: lo stesso pacchetto
può essere ritentato. Un blob alterato non viene accettato.

Gli errori di creazione rimuovono il blob pubblicato e la relativa lease;
la membership locale viene annullata se non è possibile salvare la coda.
La consegna del puntatore resta soggetta ai retry della normale outbox.

I nuovi bundle firmati annunciano `group-invite-blob-v2`. La creazione verifica
la capability di ogni dispositivo invitato prima di pubblicare il blob;
i client precedenti devono aggiornarsi e ripubblicare l'endpoint. Il decoder
continua ad accettare gli inviti v1 ricevuti dai client precedenti.

Il test nativo usa due identità reali, avatar grandi e cifratura Signal/ibrida:
verifica un invito che superava 16 KiB, il puntatore compatto, la corruzione,
i limiti, il retry dopo un download fallito e la membership dopo il riavvio.
La rete DHT è sostituita da uno storage in memoria nel test; la verifica su
due dispositivi reali resta necessaria prima della distribuzione.
