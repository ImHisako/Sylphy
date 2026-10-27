//! Sender-qualified references preserve legacy wire IDs without local clashes.
use super::*;

pub(super) fn qualified(author: &str, id: &str) -> String {
    if wire(id).len() > MAX_MESSAGE_ID_BYTES - 33 {
        return id.to_owned();
    }
    let namespace = if author.len() == 32 && author.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        author.to_owned()
    } else {
        compact_hex(&Sha256::digest(author.as_bytes())[..16])
    };
    format!("{namespace}-{}", wire(id))
}

pub(super) fn wire(id: &str) -> &str {
    match id.split_once('-') {
        Some((author, value))
            if author.len() == 32
                && !value.is_empty()
                && author.bytes().all(|byte| byte.is_ascii_hexdigit()) =>
        {
            value
        }
        _ => id,
    }
}

pub(super) fn reference(message: &StoredMessage) -> CoreResult<String> {
    let author = if message.is_outgoing {
        contact_id(&identity::active_identity()?.identity_public_key()?)
    } else {
        message.author_id.clone()
    };
    Ok(qualified(&author, &message.id))
}

pub(super) fn matches(message: &StoredMessage, target: &str) -> bool {
    if wire(&message.id) != wire(target) {
        return false;
    }
    if wire(target) == target {
        true
    } else {
        reference(message).is_ok_and(|id| id == target)
    }
}

pub(super) fn local_id(
    messages: &[StoredMessage],
    conversation: &str,
    target: &str,
) -> Option<String> {
    let mut found = messages
        .iter()
        .filter(|message| message.conversation_id == conversation && matches(message, target));
    let first = found.next()?;
    found.next().is_none().then(|| first.id.clone())
}

pub(super) fn incoming_id(messages: &[StoredMessage], author: &str, id: &str) -> String {
    if let Some(existing) = messages.iter().find(|message| {
        !message.is_outgoing && message.author_id == author && wire(&message.id) == wire(id)
    }) {
        return existing.id.clone();
    }
    if messages.iter().any(|message| message.id == id) {
        qualified(author, id)
    } else {
        id.to_owned()
    }
}

pub(super) fn encode_references(value: &mut Value) {
    match value {
        Value::Array(values) => {
            for value in values {
                encode_references(value);
            }
        }
        Value::Object(object) => {
            for value in object.values_mut() {
                encode_references(value);
            }
            for field in ["message_id", "reply_to"] {
                if let Some(id) = object.get(field).and_then(Value::as_str).map(str::to_owned) {
                    if wire(&id) != id {
                        object.insert(format!("qualified_{field}"), json!(id));
                        object.insert(field.to_owned(), json!(wire(&id)));
                    }
                }
            }
            for field in ["pinned", "deleted_messages"] {
                if let Some(values) = object.get(field).and_then(Value::as_array).cloned() {
                    if values
                        .iter()
                        .filter_map(Value::as_str)
                        .any(|id| wire(id) != id)
                    {
                        object.insert(format!("qualified_{field}"), Value::Array(values.clone()));
                        let legacy = values
                            .into_iter()
                            .map(|value| match value {
                                Value::String(id) => json!(wire(&id)),
                                other => other,
                            })
                            .collect();
                        object.insert(field.to_owned(), Value::Array(legacy));
                    }
                }
            }
        }
        _ => {}
    }
}

pub(super) fn decode_references(value: &mut Value) -> CoreResult<()> {
    match value {
        Value::Array(values) => {
            for value in values {
                decode_references(value)?;
            }
        }
        Value::Object(object) => {
            for field in ["message_id", "reply_to", "pinned", "deleted_messages"] {
                if let Some(qualified) = object.remove(&format!("qualified_{field}")) {
                    let original = object.get(field).ok_or(CoreError::InvalidInput)?;
                    let valid = match (&qualified, original) {
                        (Value::String(id), Value::String(old)) => {
                            wire(id) != id && wire(id) == old
                        }
                        (Value::Array(ids), Value::Array(old)) => {
                            ids.len() == old.len()
                                && ids.iter().zip(old).all(|(id, old)| {
                                    id.as_str()
                                        .zip(old.as_str())
                                        .is_some_and(|(id, old)| wire(id) == old)
                                })
                        }
                        _ => false,
                    };
                    if !valid {
                        return Err(CoreError::VerificationFailed);
                    }
                    object.insert(field.to_owned(), qualified);
                }
            }
            for value in object.values_mut() {
                decode_references(value)?;
            }
        }
        _ => {}
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn incoming(author: &str, id: &str) -> StoredMessage {
        let mut message = super::super::tests::history_message(1);
        message.is_outgoing = false;
        message.author_id = author.to_owned();
        message.id = id.to_owned();
        message
    }

    #[test]
    fn collisions_keep_both_authors_and_resolve_only_unambiguous_references() {
        let first = incoming("alice", "shared-id");
        let second_id = incoming_id(std::slice::from_ref(&first), "bob", "shared-id");
        assert_ne!(second_id, first.id);
        let second = incoming("bob", &second_id);
        let messages = vec![first, second];
        assert_eq!(incoming_id(&messages, "alice", "shared-id"), "shared-id");
        assert_eq!(incoming_id(&messages, "bob", "shared-id"), second_id);
        assert!(local_id(&messages, "chat", "shared-id").is_none());
        for message in &messages {
            assert_eq!(
                local_id(&messages, "chat", &reference(message).unwrap()),
                Some(message.id.clone())
            );
        }
    }

    #[test]
    fn scoped_metadata_keeps_legacy_fields_and_round_trips_nested_controls() {
        let scoped = qualified("alice", "shared-id");
        let original = json!({"action":{"message_id":scoped}, "reply_to":scoped,
            "management":{"pinned":[scoped,"legacy"],"deleted_messages":[scoped]}});
        let mut encoded = original.clone();
        encode_references(&mut encoded);
        assert_eq!(encoded["action"]["message_id"], "shared-id");
        assert_eq!(encoded["reply_to"], "shared-id");
        assert_eq!(
            encoded["management"]["pinned"],
            json!(["shared-id", "legacy"])
        );
        decode_references(&mut encoded).unwrap();
        assert_eq!(encoded, original);
        let mut forged = json!({"message_id":"different", "qualified_message_id":scoped});
        assert!(decode_references(&mut forged).is_err());
        let mut forged = json!({"pinned":["different"],"qualified_pinned":[scoped]});
        assert!(decode_references(&mut forged).is_err());
        let mut legacy = json!({"message_id":"legacy", "pinned":["legacy"]});
        let original = legacy.clone();
        encode_references(&mut legacy);
        decode_references(&mut legacy).unwrap();
        assert_eq!(legacy, original);
        let long_legacy = "x".repeat(MAX_MESSAGE_ID_BYTES);
        assert_eq!(qualified("alice", &long_legacy), long_legacy);
    }
}
