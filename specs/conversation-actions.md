# Conversation actions

Long pressing a conversation in the mobile list, desktop sidebar or group avatar
rail opens its actions. Desktop users can also right click. Dismissing the menu
does not change the chat or its read state.

## Mute

`Silenzia chat` disables message and pin alerts for that conversation until
`Riattiva notifiche` is selected. A crossed bell identifies muted chats. Messages
continue to arrive and unread counts remain visible. Unmuting does not replay
alerts for messages already received.

The optional `ConversationNotificationBridge` calls the native JSON command
`set_conversation_muted` with `conversation_id` and `muted`. The core validates
that the conversation exists, persists the preference, then updates its revision.
Conversation summaries expose `is_muted`; older summaries default to false.

Preferences are local to the device, stored in the versioned encrypted file
`messaging/conversation-notifications-v1.vault` using the account storage key.
They survive restart and vault locking and are not sent to peers or linked
devices. A failed write keeps the previous preference. The UI reports failure.

Foreground alerts and the Android background worker both respect mute. The
native inbox response retains `persisted` for reception accounting and adds
`notification_count` for newly received, unread messages in unmuted chats.
`pin_notification` excludes muted groups. Muting clears the chat's existing
notification; the summary clears when no unmuted unread chats remain.

## Delete

`Cancella chat` opens the existing confirmation dialog before deleting anything.
Direct chats remove the local contact and history. Group chats follow the
existing leave flow and explain ownership transfer. Cancelling keeps the chat.
After deletion, the conversation lists refresh and an open deleted mobile chat
closes. Existing chat notifications are cleared.

## Validation

Widget coverage exercises mute/unmute, deletion cancellation/confirmation and
the avatar rail on mobile and desktop layouts, including persistence failures.
Bridge tests check summary cache invalidation and compatibility with older
summaries. Native tests check encrypted persistence across reloads, failed-write
rollback, alert suppression, message-ID collisions and unmute behavior.
