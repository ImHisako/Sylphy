//! Authenticated group administration. The owner serializes delegated commands;
//! snapshots are accepted only from that owner, never from an arbitrary member.
use super::*;

const CONTROL: &str = "sylphy-group-control-v1:";
const INLINE_CONTROL: &str = "sylphy-group-control-v2:";
const RICH: &str = "sylphy-group-text-v1:";
const MAX_CONTROLS: usize = 512;

#[cfg(all(test, feature = "signal-ratchet"))]
#[path = "groups_tests.rs"]
mod tests;

pub(super) fn is_control(body: &str) -> bool {
    body.starts_with(CONTROL) || body.starts_with(INLINE_CONTROL)
}

#[cfg(all(test, feature = "signal-ratchet"))]
std::thread_local! { static TEST_BLOBS: std::cell::RefCell<Option<HashMap<String, Vec<u8>>>> = const { std::cell::RefCell::new(None) }; }

fn publish_bytes(bytes: &[u8]) -> CoreResult<(String, u16)> {
    #[cfg(all(test, feature = "signal-ratchet"))]
    if let Some(result) = TEST_BLOBS.with(|storage| {
        storage.borrow_mut().as_mut().map(|storage| {
            let key = new_id();
            storage.insert(key.clone(), bytes.to_vec());
            (key, 1)
        })
    }) {
        return Ok(result);
    }
    veilid_adapter::publish_attachment_blob(bytes)
}

fn fetch_bytes(key: &str, chunks: u16) -> CoreResult<Vec<u8>> {
    #[cfg(all(test, feature = "signal-ratchet"))]
    if let Some(result) = TEST_BLOBS.with(|storage| {
        storage.borrow().as_ref().map(|storage| {
            storage
                .get(key)
                .cloned()
                .ok_or(CoreError::FeatureUnavailable)
        })
    }) {
        return result;
    }
    veilid_adapter::fetch_attachment_blob(key, chunks)
}

fn local_endpoint() -> CoreResult<PublishedIdentity> {
    #[cfg(all(test, feature = "signal-ratchet"))]
    if TEST_BLOBS.with(|storage| storage.borrow().is_some()) {
        let local = identity::active_identity()?;
        return PublishedIdentity::new(
            &local.signing_key()?,
            local.public_bundle(ratchet_adapter::public_pre_key_bundle()?)?,
            vec![1; 512],
            crate::peer_identity::PublicProfile {
                display_name: Some("Test owner".to_owned()),
                avatar_base64: None,
            },
            None,
        );
    }
    local_published_identity()
}

fn seal_endpoint(
    recipient: &PublishedIdentity,
    body: &str,
) -> CoreResult<(Vec<secure_packet::SealedDelivery>, String)> {
    #[cfg(all(test, feature = "signal-ratchet"))]
    if TEST_BLOBS.with(|storage| storage.borrow().is_some()) {
        let mut id = [0; 16];
        OsRng.fill_bytes(&mut id);
        let mut deliveries = Vec::new();
        for device in recipient.delivery_devices()? {
            let (payload, _) = secure_packet::seal_for_test_with_id(&device, body, &id)?;
            deliveries.push(secure_packet::SealedDelivery {
                payload,
                route_blob: device.route_blob,
                offline_keys: None,
            });
        }
        return Ok((deliveries, compact_hex(&id)));
    }
    secure_packet::seal_for_all(recipient, body)
}

fn yes() -> bool {
    true
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Policy {
    #[serde(default = "yes")]
    pub send_messages: bool,
    #[serde(default = "yes")]
    pub send_media: bool,
    #[serde(default = "yes")]
    pub send_links: bool,
    #[serde(default)]
    pub slow_mode_seconds: u32,
    #[serde(default)]
    pub aggressive_antispam: bool,
}
impl Default for Policy {
    fn default() -> Self {
        Self {
            send_messages: true,
            send_media: true,
            send_links: true,
            slow_mode_seconds: 0,
            aggressive_antispam: false,
        }
    }
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct AdminPermissions {
    pub delete_messages: bool,
    pub manage_members: bool,
    pub change_info: bool,
    pub invite_members: bool,
    pub add_admins: bool,
    pub pin_messages: bool,
    pub manage_permissions: bool,
}
impl AdminPermissions {
    fn all() -> Self {
        Self {
            delete_messages: true,
            manage_members: true,
            change_info: true,
            invite_members: true,
            add_admins: true,
            pin_messages: true,
            manage_permissions: true,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Management {
    #[serde(default = "yes")]
    pub show_action_notices: bool,
    #[serde(default)]
    pub channels: Vec<GroupChannel>,
    #[serde(default)]
    pub deleted_channels: HashSet<String>,
    pub revision: u64,
    pub policy: Policy,
    pub admins: HashMap<String, AdminPermissions>,
    pub restrictions: HashMap<String, Policy>,
    pub pinned: Vec<String>,
    pub deleted_messages: HashSet<String>,
    pub closed: bool,
    #[serde(default)]
    invite: Option<Invite>,
    #[serde(default)]
    pub invite_generation: u64,
    #[serde(default)]
    shared_invite: Option<(u64, String)>,
    #[serde(default)]
    pub coordinator: Option<PublishedIdentity>,
    #[serde(default)]
    pub removed: bool,
    /// Durable opt-out. Only a new, explicit join may clear this tombstone.
    #[serde(default)]
    pub left: bool,
    #[serde(default)]
    pending_departure: Option<Departure>,
    #[serde(default)]
    departed: HashSet<String>,
    #[serde(default)]
    requests: Vec<Request>,
    #[serde(default)]
    processed: HashSet<String>,
    // Stored atomically with the state. Transferred to the normal outbox only
    // after persistence, so a crash cannot publish an uncommitted mutation.
    #[serde(default)]
    outbound: Vec<PendingDelivery>,
    #[serde(default)]
    pending_effect: Option<Effect>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct GroupChannel {
    pub id: String,
    pub name: String,
}

impl Default for Management {
    fn default() -> Self {
        serde_json::from_value(json!({
            "revision": 0, "policy": Policy::default(), "admins": {},
            "restrictions": {}, "pinned": [], "deleted_messages": [], "closed": false
        }))
        .expect("valid default group management")
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct Effect {
    notice: String,
    event_id: String,
    outgoing: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct Departure {
    event_id: String,
    successor: Option<String>,
}

impl Management {
    pub(super) fn new(coordinator: PublishedIdentity) -> Self {
        Self {
            coordinator: Some(coordinator),
            ..Self::default()
        }
    }
}

pub(super) fn preserve_local_queues(existing: &StoredGroup, incoming: &mut StoredGroup) {
    incoming.management.left |= existing.management.left;
    if incoming.management.left {
        incoming.management.removed = true;
        incoming.management.pending_effect = None;
    }
    incoming.management.pending_departure = existing
        .management
        .pending_departure
        .clone()
        .or(incoming.management.pending_departure.clone());
    incoming
        .management
        .departed
        .extend(existing.management.departed.iter().cloned());
    incoming
        .members
        .retain(|member| !incoming.management.departed.contains(&member.id));
    incoming.management.outbound = existing.management.outbound.clone();
    incoming.management.requests = existing.management.requests.clone();
    incoming.management.processed = existing.management.processed.clone();
    if incoming.management.coordinator.is_none() {
        incoming.management.coordinator = existing.management.coordinator.clone();
    }
    if !incoming.management.left
        && (existing.management.closed != incoming.management.closed
            || existing.management.deleted_messages != incoming.management.deleted_messages
            || existing.management.deleted_channels != incoming.management.deleted_channels)
    {
        incoming.management.pending_effect = Some(Effect {
            notice: "Moderazione del gruppo sincronizzata".to_owned(),
            event_id: new_id(),
            outgoing: false,
        });
    }
    if incoming.management.left {
        incoming.management.requests.clear();
        // A departure may already be sealed and persisted but not yet moved to
        // the transport outbox. Do not discard it when an old snapshot arrives.
        if !existing.management.left {
            incoming.management.outbound.clear();
        }
        incoming.management.pinned.clear();
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct Invite {
    code: String,
    token: String,
    expires_at_ms: u64,
}
#[derive(Deserialize, Serialize)]
struct JoinLink {
    version: u8,
    group_id: String,
    owner: PublishedIdentity,
    token: String,
    expires_at_ms: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Action {
    ActionNotices {
        enabled: bool,
    },
    CreateChannel {
        name: String,
    },
    RenameChannel {
        channel_id: String,
        name: String,
    },
    DeleteChannel {
        channel_id: String,
    },
    MoveChannel {
        channel_id: String,
        before_channel_id: Option<String>,
    },
    Info {
        name: String,
        description: String,
    },
    Policy {
        policy: Policy,
    },
    AddMembers {
        invitation_codes: Vec<String>,
    },
    RemoveMember {
        member_id: String,
    },
    SetAdmin {
        member_id: String,
        permissions: Option<AdminPermissions>,
    },
    Restrict {
        member_id: String,
        policy: Option<Policy>,
    },
    Pin {
        message_id: String,
        pinned: bool,
    },
    DeleteMessage {
        message_id: String,
    },
    Close,
    InviteLink,
    RevokeInviteLink,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct Request {
    id: String,
    actor: String,
    action: Action,
    #[serde(default)]
    candidate: Option<GroupMember>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum Control {
    Departure {
        group_id: String,
        departure: Departure,
    },
    Request {
        group_id: String,
        request: Request,
    },
    Snapshot {
        group: StoredGroup,
        notice: String,
        event_id: String,
    },
    Join {
        group_id: String,
        token: String,
        request_id: String,
    },
    Invite {
        group_id: String,
        generation: u64,
        code: String,
    },
    Rejected {
        group_id: String,
        request_id: String,
    },
}

#[derive(Deserialize, Serialize)]
struct RichText {
    version: u8,
    text: String,
    reply_to: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    channel_id: Option<String>,
}

pub(super) fn new_id() -> String {
    let mut bytes = [0; 16];
    OsRng.fill_bytes(&mut bytes);
    compact_hex(&bytes)
}
fn local_id() -> CoreResult<String> {
    Ok(contact_id(
        &identity::active_identity()?.identity_public_key()?,
    ))
}
fn owner_id(group: &StoredGroup) -> CoreResult<String> {
    if group.admin_id == "me" {
        local_id()
    } else {
        Ok(group.admin_id.clone())
    }
}
fn is_coordinator(group: &StoredGroup) -> CoreResult<bool> {
    if owner_id(group)? != local_id()? {
        return Ok(false);
    }
    let active = ratchet_adapter::public_pre_key_bundle()?.ok_or(CoreError::FeatureUnavailable)?;
    Ok(group
        .management
        .coordinator
        .as_ref()
        .is_none_or(|identity| {
            identity
                .bundle
                .signal_pre_key
                .as_ref()
                .is_some_and(|key| key.identity_key == active.identity_key)
        }))
}
fn permissions(group: &StoredGroup, actor: &str) -> CoreResult<AdminPermissions> {
    if actor == owner_id(group)? {
        return Ok(AdminPermissions::all());
    }
    Ok(group
        .management
        .admins
        .get(actor)
        .cloned()
        .unwrap_or_default())
}

pub(super) fn is_admin(group: &StoredGroup) -> CoreResult<bool> {
    let local = local_id()?;
    Ok(local == owner_id(group)? || group.management.admins.contains_key(&local))
}
fn participant(group: &StoredGroup, actor: &str) -> CoreResult<bool> {
    Ok(actor == owner_id(group)?
        || group.members.iter().any(|member| member.id == actor)
        || (actor == local_id()? && !group.management.removed))
}
fn authorized(group: &StoredGroup, actor: &str, action: &Action) -> CoreResult<()> {
    if group.management.closed || group.management.removed {
        return Err(CoreError::GroupClosed);
    }
    if !participant(group, actor)? {
        return Err(CoreError::GroupPermissionDenied);
    }
    let rights = permissions(group, actor)?;
    let permitted = match action {
        Action::ActionNotices { .. } => rights.manage_permissions,
        Action::CreateChannel { .. }
        | Action::RenameChannel { .. }
        | Action::MoveChannel { .. } => rights.change_info,
        Action::DeleteChannel { .. } => rights.change_info && rights.delete_messages,
        Action::Info { .. } => rights.change_info,
        Action::Policy { .. } => rights.manage_permissions,
        Action::AddMembers { .. } => rights.invite_members,
        Action::RemoveMember { member_id } => {
            rights.manage_members
                && *member_id != owner_id(group)?
                && (!group.management.admins.contains_key(member_id) || actor == owner_id(group)?)
        }
        Action::Restrict { member_id, .. } => {
            rights.manage_members
                && *member_id != owner_id(group)?
                && !group.management.admins.contains_key(member_id)
        }
        Action::SetAdmin {
            member_id,
            permissions: requested,
        } => {
            // Delegation cannot create privileges the grantor does not possess.
            let requested = requested.clone().unwrap_or_default();
            rights.add_admins
                && *member_id != owner_id(group)?
                && (actor == owner_id(group)?
                    || (!group.management.admins.contains_key(member_id)
                        && (!requested.delete_messages || rights.delete_messages)
                        && (!requested.manage_members || rights.manage_members)
                        && (!requested.change_info || rights.change_info)
                        && (!requested.invite_members || rights.invite_members)
                        && (!requested.add_admins || rights.add_admins)
                        && (!requested.pin_messages || rights.pin_messages)
                        && (!requested.manage_permissions || rights.manage_permissions)))
        }
        Action::Pin { .. } => rights.pin_messages,
        Action::DeleteMessage { .. } => rights.delete_messages,
        Action::Close => actor == owner_id(group)?,
        Action::InviteLink | Action::RevokeInviteLink => rights.invite_members,
    };
    if permitted {
        Ok(())
    } else {
        Err(CoreError::GroupPermissionDenied)
    }
}

pub(super) fn validate(group: &StoredGroup) -> CoreResult<()> {
    let value = &group.management;
    if let Some(coordinator) = &value.coordinator {
        coordinator.validate()?;
        if group.admin_id != "me"
            && contact_id(&coordinator.bundle.identity_ed25519) != group.admin_id
        {
            return Err(CoreError::VerificationFailed);
        }
    }
    if value.channels.len() > 50 {
        return Err(CoreError::LimitExceeded);
    }
    let mut channel_ids = HashSet::new();
    let mut channel_names = HashSet::new();
    for channel in &value.channels {
        validate_conversation_id(&channel.id)?;
        validate_display_name(&channel.name)?;
        if value.deleted_channels.contains(&channel.id)
            || !channel_ids.insert(&channel.id)
            || !channel_names.insert(channel.name.to_lowercase())
        {
            return Err(CoreError::InvalidInput);
        }
    }
    if value.policy.slow_mode_seconds > 3600
        || value.admins.len() > MAX_GROUP_MEMBERS
        || value.restrictions.len() > MAX_GROUP_MEMBERS
        || value.pinned.len() > 50
        || value.deleted_messages.len() > MAX_MESSAGES
        || value.deleted_channels.len() > 4096
        || value.requests.len() > MAX_CONTROLS
        || value.processed.len() > 4096
        || value.outbound.len() > MAX_OUTBOX_DELIVERIES
    {
        return Err(CoreError::LimitExceeded);
    }
    for (id, policy) in &value.restrictions {
        validate_conversation_id(id)?;
        if policy.slow_mode_seconds > 3600 {
            return Err(CoreError::LimitExceeded);
        }
    }
    for id in value
        .admins
        .keys()
        .chain(value.pinned.iter())
        .chain(value.deleted_messages.iter())
        .chain(value.deleted_channels.iter())
        .chain(value.departed.iter())
    {
        validate_conversation_id(id)?;
    }
    if let Some(departure) = &value.pending_departure {
        if !value.left {
            return Err(CoreError::InvalidInput);
        }
        validate_conversation_id(&departure.event_id)?;
        if let Some(successor) = &departure.successor {
            validate_conversation_id(successor)?;
        }
    }
    Ok(())
}

pub(super) fn require_updated(group: &StoredGroup) -> CoreResult<()> {
    if !group.management.deleted_channels.is_empty() {
        require_channel_management(group)?;
    }
    if !group.management.channels.is_empty() {
        require_channels(group)?;
    }
    for member in &group.members {
        if member.identity.delivery_devices()?.iter().any(|device| {
            !device
                .bundle
                .capabilities
                .iter()
                .any(|capability| capability == "group-management-v1")
        }) {
            return Err(CoreError::UnsupportedVersion);
        }
    }
    Ok(())
}

pub fn details(id: &str) -> CoreResult<Value> {
    // Settings are a local read: do not refresh endpoints or persist contacts.
    let group = contact_store()
        .lock()
        .map_err(|_| CoreError::Internal)?
        .groups
        .iter()
        .find(|group| group.id == id && !group.management.left)
        .cloned()
        .ok_or(CoreError::InvalidInput)?;
    let local = local_id()?;
    let owner = owner_id(&group)?;
    let mut members = group
        .members
        .iter()
        .map(|member| {
            json!({
                "id": member.id, "name": member.display_name, "is_owner": member.id == owner,
                "permissions": group.management.admins.get(&member.id),
                "is_admin": member.id == owner || group.management.admins.contains_key(&member.id),
                "restriction": group.management.restrictions.get(&member.id),
            })
        })
        .collect::<Vec<_>>();
    if !group.management.removed {
        members.push(
            json!({"id": local, "name": "Tu", "is_owner": local == owner,
        "permissions": group.management.admins.get(&local),
        "is_admin": local == owner || group.management.admins.contains_key(&local),
        "restriction": group.management.restrictions.get(&local)}),
        );
    }
    Ok(
        json!({"id": group.id, "name": group.name, "description": group.description,
        "revision": group.management.revision, "policy": group.management.policy,
        "permissions": permissions(&group, &local)?, "is_owner": local == owner,
        "members": members, "pinned": group.management.pinned,
        "show_action_notices": group.management.show_action_notices,
        "channels": group.management.channels,
        "pending_actions": group.management.requests.iter().filter(|request| request.actor == local).map(|request| &request.action).collect::<Vec<_>>(),
        "closed": group.management.closed || group.management.removed,
        "can_send": can_write(&group)?, "pending_requests": group.management.requests.len(),
        "invite_link": if permissions(&group, &local)?.invite_members {
            group.management.invite.as_ref().map(|invite| invite.code.clone()).or_else(||
                group.management.shared_invite.as_ref().filter(|(generation, _)| *generation == group.management.invite_generation).map(|(_, code)| code.clone()))
        } else { None }}),
    )
}

pub(super) fn can_write(group: &StoredGroup) -> CoreResult<bool> {
    let local = local_id()?;
    Ok(!group.management.closed
        && !group.management.removed
        && (local == owner_id(group)?
            || group.management.admins.contains_key(&local)
            || (group.management.policy.send_messages
                && group
                    .management
                    .restrictions
                    .get(&local)
                    .is_none_or(|policy| policy.send_messages))))
}

pub(super) fn enforce(group: &StoredGroup, actor: &str, text: &str, media: bool) -> CoreResult<()> {
    enforce_with(group, actor, text, media, false)
}

pub(super) fn enforce_inbound(
    group: &StoredGroup,
    actor: &str,
    text: &str,
    media: bool,
) -> CoreResult<()> {
    enforce_with(group, actor, text, media, true)
}

fn enforce_with(
    group: &StoredGroup,
    actor: &str,
    text: &str,
    media: bool,
    inbound: bool,
) -> CoreResult<()> {
    if group.management.closed || group.management.removed {
        return Err(CoreError::GroupClosed);
    }
    if !participant(group, actor)? {
        return Err(CoreError::GroupPermissionDenied);
    }
    if actor == owner_id(group)? || group.management.admins.contains_key(actor) {
        return Ok(());
    }
    let base = &group.management.policy;
    let restriction = group
        .management
        .restrictions
        .get(actor)
        .cloned()
        .unwrap_or_default();
    let has_link = !media && contains_link(text);
    if !base.send_messages
        || !restriction.send_messages
        || (media && (!base.send_media || !restriction.send_media))
        || (has_link && (!base.send_links || !restriction.send_links))
    {
        return Err(CoreError::GroupPermissionDenied);
    }
    // Content violations remain permanent. Timing alone cannot establish
    // abuse: a legitimate offline backlog can arrive in a single batch.
    if base.aggressive_antispam && text.matches('@').count() > 5 {
        return Err(CoreError::SpamRejected);
    }
    let now = current_time_ms()?;
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    ensure_messages_loaded(&mut store)?;
    let local = local_id()?;
    let recent = store
        .messages
        .iter()
        .rev()
        .filter(|message| {
            message.conversation_id == group.id
                && (message.author_id == actor || (actor == local && message.is_outgoing))
        })
        .take(12)
        .collect::<Vec<_>>();
    let slow = u64::from(base.slow_mode_seconds.max(restriction.slow_mode_seconds)) * 1000;
    let observed_at = |message: &&StoredMessage| {
        if message.received_at_ms == 0 {
            message.sent_at_ms
        } else {
            message.received_at_ms
        }
    };
    if slow > 0
        && recent
            .iter()
            .any(|message| now < observed_at(message).saturating_add(slow))
    {
        return Err(if inbound {
            CoreError::InboundDeferred
        } else {
            CoreError::SlowModeActive
        });
    }
    if base.aggressive_antispam
        && (recent
            .iter()
            .filter(|message| now.saturating_sub(observed_at(message)) < 10_000)
            .count()
            >= 5
            || recent.iter().any(|message| {
                now.saturating_sub(observed_at(message)) < 60_000
                    && !media
                    && text_metadata(&message.body)
                        .is_ok_and(|(body, _)| body.eq_ignore_ascii_case(text))
            }))
    {
        return Err(if inbound {
            CoreError::InboundDeferred
        } else {
            CoreError::SpamRejected
        });
    }
    Ok(())
}

fn contains_link(text: &str) -> bool {
    // Ignore invisible separators commonly inserted to evade moderation.
    let normalized: String = text
        .chars()
        .filter(|c| {
            !matches!(
                c,
                '\u{200b}' | '\u{200c}' | '\u{200d}' | '\u{2060}' | '\u{feff}'
            )
        })
        .collect();
    let lower = normalized.to_lowercase();
    if lower.contains("://")
        || lower.contains("mailto:")
        || lower.contains("sylphy:")
        || lower.contains("sylphy-group-join-v1:")
    {
        return true;
    }
    lower
        .split(|c: char| !(c.is_alphanumeric() || matches!(c, '-' | '.')))
        .any(|host| {
            let host = host.trim_matches('.');
            if host.parse::<std::net::Ipv4Addr>().is_ok() {
                return true;
            }
            host.rsplit_once('.').is_some_and(|(name, tld)| {
                !name.is_empty()
                    && ((2..=63).contains(&tld.chars().count())
                        && tld.chars().all(char::is_alphabetic)
                        || tld.starts_with("xn--") && tld.len() > 4)
                    && name.split('.').all(|label| {
                        !label.is_empty() && !label.starts_with('-') && !label.ends_with('-')
                    })
            })
        })
}
fn already_applied(group: &StoredGroup, action: &Action) -> bool {
    match action {
        Action::DeleteChannel { channel_id } => {
            group.management.deleted_channels.contains(channel_id)
        }
        Action::DeleteMessage { message_id } => {
            group.management.deleted_messages.contains(message_id)
        }
        Action::Pin { message_id, pinned } => {
            group.management.pinned.contains(message_id) == *pinned
        }
        Action::ActionNotices { enabled } => group.management.show_action_notices == *enabled,
        _ => false,
    }
}

pub fn act(id: &str, action: Action) -> CoreResult<Value> {
    let group = current_group(id)?.ok_or(CoreError::InvalidInput)?;
    let local = local_id()?;
    authorized(&group, &local, &action)?;
    require_updated(&group)?;
    if matches!(
        action,
        Action::DeleteChannel { .. } | Action::MoveChannel { .. }
    ) {
        require_channel_management(&group)?;
    }
    if already_applied(&group, &action) {
        return Ok(json!({"state": "applied"}));
    }
    if group.management.requests.iter().any(|request| {
        request.actor == local
            && serde_json::to_value(&request.action).ok() == serde_json::to_value(&action).ok()
    }) {
        return Ok(json!({"state": "pending_owner"}));
    }
    if group.management.requests.len() >= MAX_CONTROLS {
        return Err(CoreError::StorageFull);
    }
    let request = Request {
        id: new_id(),
        actor: local.clone(),
        action,
        candidate: None,
    };
    if is_coordinator(&group)? {
        apply_request(group, &request)?;
        Ok(json!({"state": "applied"}))
    } else {
        let owner = if let Some(member) = group
            .members
            .iter()
            .find(|member| member.id == group.admin_id)
        {
            member.clone()
        } else {
            group_member(
                group
                    .management
                    .coordinator
                    .clone()
                    .ok_or(CoreError::VerificationFailed)?,
            )?
        };
        let control = Control::Request {
            group_id: id.to_owned(),
            request: request.clone(),
        };
        let deliveries = seal_control(&control, std::slice::from_ref(&owner))?;
        let mut group = group;
        group.management.outbound.extend(deliveries);
        group.management.requests.push(request);
        save(group)?;
        transfer_outbound()?;
        Ok(json!({"state": "pending_owner"}))
    }
}

fn apply_request(mut group: StoredGroup, request: &Request) -> CoreResult<()> {
    if group.management.processed.contains(&request.id) {
        return Ok(());
    }
    authorized(&group, &request.actor, &request.action)?;
    require_updated(&group)?;
    group.management.coordinator = Some(local_endpoint()?);
    if group.management.processed.len() >= 4096 {
        return Err(CoreError::StorageFull);
    }
    let mut recipients = group.members.clone();
    let mut private_invite = None;
    let no_change = already_applied(&group, &request.action);
    let notice = match &request.action {
        Action::ActionNotices { enabled } => {
            group.management.show_action_notices = *enabled;
            "Avvisi delle azioni aggiornati"
        }
        Action::CreateChannel { name } => {
            require_channels(&group)?;
            group.management.channels.push(GroupChannel {
                id: new_id(),
                name: validate_display_name(name)?,
            });
            "Un canale è stato creato"
        }
        Action::RenameChannel { channel_id, name } => {
            require_channels(&group)?;
            let channel = group
                .management
                .channels
                .iter_mut()
                .find(|channel| channel.id == *channel_id)
                .ok_or(CoreError::InvalidInput)?;
            channel.name = validate_display_name(name)?;
            "Un canale è stato rinominato"
        }
        Action::DeleteChannel { channel_id } => {
            require_channel_management(&group)?;
            if !no_change {
                let position = group
                    .management
                    .channels
                    .iter()
                    .position(|channel| channel.id == *channel_id)
                    .ok_or(CoreError::InvalidInput)?;
                group.management.channels.remove(position);
                group.management.deleted_channels.insert(channel_id.clone());
                // Pins and channel history disappear together on every device.
                let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
                ensure_messages_loaded(&mut store)?;
                let deleted = store
                    .messages
                    .iter()
                    .filter(|message| {
                        message.conversation_id == group.id && message_deleted(&group, message)
                    })
                    .map(|message| message.id.as_str())
                    .collect::<HashSet<_>>();
                group
                    .management
                    .pinned
                    .retain(|id| !deleted.contains(id.as_str()));
            }
            "Un canale è stato eliminato"
        }
        Action::MoveChannel {
            channel_id,
            before_channel_id,
        } => {
            require_channel_management(&group)?;
            let position = group
                .management
                .channels
                .iter()
                .position(|channel| channel.id == *channel_id)
                .ok_or(CoreError::InvalidInput)?;
            if before_channel_id.as_ref() != Some(channel_id) {
                let channel = group.management.channels.remove(position);
                let destination = match before_channel_id {
                    Some(id) => group
                        .management
                        .channels
                        .iter()
                        .position(|channel| channel.id == *id)
                        .ok_or(CoreError::InvalidInput)?,
                    None => group.management.channels.len(),
                };
                group.management.channels.insert(destination, channel);
            }
            "Ordine dei canali aggiornato"
        }
        Action::Info { name, description } => {
            group.name = validate_display_name(name)?;
            group.description = description.trim().to_owned();
            "Informazioni del gruppo aggiornate"
        }
        Action::Policy { policy } => {
            group.management.policy = policy.clone();
            "Permessi del gruppo aggiornati"
        }
        Action::AddMembers { invitation_codes } => {
            if (invitation_codes.is_empty() && request.candidate.is_none())
                || group.members.len()
                    + invitation_codes.len()
                    + usize::from(request.candidate.is_some())
                    > MAX_GROUP_MEMBERS
            {
                return Err(CoreError::LimitExceeded);
            }
            if let Some(candidate) = &request.candidate {
                if group.members.iter().any(|member| member.id == candidate.id)
                    || candidate.id == local_id()?
                {
                    return Err(CoreError::InvalidInput);
                }
                group.members.push(candidate.clone());
                group.management.departed.remove(&candidate.id);
                recipients.push(candidate.clone());
            }
            for code in invitation_codes {
                let (_, identity) = decode_invitation(code)?;
                let mut member = group_member(identity.ok_or(CoreError::VerificationFailed)?)?;
                if member.id == local_id()?
                    || group
                        .members
                        .iter()
                        .any(|existing| existing.id == member.id)
                {
                    return Err(CoreError::InvalidInput);
                }
                member.invitation_code = Some(code.trim().to_owned());
                group.management.departed.remove(&member.id);
                group.members.push(member.clone());
                recipients.push(member);
            }
            require_updated(&group)?;
            "Nuovi membri aggiunti al gruppo"
        }
        Action::RemoveMember { member_id } => {
            if !group.members.iter().any(|member| member.id == *member_id) {
                return Err(CoreError::InvalidInput);
            }
            group.members.retain(|member| member.id != *member_id);
            group.management.admins.remove(member_id);
            group.management.restrictions.remove(member_id);
            group.management.departed.insert(member_id.clone());
            "Un membro è stato rimosso dal gruppo"
        }
        Action::SetAdmin {
            member_id,
            permissions,
        } => {
            if !group.members.iter().any(|member| member.id == *member_id) {
                return Err(CoreError::InvalidInput);
            }
            if let Some(permissions) = permissions {
                group
                    .management
                    .admins
                    .insert(member_id.clone(), permissions.clone());
            } else {
                group.management.admins.remove(member_id);
            }
            "Ruoli degli amministratori aggiornati"
        }
        Action::Restrict { member_id, policy } => {
            if !group.members.iter().any(|member| member.id == *member_id) {
                return Err(CoreError::InvalidInput);
            }
            if let Some(policy) = policy {
                group
                    .management
                    .restrictions
                    .insert(member_id.clone(), policy.clone());
            } else {
                group.management.restrictions.remove(member_id);
            }
            "Restrizioni di un membro aggiornate"
        }
        Action::Pin { message_id, pinned } => {
            let store = contact_store().lock().map_err(|_| CoreError::Internal)?;
            if !store
                .messages
                .iter()
                .any(|message| message.id == *message_id && message.conversation_id == group.id)
                || group.management.deleted_messages.contains(message_id)
            {
                return Err(CoreError::InvalidInput);
            }
            group.management.pinned.retain(|id| id != message_id);
            if *pinned {
                group.management.pinned.push(message_id.clone());
            }
            if *pinned {
                "Un messaggio è stato fissato nel gruppo"
            } else {
                "Un messaggio è stato rimosso dai fissati"
            }
        }
        Action::DeleteMessage { message_id } => {
            validate_conversation_id(message_id)?;
            group.management.deleted_messages.insert(message_id.clone());
            group.management.pinned.retain(|id| id != message_id);
            "Un messaggio è stato eliminato per tutti"
        }
        Action::Close => {
            group.management.closed = true;
            "Il gruppo è stato eliminato dal proprietario"
        }
        Action::InviteLink => {
            let token = new_id();
            let link = JoinLink {
                version: 1,
                group_id: group.id.clone(),
                owner: local_endpoint()?,
                token: token.clone(),
                expires_at_ms: current_time_ms()?.saturating_add(ATTACHMENT_RETENTION_MS),
            };
            let pointer = publish_control_value(&link)?;
            let code = format!(
                "sylphy-group-join-v1:{}",
                STANDARD_NO_PAD
                    .encode(serde_json::to_vec(&pointer).map_err(|_| CoreError::Internal)?)
            );
            group.management.invite_generation = group
                .management
                .invite_generation
                .checked_add(1)
                .ok_or(CoreError::LimitExceeded)?;
            group.management.invite = Some(Invite {
                code: code.clone(),
                token,
                expires_at_ms: link.expires_at_ms,
            });
            private_invite = Some(code);
            "Un nuovo link di invito è stato creato"
        }
        Action::RevokeInviteLink => {
            group.management.invite = None;
            group.management.invite_generation = group
                .management
                .invite_generation
                .checked_add(1)
                .ok_or(CoreError::LimitExceeded)?;
            "Il link di invito è stato revocato"
        }
    }
    .to_owned();
    let notice = if no_change { String::new() } else { notice };
    group.management.revision = group
        .management
        .revision
        .checked_add(1)
        .ok_or(CoreError::LimitExceeded)?;
    group.management.processed.insert(request.id.clone());
    group
        .management
        .requests
        .retain(|pending| pending.id != request.id);
    validate(&group)?;
    let mut snapshot = group.clone();
    snapshot.admin_id = local_id()?;
    snapshot.members.push(group_member(local_endpoint()?)?);
    snapshot.management.outbound.clear();
    snapshot.management.requests.clear();
    snapshot.management.processed.clear();
    snapshot.management.pending_effect = None;
    snapshot.management.invite = None;
    snapshot.management.shared_invite = None;
    snapshot.management.left = false;
    snapshot.management.pending_departure = None;
    snapshot.management.departed.clear();
    let deliveries = seal_control(
        &Control::Snapshot {
            group: snapshot,
            notice: notice.clone(),
            event_id: request.id.clone(),
        },
        &recipients,
    )?;
    group.management.outbound.extend(deliveries);
    if let Some(code) = private_invite {
        if request.actor != local_id()? {
            let recipient = group
                .members
                .iter()
                .find(|member| member.id == request.actor)
                .ok_or(CoreError::InvalidInput)?;
            group.management.outbound.extend(seal_control(
                &Control::Invite {
                    group_id: group.id.clone(),
                    generation: group.management.invite_generation,
                    code,
                },
                std::slice::from_ref(recipient),
            )?);
        }
    }
    group.management.pending_effect = Some(Effect {
        notice: notice.clone(),
        event_id: request.id.clone(),
        outgoing: true,
    });
    save(group.clone())?;
    complete_effect(group.clone())?;
    transfer_outbound()?;
    group.management.outbound.clear();
    group.management.requests.clear();
    group.management.pending_effect = None;
    queue_device_sync(&DeviceSyncEvent::UpsertGroup { group });
    Ok(())
}

fn seal_control(control: &Control, recipients: &[GroupMember]) -> CoreResult<Vec<PendingDelivery>> {
    if recipients.is_empty() {
        return Ok(Vec::new());
    }
    let encoded = serde_json::to_vec(control).map_err(|_| CoreError::Internal)?;
    // Small requests need only the existing encrypted direct transport. Avoid
    // publishing and fetching a DHT attachment before the owner can apply them.
    if encoded.len() <= 4096
        && recipients.iter().all(|recipient| {
            recipient.identity.delivery_devices().is_ok_and(|devices| {
                devices.iter().all(|device| {
                    device
                        .bundle
                        .capabilities
                        .iter()
                        .any(|capability| capability == "group-control-inline-v2")
                })
            })
        })
    {
        let body = format!(
            "{INLINE_CONTROL}{}",
            String::from_utf8(encoded).map_err(|_| CoreError::Internal)?
        );
        let mut pending = Vec::new();
        for recipient in recipients {
            let (deliveries, id) = seal_endpoint(&recipient.identity, &body)?;
            for sealed in deliveries {
                pending.push(PendingDelivery {
                    id: new_id(),
                    message_id: id.clone(),
                    is_control: true,
                    route_blob: sealed.route_blob,
                    payload: sealed.payload,
                    offline_keys: sealed.offline_keys,
                    created_at_ms: current_time_ms()?,
                    attempts: 0,
                    next_attempt_ms: 0,
                });
            }
        }
        return Ok(pending);
    }
    if encoded.len() > MAX_ATTACHMENT_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let mut key = [0; 32];
    OsRng.fill_bytes(&mut key);
    let encrypted = vault::seal_with_key(&key, &encoded)?;
    let (record_key, chunk_count) = publish_bytes(&encrypted)?;
    let result = (|| {
        register_attachment_lease(&record_key, chunk_count)?;
        let pointer = GroupInvitationPointer {
            version: 1,
            size: encoded.len(),
            record_key: record_key.clone(),
            chunk_count,
            key_base64: STANDARD_NO_PAD.encode(key),
        };
        let body = format!(
            "{CONTROL}{}",
            STANDARD_NO_PAD.encode(serde_json::to_vec(&pointer).map_err(|_| CoreError::Internal)?)
        );
        let now = current_time_ms()?;
        let mut pending = Vec::new();
        for recipient in recipients {
            for sealed in seal_endpoint(&recipient.identity, &body)?.0 {
                pending.push(PendingDelivery {
                    id: new_id(),
                    message_id: new_id(),
                    is_control: true,
                    route_blob: sealed.route_blob,
                    payload: sealed.payload,
                    offline_keys: sealed.offline_keys,
                    created_at_ms: now,
                    attempts: 0,
                    next_attempt_ms: 0,
                });
            }
        }
        Ok(pending)
    })();
    if result.is_err() {
        let _ = veilid_adapter::delete_attachment_blob(&record_key, chunk_count);
        remove_attachment_lease(&record_key);
    }
    result
}

fn save(group: StoredGroup) -> CoreResult<()> {
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    let mut groups = store.groups.clone();
    if let Some(existing) = groups.iter_mut().find(|item| item.id == group.id) {
        *existing = group;
    } else {
        if groups.len() >= MAX_CONTACTS {
            return Err(CoreError::StorageFull);
        }
        groups.push(group);
    }
    persist_groups(
        store
            .groups_path
            .as_deref()
            .ok_or(CoreError::FeatureUnavailable)?,
        &groups,
    )?;
    store.groups = groups;
    store.revision = store.revision.wrapping_add(1);
    Ok(())
}

pub(super) fn transfer_outbound() -> CoreResult<()> {
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    let mut outbox = store.outbox.clone();
    for delivery in store
        .groups
        .iter()
        .flat_map(|group| &group.management.outbound)
    {
        if !outbox.iter().any(|existing| existing.id == delivery.id) {
            outbox.push(delivery.clone());
        }
    }
    if outbox.len() == store.outbox.len()
        && store
            .groups
            .iter()
            .all(|group| group.management.outbound.is_empty())
    {
        return Ok(());
    }
    if outbox.len() > MAX_OUTBOX_DELIVERIES {
        return Err(CoreError::StorageFull);
    }
    persist_outbox(
        store
            .outbox_path
            .as_deref()
            .ok_or(CoreError::FeatureUnavailable)?,
        &outbox,
    )?;
    store.outbox = outbox;
    let mut groups = store.groups.clone();
    for group in &mut groups {
        group.management.outbound.clear();
    }
    persist_groups(
        store
            .groups_path
            .as_deref()
            .ok_or(CoreError::FeatureUnavailable)?,
        &groups,
    )?;
    store.groups = groups;
    Ok(())
}

pub(super) fn prepare_leave(group: &mut StoredGroup) -> CoreResult<()> {
    if group.management.left {
        return Ok(());
    }
    let successor = if local_id()? == owner_id(group)? {
        group
            .members
            .iter()
            .min_by_key(|member| {
                (
                    !group.management.admins.contains_key(&member.id),
                    member.id.as_str(),
                )
            })
            .map(|member| member.id.clone())
    } else {
        None
    };
    group.management.left = true;
    group.management.removed = true;
    group.management.requests.clear();
    group.management.pending_effect = None;
    group.management.outbound.clear();
    group.management.pinned.clear();
    group.management.pending_departure = Some(Departure {
        event_id: new_id(),
        successor,
    });
    Ok(())
}

fn flush_departures() {
    let groups = contact_store()
        .lock()
        .map(|store| {
            store
                .groups
                .iter()
                .filter(|group| group.management.pending_departure.is_some())
                .cloned()
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    for mut group in groups {
        let departure = group.management.pending_departure.clone().unwrap();
        let control = Control::Departure {
            group_id: group.id.clone(),
            departure,
        };
        let Ok(deliveries) = seal_control(&control, &group.members) else {
            continue;
        };
        group.management.outbound.extend(deliveries);
        group.management.pending_departure = None;
        let _ = save(group);
    }
    let _ = transfer_outbound();
}

pub(super) fn process_requests() {
    flush_departures();
    let requests = match contact_store().lock() {
        Ok(store) => store
            .groups
            .iter()
            .filter(|group| is_coordinator(group).unwrap_or(false))
            .filter_map(|group| {
                group
                    .management
                    .requests
                    .first()
                    .map(|request| (group.clone(), request.clone()))
            })
            .take(2)
            .collect::<Vec<_>>(),
        Err(_) => return,
    };
    for (mut group, request) in requests {
        if let Err(error) = apply_request(group.clone(), &request) {
            if matches!(
                error,
                CoreError::GroupPermissionDenied
                    | CoreError::GroupClosed
                    | CoreError::InvalidInput
                    | CoreError::LimitExceeded
            ) {
                if let Some(recipient) = group
                    .members
                    .iter()
                    .find(|member| member.id == request.actor)
                {
                    let Ok(deliveries) = seal_control(
                        &Control::Rejected {
                            group_id: group.id.clone(),
                            request_id: request.id.clone(),
                        },
                        std::slice::from_ref(recipient),
                    ) else {
                        continue;
                    };
                    group.management.outbound.extend(deliveries);
                }
                group
                    .management
                    .requests
                    .retain(|item| item.id != request.id);
                let _ = save(group);
            }
        }
    }
    let _ = transfer_outbound();
    let effects = contact_store()
        .lock()
        .map(|store| {
            store
                .groups
                .iter()
                .filter(|group| group.management.pending_effect.is_some())
                .cloned()
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    for group in effects {
        let _ = complete_effect(group);
    }
}

fn complete_effect(mut group: StoredGroup) -> CoreResult<()> {
    if let Some(effect) = &group.management.pending_effect {
        apply_local_effects(&group, &effect.notice, &effect.event_id, effect.outgoing)?;
        group.management.pending_effect = None;
        save(group)?;
    }
    Ok(())
}

pub(super) fn receive<F>(
    body: &str,
    sender: &PublishedIdentity,
    fetch: F,
) -> CoreResult<Option<bool>>
where
    F: FnOnce(&str, u16) -> CoreResult<Vec<u8>>,
{
    if let Some(encoded) = body.strip_prefix(INLINE_CONTROL) {
        if encoded.len() > 4096 {
            return Err(CoreError::LimitExceeded);
        }
        let control: Control =
            serde_json::from_str(encoded).map_err(|_| CoreError::InvalidInput)?;
        return receive_control(control, sender).map(Some);
    }
    let Some(encoded) = body.strip_prefix(CONTROL) else {
        return Ok(None);
    };
    if encoded.len() > 2048 {
        return Err(CoreError::LimitExceeded);
    }
    let pointer: GroupInvitationPointer = serde_json::from_slice(
        &STANDARD_NO_PAD
            .decode(encoded)
            .map_err(|_| CoreError::InvalidInput)?,
    )
    .map_err(|_| CoreError::InvalidInput)?;
    let key: [u8; 32] = STANDARD_NO_PAD
        .decode(&pointer.key_base64)
        .map_err(|_| CoreError::InvalidInput)?
        .try_into()
        .map_err(|_| CoreError::InvalidInput)?;
    if pointer.version != 1
        || pointer.size == 0
        || pointer.size > MAX_ATTACHMENT_BYTES
        || pointer.chunk_count == 0
        || pointer.chunk_count > 64
        || pointer.record_key.len() > 256
    {
        return Err(CoreError::LimitExceeded);
    }
    let plaintext = vault::open_with_key(&key, &fetch(&pointer.record_key, pointer.chunk_count)?)?;
    if plaintext.len() != pointer.size {
        return Err(CoreError::VerificationFailed);
    }
    let control: Control =
        serde_json::from_slice(&plaintext).map_err(|_| CoreError::InvalidInput)?;
    receive_control(control, sender).map(Some)
}

fn receive_control(control: Control, sender: &PublishedIdentity) -> CoreResult<bool> {
    let sender_id = contact_id(&sender.bundle.identity_ed25519);
    let group_id = match &control {
        Control::Snapshot { group, .. } => &group.id,
        Control::Request { group_id, .. }
        | Control::Join { group_id, .. }
        | Control::Invite { group_id, .. }
        | Control::Rejected { group_id, .. }
        | Control::Departure { group_id, .. } => group_id,
    };
    if current_group(group_id)?.is_some_and(|group| group.management.left) {
        return Ok(false);
    }
    match control {
        Control::Departure {
            group_id,
            departure,
        } => {
            let mut group = current_group(&group_id)?.ok_or(CoreError::FeatureUnavailable)?;
            validate_conversation_id(&departure.event_id)?;
            if group.management.departed.contains(&sender_id) {
                return Ok(false);
            }
            let owner = owner_id(&group)?;
            if !group.members.iter().any(|member| member.id == sender_id) {
                return Err(CoreError::AuthenticationFailed);
            }
            if owner == sender_id {
                let successor = departure.successor.ok_or(CoreError::InvalidInput)?;
                let local = local_id()?;
                let endpoint = if successor == local {
                    local_endpoint()?
                } else {
                    group
                        .members
                        .iter()
                        .find(|member| member.id == successor && member.id != sender_id)
                        .map(|member| member.identity.clone())
                        .ok_or(CoreError::AuthenticationFailed)?
                };
                group.admin_id = if successor == local {
                    "me".to_owned()
                } else {
                    successor
                };
                group.management.coordinator = Some(endpoint);
                group.management.revision = group
                    .management
                    .revision
                    .checked_add(1)
                    .ok_or(CoreError::LimitExceeded)?;
                group.management.invite = None;
                group.management.shared_invite = None;
            } else {
                if departure.successor.is_some() {
                    return Err(CoreError::AuthenticationFailed);
                }
                if is_coordinator(&group)? {
                    group.management.revision = group
                        .management
                        .revision
                        .checked_add(1)
                        .ok_or(CoreError::LimitExceeded)?;
                }
            }
            group.members.retain(|member| member.id != sender_id);
            group.management.admins.remove(&sender_id);
            group.management.restrictions.remove(&sender_id);
            group.management.departed.insert(sender_id);
            save(group.clone())?;
            group.management.outbound.clear();
            group.management.requests.clear();
            group.management.pending_effect = None;
            queue_device_sync(&DeviceSyncEvent::UpsertGroup { group });
            Ok(true)
        }
        Control::Join {
            group_id,
            token,
            request_id,
        } => {
            let mut group = current_group(&group_id)?.ok_or(CoreError::GroupPermissionDenied)?;
            if !is_coordinator(&group)? || group.management.closed {
                return Err(CoreError::GroupClosed);
            }
            let invite = group
                .management
                .invite
                .as_ref()
                .ok_or(CoreError::GroupPermissionDenied)?;
            use subtle::ConstantTimeEq;
            if !bool::from(invite.token.as_bytes().ct_eq(token.as_bytes()))
                || invite.expires_at_ms < current_time_ms()?
            {
                return Err(CoreError::GroupPermissionDenied);
            }
            validate_conversation_id(&request_id)?;
            if group.management.processed.contains(&request_id)
                || group
                    .management
                    .requests
                    .iter()
                    .any(|request| request.id == request_id)
            {
                return Ok(false);
            }
            if group.members.iter().any(|member| member.id == sender_id) {
                return Ok(false);
            }
            if group.management.requests.len() >= MAX_CONTROLS {
                return Err(CoreError::StorageFull);
            }
            let candidate = group_member(sender.clone())?;
            group.management.requests.push(Request {
                id: request_id,
                actor: owner_id(&group)?,
                action: Action::AddMembers {
                    invitation_codes: Vec::new(),
                },
                candidate: Some(candidate),
            });
            save(group)?;
            Ok(true)
        }
        Control::Invite {
            group_id,
            generation,
            code,
        } => {
            let mut group = current_group(&group_id)?.ok_or(CoreError::FeatureUnavailable)?;
            if owner_id(&group)? != sender_id
                || code.len() > 2048
                || !code.starts_with("sylphy-group-join-v1:")
            {
                return Err(CoreError::GroupPermissionDenied);
            }
            group.management.shared_invite = Some((generation, code));
            save(group)?;
            Ok(true)
        }
        Control::Rejected {
            group_id,
            request_id,
        } => {
            let mut group = current_group(&group_id)?.ok_or(CoreError::FeatureUnavailable)?;
            if owner_id(&group)? != sender_id {
                return Err(CoreError::GroupPermissionDenied);
            }
            validate_conversation_id(&request_id)?;
            group
                .management
                .requests
                .retain(|request| request.id != request_id);
            group.management.pending_effect = Some(Effect {
                notice: "La richiesta di modifica del gruppo è stata rifiutata".to_owned(),
                event_id: request_id,
                outgoing: false,
            });
            save(group.clone())?;
            complete_effect(group)?;
            Ok(true)
        }
        Control::Request { group_id, request } => {
            let mut group = current_group(&group_id)?.ok_or(CoreError::FeatureUnavailable)?;
            if !is_coordinator(&group)? || request.actor != sender_id || request.candidate.is_some()
            {
                return Err(CoreError::GroupPermissionDenied);
            }
            authorized(&group, &sender_id, &request.action)?;
            if group.management.processed.contains(&request.id)
                || group
                    .management
                    .requests
                    .iter()
                    .any(|item| item.id == request.id)
            {
                return Ok(false);
            }
            if group.management.requests.len() >= MAX_CONTROLS {
                return Err(CoreError::StorageFull);
            }
            validate_conversation_id(&request.id)?;
            group.management.requests.push(request);
            save(group)?;
            Ok(true)
        }
        Control::Snapshot {
            mut group,
            notice,
            event_id,
        } => {
            validate_groups(std::slice::from_ref(&group))?;
            validate_conversation_id(&event_id)?;
            if group.admin_id != sender_id
                || group.management.revision == 0
                || notice.len() > 256
                || !group.management.requests.is_empty()
                || !group.management.outbound.is_empty()
                || !group.management.processed.is_empty()
                || group.management.removed
                || group.management.left
                || group.management.pending_departure.is_some()
                || !group.management.departed.is_empty()
                || group.management.pending_effect.is_some()
                || group.management.invite.is_some()
                || group.management.shared_invite.is_some()
            {
                return Err(CoreError::VerificationFailed);
            }
            let local = local_id()?;
            let existing = current_group(&group.id)?;
            if let Some(existing) = &existing {
                if owner_id(existing)? != sender_id {
                    return Err(CoreError::GroupPermissionDenied);
                }
                if let Some(coordinator) = &existing.management.coordinator {
                    if coordinator
                        .bundle
                        .signal_pre_key
                        .as_ref()
                        .map(|key| &key.identity_key)
                        != sender
                            .bundle
                            .signal_pre_key
                            .as_ref()
                            .map(|key| &key.identity_key)
                    {
                        return Err(CoreError::GroupPermissionDenied);
                    }
                }
                if group.management.revision <= existing.management.revision {
                    return Ok(false);
                }
                if existing.management.closed {
                    return Err(CoreError::GroupClosed);
                }
            } else {
                if !group.members.iter().any(|member| member.id == local) {
                    return Err(CoreError::GroupPermissionDenied);
                }
                if !allows_unknown_contacts()?
                    && !contact_store()
                        .lock()
                        .map_err(|_| CoreError::Internal)?
                        .contacts
                        .iter()
                        .any(|contact| contact.id == sender_id)
                {
                    return Err(CoreError::GroupPermissionDenied);
                }
            }
            group.management.removed = !group.members.iter().any(|member| member.id == local);
            group.members.retain(|member| member.id != local);
            if !group.members.iter().any(|member| member.id == sender_id) {
                return Err(CoreError::VerificationFailed);
            }
            if let Some(existing) = existing {
                // Retain departures that the owner has not yet observed. Once
                // its snapshot excludes that member, its revision prevents replay.
                group.management.departed = existing
                    .management
                    .departed
                    .into_iter()
                    .filter(|id| group.members.iter().any(|member| &member.id == id))
                    .collect();
                group
                    .members
                    .retain(|member| !group.management.departed.contains(&member.id));
                group.management.requests = existing
                    .management
                    .requests
                    .into_iter()
                    .filter(|request| {
                        request.id != event_id && !already_applied(&group, &request.action)
                    })
                    .collect();
                group.management.outbound = existing.management.outbound;
                group.management.shared_invite = existing.management.shared_invite;
            }
            group.management.pending_effect = Some(Effect {
                notice,
                event_id,
                outgoing: false,
            });
            save(group.clone())?;
            complete_effect(group)?;
            Ok(true)
        }
    }
}

fn apply_local_effects(
    group: &StoredGroup,
    notice: &str,
    event_id: &str,
    outgoing: bool,
) -> CoreResult<()> {
    let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
    ensure_messages_loaded(&mut store)?;
    let path = store
        .message_path
        .clone()
        .ok_or(CoreError::FeatureUnavailable)?;
    let deleted = store
        .messages
        .iter()
        .filter(|message| {
            message.conversation_id == group.id
                && (group.management.closed
                    || group.management.left
                    || message_deleted(group, message))
        })
        .map(|message| message.id.clone())
        .collect::<HashSet<_>>();
    if !deleted.is_empty() {
        let messages = store
            .messages
            .iter()
            .filter(|message| message.conversation_id != group.id || !deleted.contains(&message.id))
            .cloned()
            .collect::<Vec<_>>();
        write_message_snapshot(&path, &messages)?;
        store.messages = messages;
        let outbox = store
            .outbox
            .iter()
            .filter(|pending| !deleted.contains(&pending.message_id))
            .cloned()
            .collect::<Vec<_>>();
        persist_outbox(
            store
                .outbox_path
                .as_deref()
                .ok_or(CoreError::FeatureUnavailable)?,
            &outbox,
        )?;
        store.outbox = outbox;
    }
    if group.management.show_action_notices
        && !notice.is_empty()
        && !group.management.closed
        && !group.management.left
        && !store.messages.iter().any(|message| message.id == event_id)
    {
        let message = StoredMessage {
            id: event_id.to_owned(),
            conversation_id: group.id.clone(),
            author_id: if outgoing {
                "me".to_owned()
            } else {
                group.admin_id.clone()
            },
            body: notice.to_owned(),
            sent_at_ms: current_time_ms()?,
            received_at_ms: 0,
            author_name: None,
            is_outgoing: outgoing,
            is_read: outgoing,
            delivery_state: "delivered".to_owned(),
            receipts: Default::default(),
            attachment_name: None,
            attachment_base64: None,
            attachment_pointer: None,
        };
        append_message_event(
            &path,
            &MessageEvent::Upsert {
                message: message.clone(),
            },
        )?;
        store.messages.push(message);
    }
    store.revision = store.revision.wrapping_add(1);
    Ok(())
}

pub(super) fn encode_text(text: &str, reply_to: Option<&str>) -> CoreResult<String> {
    encode_channel_text(text, reply_to, None)
}

pub(super) fn encode_channel_text(
    text: &str,
    reply_to: Option<&str>,
    channel_id: Option<&str>,
) -> CoreResult<String> {
    if let Some(id) = reply_to {
        validate_conversation_id(id)?;
    }
    if let Some(id) = channel_id {
        validate_conversation_id(id)?;
    }
    Ok(format!(
        "{RICH}{}",
        STANDARD_NO_PAD.encode(
            serde_json::to_vec(&RichText {
                version: 1,
                text: text.to_owned(),
                reply_to: reply_to.map(str::to_owned),
                channel_id: channel_id.map(str::to_owned)
            })
            .map_err(|_| CoreError::Internal)?
        )
    ))
}

pub(super) fn text_metadata(body: &str) -> CoreResult<(String, Option<String>)> {
    let (text, reply, _) = rich_metadata(body)?;
    Ok((text, reply))
}

pub(super) fn rich_metadata(body: &str) -> CoreResult<(String, Option<String>, Option<String>)> {
    let Some(encoded) = body.strip_prefix(RICH) else {
        return Ok((body.to_owned(), None, None));
    };
    if encoded.len() > MAX_MESSAGE_BODY_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let rich: RichText = serde_json::from_slice(
        &STANDARD_NO_PAD
            .decode(encoded)
            .map_err(|_| CoreError::InvalidInput)?,
    )
    .map_err(|_| CoreError::InvalidInput)?;
    if rich.version != 1 || rich.text.trim().is_empty() {
        return Err(CoreError::InvalidInput);
    }
    if let Some(id) = &rich.reply_to {
        validate_conversation_id(id)?;
    }
    if let Some(id) = &rich.channel_id {
        validate_conversation_id(id)?;
    }
    Ok((rich.text, rich.reply_to, rich.channel_id))
}

fn require_channel_management(group: &StoredGroup) -> CoreResult<()> {
    require_channel_capability(group, "group-channel-management-v1")
}

fn require_channels(group: &StoredGroup) -> CoreResult<()> {
    require_channel_capability(group, "group-channels-v1")
}

fn require_channel_capability(group: &StoredGroup, required: &str) -> CoreResult<()> {
    for member in &group.members {
        if member.identity.delivery_devices()?.iter().any(|device| {
            !device
                .bundle
                .capabilities
                .iter()
                .any(|capability| capability == required)
        }) {
            return Err(CoreError::UnsupportedVersion);
        }
    }
    Ok(())
}

pub(super) fn message_deleted(group: &StoredGroup, message: &StoredMessage) -> bool {
    group.management.deleted_messages.contains(&message.id)
        || (!group.management.deleted_channels.is_empty()
            && rich_metadata(&message.body).is_ok_and(|(_, _, channel)| {
                channel.is_some_and(|id| group.management.deleted_channels.contains(&id))
            }))
}

pub(super) fn enforce_channel(group: &StoredGroup, channel_id: Option<&str>) -> CoreResult<()> {
    if let Some(id) = channel_id {
        if !group
            .management
            .channels
            .iter()
            .any(|channel| channel.id == id)
        {
            return Err(CoreError::InvalidInput);
        }
    }
    Ok(())
}

pub fn send_channel_text(
    id: &str,
    text: &str,
    channel_id: &str,
    reply_to: Option<&str>,
) -> CoreResult<Value> {
    let group = current_group(id)?.ok_or(CoreError::InvalidInput)?;
    enforce_channel(&group, Some(channel_id))?;
    require_channels(&group)?;
    if text.trim().is_empty() {
        return Err(CoreError::InvalidInput);
    }
    if let Some(reply) = reply_to {
        let mut store = contact_store().lock().map_err(|_| CoreError::Internal)?;
        ensure_messages_loaded(&mut store)?;
        let original = store
            .messages
            .iter()
            .find(|message| message.conversation_id == id && message.id == reply)
            .ok_or(CoreError::InvalidInput)?;
        if rich_metadata(&original.body)?.2.as_deref() != Some(channel_id) {
            return Err(CoreError::InvalidInput);
        }
    }
    send_text(id, &encode_channel_text(text, reply_to, Some(channel_id))?)
}

pub fn search(id: &str, query: &str, offset: usize) -> CoreResult<Value> {
    super::search::search(id, query, offset)
}

fn publish_control_value(value: &impl Serialize) -> CoreResult<GroupInvitationPointer> {
    let encoded = serde_json::to_vec(value).map_err(|_| CoreError::Internal)?;
    if encoded.len() > MAX_ATTACHMENT_BYTES {
        return Err(CoreError::LimitExceeded);
    }
    let mut key = [0; 32];
    OsRng.fill_bytes(&mut key);
    let encrypted = vault::seal_with_key(&key, &encoded)?;
    let (record_key, chunk_count) = publish_bytes(&encrypted)?;
    if let Err(error) = register_attachment_lease(&record_key, chunk_count) {
        let _ = veilid_adapter::delete_attachment_blob(&record_key, chunk_count);
        return Err(error);
    }
    Ok(GroupInvitationPointer {
        version: 1,
        size: encoded.len(),
        record_key,
        chunk_count,
        key_base64: STANDARD_NO_PAD.encode(key),
    })
}

pub fn join(code: &str) -> CoreResult<Value> {
    let encoded = code
        .trim()
        .strip_prefix("sylphy-group-join-v1:")
        .ok_or(CoreError::InvalidInput)?;
    if encoded.len() > 2048 {
        return Err(CoreError::LimitExceeded);
    }
    let pointer: GroupInvitationPointer = serde_json::from_slice(
        &STANDARD_NO_PAD
            .decode(encoded)
            .map_err(|_| CoreError::InvalidInput)?,
    )
    .map_err(|_| CoreError::InvalidInput)?;
    if pointer.version != 1
        || pointer.size == 0
        || pointer.size > MAX_ATTACHMENT_BYTES
        || pointer.chunk_count == 0
        || pointer.chunk_count > 64
        || pointer.record_key.len() > 256
    {
        return Err(CoreError::InvalidInput);
    }
    let key: [u8; 32] = STANDARD_NO_PAD
        .decode(&pointer.key_base64)
        .map_err(|_| CoreError::InvalidInput)?
        .try_into()
        .map_err(|_| CoreError::InvalidInput)?;
    let plaintext = vault::open_with_key(
        &key,
        &fetch_bytes(&pointer.record_key, pointer.chunk_count)?,
    )?;
    if plaintext.len() != pointer.size {
        return Err(CoreError::VerificationFailed);
    }
    let link: JoinLink = serde_json::from_slice(&plaintext).map_err(|_| CoreError::InvalidInput)?;
    if link.version != 1 || link.token.len() != 32 || link.expires_at_ms <= current_time_ms()? {
        return Err(CoreError::GroupPermissionDenied);
    }
    validate_conversation_id(&link.group_id)?;
    link.owner.validate()?;
    let owner = group_member(link.owner.clone())?;
    if owner.id == local_id()? {
        return Err(CoreError::InvalidInput);
    }
    let mut group = if let Some(existing) = current_group(&link.group_id)? {
        if owner_id(&existing)? != owner.id
            || existing.management.closed
            || !existing.management.removed
        {
            return Err(CoreError::GroupPermissionDenied);
        }
        existing
    } else {
        StoredGroup {
            id: link.group_id.clone(),
            name: "Ingresso in attesa".to_owned(),
            description: String::new(),
            mode: "group".to_owned(),
            admin_id: owner.id.clone(),
            created_at_ms: current_time_ms()?,
            members: vec![owner.clone()],
            management: Management {
                removed: true,
                coordinator: Some(link.owner),
                ..Management::default()
            },
        }
    };
    require_updated(&group)?;
    let pending = seal_control(
        &Control::Join {
            group_id: link.group_id.clone(),
            token: link.token,
            request_id: new_id(),
        },
        &[owner],
    )?;
    group.management.outbound.extend(pending);
    group.management.left = false;
    group.management.pending_departure = None;
    save(group)?;
    transfer_outbound()?;
    Ok(json!({"group_id": link.group_id, "state": "pending_owner"}))
}
