//! A volatile substring index. Disk data stays in the encrypted message log.
//! Postings contain offsets only; append-only updates do not rebuild old text.
use super::*;

#[derive(Default)]
struct Index {
    generation: u64,
    last_id: Option<String>,
    texts: Vec<String>,
    grams: HashMap<[u8; 3], Vec<u32>>,
    chats: HashMap<String, Vec<u32>>,
    ids: HashMap<String, u32>,
}

impl Index {
    fn update(&mut self, messages: &[StoredMessage], generation: u64) {
        if self.generation != generation
            || self.texts.len() > messages.len()
            || (!self.texts.is_empty()
                && messages
                    .get(self.texts.len() - 1)
                    .map(|message| &message.id)
                    != self.last_id.as_ref())
        {
            *self = Self {
                generation,
                ..Self::default()
            };
        }
        for (index, message) in messages.iter().enumerate().skip(self.texts.len()) {
            let text = groups::text_metadata(&message.body)
                .map(|(text, _)| text)
                .unwrap_or_default()
                .to_lowercase();
            let unique = text
                .as_bytes()
                .windows(3)
                .map(|bytes| [bytes[0], bytes[1], bytes[2]])
                .collect::<HashSet<_>>();
            for gram in unique {
                self.grams.entry(gram).or_default().push(index as u32);
            }
            self.chats
                .entry(message.conversation_id.clone())
                .or_default()
                .push(index as u32);
            self.ids.insert(message.id.clone(), index as u32);
            self.texts.push(text);
        }
        self.last_id = messages.last().map(|message| message.id.clone());
    }

    fn find(&self, chat: &str, query: &str) -> Vec<usize> {
        let Some(chat_positions) = self.chats.get(chat) else {
            return Vec::new();
        };
        if let Some(id) = query.strip_prefix("id:") {
            return self
                .ids
                .get(id)
                .filter(|position| chat_positions.binary_search(position).is_ok())
                .map(|position| vec![*position as usize])
                .unwrap_or_default();
        }
        let terms = query.split_whitespace().collect::<Vec<_>>();
        let mut candidates = chat_positions;
        for term in &terms {
            for bytes in term.as_bytes().windows(3) {
                let Some(positions) = self.grams.get(&[bytes[0], bytes[1], bytes[2]]) else {
                    return Vec::new();
                };
                if positions.len() < candidates.len() {
                    candidates = positions;
                }
            }
        }
        candidates
            .iter()
            .filter(|position| chat_positions.binary_search(position).is_ok())
            .map(|position| *position as usize)
            .filter(|position| {
                terms
                    .iter()
                    .all(|term| self.texts[*position].contains(term))
            })
            .collect()
    }
}

static INDEX: OnceLock<Mutex<Index>> = OnceLock::new();

pub(super) fn search(id: &str, query: &str, offset: usize) -> CoreResult<Value> {
    validate_conversation_id(id)?;
    let query = query.trim().to_lowercase();
    if query.is_empty() || query.len() > 256 || offset > MAX_MESSAGES {
        return Err(CoreError::InvalidInput);
    }
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    ensure_messages_loaded(&mut store)?;
    let mut index = INDEX
        .get_or_init(|| Mutex::new(Index::default()))
        .lock()
        .map_err(|_| CoreError::Internal)?;
    index.update(&store.messages, store.generation);
    let mut positions = index.find(id, &query);
    if let Some(group) = store.groups.iter().find(|group| group.id == id) {
        positions.retain(|position| {
            !group.management.closed
                && !group
                    .management
                    .deleted_messages
                    .contains(&store.messages[*position].id)
        });
    }
    positions.sort_unstable_by(|left, right| {
        let left = &store.messages[*left];
        let right = &store.messages[*right];
        right
            .sent_at_ms
            .cmp(&left.sent_at_ms)
            .then_with(|| right.id.cmp(&left.id))
    });
    let total = positions.len();
    Ok(
        json!({"messages": positions.into_iter().skip(offset).take(50).map(|index| message_json(&store.messages[index], &store)).collect::<Vec<_>>(),
        "total": total, "has_more": total > offset.saturating_add(50)}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    fn message(id: &str, chat: &str, text: &str) -> StoredMessage {
        StoredMessage {
            id: id.to_owned(),
            conversation_id: chat.to_owned(),
            author_id: "me".to_owned(),
            body: text.to_owned(),
            sent_at_ms: 1,
            received_at_ms: 0,
            author_name: None,
            is_outgoing: true,
            is_read: true,
            delivery_state: "sent".to_owned(),
            attachment_name: None,
            attachment_base64: None,
        }
    }
    #[test]
    fn substring_index_handles_unicode_replies_append_deletion_and_account_switch() {
        let mut history = vec![
            message("1", "a", "Caffè #progetto @Luca"),
            message("2", "b", "Caffè segreto"),
        ];
        let mut index = Index::default();
        index.update(&history, 1);
        assert_eq!(index.find("a", "caffè @luca"), vec![0]);
        assert!(index.find("a", "segreto").is_empty());
        assert_eq!(index.find("a", "è"), vec![0]);
        history.push(message(
            "3",
            "a",
            &groups::encode_text("risposta unica", Some("1")).unwrap(),
        ));
        index.update(&history, 1);
        assert_eq!(index.find("a", "unica"), vec![2]);
        assert_eq!(index.find("a", "id:3"), vec![2]);
        assert!(index.find("b", "id:3").is_empty());
        history.remove(0);
        index.update(&history, 1);
        assert!(index.find("a", "progetto").is_empty());
        index.update(&[message("1", "a", "Nuovo account")], 2);
        assert!(index.find("a", "unica").is_empty());
        assert_eq!(index.find("a", "account"), vec![0]);
    }
    #[test]
    fn index_queries_a_large_history_without_changing_storage_limits() {
        let mut messages = (0..100_000)
            .map(|index| {
                message(
                    &index.to_string(),
                    "large",
                    "Messaggio ordinario del gruppo",
                )
            })
            .collect::<Vec<_>>();
        messages[76_543].body = "Obiettivo raro #rilascio".to_owned();
        let mut index = Index::default();
        index.update(&messages, 1);
        let start = std::time::Instant::now();
        for _ in 0..100 {
            assert_eq!(index.find("large", "raro #rilascio"), vec![76_543]);
        }
        eprintln!(
            "100 indexed queries / 100,000 synthetic messages: {:?}",
            start.elapsed()
        );
    }
}
