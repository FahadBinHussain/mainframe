# WACLI raw-handle calls still needing ownership review

The final twelve-patch WACLI chain contains **164 production zero-argument accessor call sites: 80 `DB()` and 84 `WA()`**. Every entry remains conservatively `raw_escape` / **UNPROVEN**. This is a complete syntactic list of these calls, not a proof of lifecycle coverage.

The chain applies to WACLI `5578d1b6892f50a8f2329b11a6b6e27a1a81f88b` with the four pinned whatsmeow patches. The [SHA-256 manifest](../patches/wacli/runtime-series.json) identifies the exact source artifacts. [Patch 0009](../patches/wacli/0009-owned-quote-and-handle-inventory.patch) introduces the AST regression and full machine-readable `cmd/wacli/testdata/owned_handle_inventory.json` fixture; patches [0010](../patches/wacli/0010-owned-command-reads.patch), [0011](../patches/wacli/0011-owned-contacts.patch) and [0012](../patches/wacli/0012-owned-auth-profile-presence.patch) update them after source review. Line numbers below refer to the reconstructed final source, not Mainframe files.

## What changed, and what has not

File and sticker sends select owned client and database facets before accessing a raw handle. Their quoted-message and media-metadata reads have per-invocation child leases. Their remaining raw accessor entries below are compatibility branches for non-owned callers, not evidence that those callers are fenced. Text-send helpers still use a raw reply adapter. Patch 0010 adds leased message-read and local archive-diagnostic facades. Their scoped command routes do not borrow raw handles; consistent page callbacks and synchronous resolver work stay private inside the invocation lease. This fences those application invocations, not arbitrary SDK descendants or output descriptors.

Large remaining families include legacy message-mutation helpers, message mutations, group administration, poll state, media download, cleanup, and other client operations. The internal `LocalResolver` return and chat-state handler removal also remain raw. The migrated routes are message list/search/starred/show/context/export reads and changes; calls list, history coverage/fill planning, and store statistics. Export file publication remains a separate filesystem-ownership gap. Patch 0011 also migrates contact search/show, refresh, alias/tag metadata, system import/clear, live registration check, and account save (including those two delegated contact routes). Each actual DB/resolver/client effect retains a child lease through completion. Save retains the whole persistence/journal operation and leases disconnect cleanup before the still-live parent finishes, even after timeout. The separate `contacts resolve` command still borrows a raw resolver; direct legacy `App.SaveContact` and application fields/stores are not certified. A root command scope alone does not prove a borrowed handle or callback continuation is joined.

Public SDK synchronous methods, SDK `Store` and `DangerousInternals`, application fields/direct store methods, previously borrowed handles, method values and aliases, arbitrary callbacks, drivers/descriptors and independent processes remain separate gaps. Both production drain APIs still refuse a held capture; capture, publication and usable restore remain disabled. No Windows runtime is claimed.

## What the source gate checks

The Go AST test walks every `.go` source file except `*_test.go`, `vendor` and `.git`, independently of host build tags. It includes calls inside closures and file-level initializers, but does not perform receiver type resolution. Generated Go files are included if present; code generated later is not inferred. Comments, strings and method values are not calls. The gate compares source path, enclosing named function, accessor, expression, location and ordinal identity. Additions, deletions and location changes fail until reviewed. A synthetic parser test checks repeated calls, closures, file scope and exclusions.

After source review only, regenerate the test fixture with `WACLI_UPDATE_OWNED_HANDLE_INVENTORY=1 go test ./cmd/wacli -run "^TestOwnedHandleInventory$"` in a disposable exact-chain source tree with the patched SDK. This changes a test fixture only; it cannot approve runtime ownership, clear coverage gaps or authorize capture. Normal verification removes inherited `WACLI_` variables and does not update the fixture.

## Authentication, profile and presence review

Patch 0012 migrates login/bootstrap `Sync`, writable auth status, logout, profile mutations/reads, typing/paused presence and watched presence, including delegated presence routes. `OwnedAuth` retains each complete application authentication/connect invocation; profile and presence client effects have distinct child leases. Session authentication and local migration/database work stay private inside the accepted invocation. Bounded presence attempts retain their worker lease after caller timeout; reconnect uses owned disconnect and authentication/connect effects. Hide-presence cleanup uses cancellation-stripped **live parent lineage**, not a new root, and finishes before parent completion. Command cleanup finishes its own root before joining actual descendants and retains close/lock errors. The existing independent read-only auth-status SQL reader is unchanged and is not certified by these application facades.

Only these reviewed command routes removed calls: auth 3 WA, profile 7 WA, presence 3 WA, and delegated presence 1 WA. The other seven `send_ipc.go` entries retain their identities/status and shift only in source location; no other inventory path changed. The complete AST fixture was regenerated, with no additions or omitted residuals. Public SDK/direct store APIs and arbitrary descendants remain unproven.

## Counts by file

| Final source file | DB | WA | Total |
|---|---:|---:|---:|
| `cmd/wacli/channels.go` | 3 | 5 | 8 |
| `cmd/wacli/chats.go` | 3 | 0 | 3 |
| `cmd/wacli/chats_cleanup.go` | 6 | 0 | 6 |
| `cmd/wacli/chats_state.go` | 0 | 1 | 1 |
| `cmd/wacli/doctor.go` | 1 | 2 | 3 |
| `cmd/wacli/groups_admin.go` | 4 | 13 | 17 |
| `cmd/wacli/groups_info_rename.go` | 3 | 6 | 9 |
| `cmd/wacli/groups_invite_join.go` | 1 | 5 | 6 |
| `cmd/wacli/groups_participants.go` | 2 | 3 | 5 |
| `cmd/wacli/groups_prune.go` | 2 | 0 | 2 |
| `cmd/wacli/groups_refresh_list.go` | 4 | 2 | 6 |
| `cmd/wacli/media_download.go` | 4 | 1 | 5 |
| `cmd/wacli/messages_delete.go` | 6 | 3 | 9 |
| `cmd/wacli/messages_edit.go` | 1 | 1 | 2 |
| `cmd/wacli/messages_forward.go` | 3 | 3 | 6 |
| `cmd/wacli/messages_helpers.go` | 2 | 0 | 2 |
| `cmd/wacli/messages_purge.go` | 3 | 0 | 3 |
| `cmd/wacli/poll_cmd.go` | 10 | 6 | 16 |
| `cmd/wacli/recipient.go` | 1 | 0 | 1 |
| `cmd/wacli/send.go` | 1 | 3 | 4 |
| `cmd/wacli/send_file.go` | 1 | 1 | 2 |
| `cmd/wacli/send_file_cmd.go` | 0 | 1 | 1 |
| `cmd/wacli/send_helpers.go` | 0 | 1 | 1 |
| `cmd/wacli/send_ipc.go` | 2 | 5 | 7 |
| `cmd/wacli/send_location_cmd.go` | 1 | 4 | 5 |
| `cmd/wacli/send_poll_cmd.go` | 3 | 5 | 8 |
| `cmd/wacli/send_react_cmd.go` | 1 | 3 | 4 |
| `cmd/wacli/send_select_cmd.go` | 3 | 3 | 6 |
| `cmd/wacli/send_status_cmd.go` | 1 | 1 | 2 |
| `cmd/wacli/send_sticker.go` | 1 | 1 | 2 |
| `cmd/wacli/send_sticker_cmd.go` | 0 | 1 | 1 |
| `cmd/wacli/send_text_history.go` | 1 | 1 | 2 |
| `cmd/wacli/send_voice_cmd.go` | 0 | 1 | 1 |
| `cmd/wacli/store_cleanup.go` | 5 | 0 | 5 |
| `cmd/wacli/store_media_membership.go` | 1 | 0 | 1 |
| `internal/app/app.go` | 0 | 1 | 1 |
| `internal/app/chat_state.go` | 0 | 1 | 1 |

## Every remaining call

All entries in this table have status **UNPROVEN (`raw_escape`)**. Occurrence numbers distinguish repeated accessors within one enclosing function.

| Final source location | Enclosing function | Call | Occurrence |
|---|---|---|---:|
| `cmd/wacli/channels.go:52:17` | `newChannelsListCmd` | `a.WA()` | 1 |
| `cmd/wacli/channels.go:57:36` | `newChannelsListCmd` | `a.DB()` | 1 |
| `cmd/wacli/channels.go:117:17` | `newChannelsInfoCmd` | `a.WA()` | 1 |
| `cmd/wacli/channels.go:125:36` | `newChannelsInfoCmd` | `a.DB()` | 1 |
| `cmd/wacli/channels.go:178:17` | `newChannelsJoinCmd` | `a.WA()` | 1 |
| `cmd/wacli/channels.go:185:14` | `newChannelsJoinCmd` | `a.WA()` | 2 |
| `cmd/wacli/channels.go:189:36` | `newChannelsJoinCmd` | `a.DB()` | 1 |
| `cmd/wacli/channels.go:236:14` | `newChannelsLeaveCmd` | `a.WA()` | 1 |
| `cmd/wacli/chats.go:81:18` | `newChatsListCmd` | `a.DB()` | 1 |
| `cmd/wacli/chats.go:253:15` | `getChatForDisplay` | `a.DB()` | 1 |
| `cmd/wacli/chats.go:266:15` | `getChatForDisplay` | `a.DB()` | 2 |
| `cmd/wacli/chats_cleanup.go:49:18` | `newChatsCleanupCmd` | `a.DB()` | 1 |
| `cmd/wacli/chats_cleanup.go:93:20` | `newChatsCleanupCmd` | `a.DB()` | 2 |
| `cmd/wacli/chats_cleanup.go:94:15` | `newChatsCleanupCmd` | `a.DB()` | 3 |
| `cmd/wacli/chats_cleanup.go:127:15` | `cleanupSingleChat` | `a.DB()` | 1 |
| `cmd/wacli/chats_cleanup.go:132:17` | `cleanupSingleChat` | `a.DB()` | 2 |
| `cmd/wacli/chats_cleanup.go:166:12` | `cleanupSingleChat` | `a.DB()` | 3 |
| `cmd/wacli/chats_state.go:243:3` | `runChatState` | `a.WA()` | 1 |
| `cmd/wacli/doctor.go:198:11` | `newDoctorCmd` | `appInstance.DB()` | 1 |
| `cmd/wacli/doctor.go:216:15` | `newDoctorCmd` | `a.WA()` | 1 |
| `cmd/wacli/doctor.go:218:19` | `newDoctorCmd` | `a.WA()` | 2 |
| `cmd/wacli/groups_admin.go:65:17` | `newGroupsCreateCmd` | `a.WA()` | 1 |
| `cmd/wacli/groups_admin.go:78:31` | `newGroupsCreateCmd` | `a.DB()` | 1 |
| `cmd/wacli/groups_admin.go:78:39` | `newGroupsCreateCmd` | `a.WA()` | 2 |
| `cmd/wacli/groups_admin.go:134:14` | `newGroupsTopicCmd` | `a.WA()` | 1 |
| `cmd/wacli/groups_admin.go:137:20` | `newGroupsTopicCmd` | `a.WA()` | 2 |
| `cmd/wacli/groups_admin.go:138:31` | `newGroupsTopicCmd` | `a.DB()` | 1 |
| `cmd/wacli/groups_admin.go:138:39` | `newGroupsTopicCmd` | `a.WA()` | 3 |
| `cmd/wacli/groups_admin.go:201:25` | `newGroupsToggleCmd` | `a.WA()` | 1 |
| `cmd/wacli/groups_admin.go:204:20` | `newGroupsToggleCmd` | `a.WA()` | 2 |
| `cmd/wacli/groups_admin.go:205:31` | `newGroupsToggleCmd` | `a.DB()` | 1 |
| `cmd/wacli/groups_admin.go:205:39` | `newGroupsToggleCmd` | `a.WA()` | 3 |
| `cmd/wacli/groups_admin.go:285:21` | `newGroupsRequestsListCmd` | `a.WA()` | 1 |
| `cmd/wacli/groups_admin.go:290:52` | `newGroupsRequestsListCmd` | `a.WA()` | 2 |
| `cmd/wacli/groups_admin.go:341:20` | `newGroupsRequestsActionCmd` | `a.WA()` | 1 |
| `cmd/wacli/groups_admin.go:345:20` | `newGroupsRequestsActionCmd` | `a.WA()` | 2 |
| `cmd/wacli/groups_admin.go:346:31` | `newGroupsRequestsActionCmd` | `a.DB()` | 1 |
| `cmd/wacli/groups_admin.go:346:39` | `newGroupsRequestsActionCmd` | `a.WA()` | 3 |
| `cmd/wacli/groups_info_rename.go:47:17` | `newGroupsInfoCmd` | `a.WA()` | 1 |
| `cmd/wacli/groups_info_rename.go:55:31` | `newGroupsInfoCmd` | `a.DB()` | 1 |
| `cmd/wacli/groups_info_rename.go:55:39` | `newGroupsInfoCmd` | `a.WA()` | 2 |
| `cmd/wacli/groups_info_rename.go:115:14` | `newGroupsRenameCmd` | `a.WA()` | 1 |
| `cmd/wacli/groups_info_rename.go:118:20` | `newGroupsRenameCmd` | `a.WA()` | 2 |
| `cmd/wacli/groups_info_rename.go:119:31` | `newGroupsRenameCmd` | `a.DB()` | 1 |
| `cmd/wacli/groups_info_rename.go:119:39` | `newGroupsRenameCmd` | `a.WA()` | 3 |
| `cmd/wacli/groups_info_rename.go:164:14` | `newGroupsLeaveCmd` | `a.WA()` | 1 |
| `cmd/wacli/groups_info_rename.go:167:8` | `newGroupsLeaveCmd` | `a.DB()` | 1 |
| `cmd/wacli/groups_invite_join.go:61:17` | `newGroupsInviteLinkGetCmd` | `a.WA()` | 1 |
| `cmd/wacli/groups_invite_join.go:107:17` | `newGroupsInviteLinkRevokeCmd` | `a.WA()` | 1 |
| `cmd/wacli/groups_invite_join.go:149:16` | `newGroupsJoinCmd` | `a.WA()` | 1 |
| `cmd/wacli/groups_invite_join.go:153:20` | `newGroupsJoinCmd` | `a.WA()` | 2 |
| `cmd/wacli/groups_invite_join.go:154:31` | `newGroupsJoinCmd` | `a.DB()` | 1 |
| `cmd/wacli/groups_invite_join.go:154:39` | `newGroupsJoinCmd` | `a.WA()` | 3 |
| `cmd/wacli/groups_participants.go:51:25` | `newGroupsParticipantsListCmd` | `a.DB()` | 1 |
| `cmd/wacli/groups_participants.go:118:20` | `newGroupsParticipantsActionCmd` | `a.WA()` | 1 |
| `cmd/wacli/groups_participants.go:122:20` | `newGroupsParticipantsActionCmd` | `a.WA()` | 2 |
| `cmd/wacli/groups_participants.go:123:31` | `newGroupsParticipantsActionCmd` | `a.DB()` | 1 |
| `cmd/wacli/groups_participants.go:123:39` | `newGroupsParticipantsActionCmd` | `a.WA()` | 3 |
| `cmd/wacli/groups_prune.go:66:17` | `pruneGroups` | `a.DB()` | 1 |
| `cmd/wacli/groups_prune.go:103:13` | `pruneGroups` | `a.DB()` | 2 |
| `cmd/wacli/groups_refresh_list.go:38:15` | `newGroupsRefreshCmd` | `a.WA()` | 1 |
| `cmd/wacli/groups_refresh_list.go:49:31` | `newGroupsRefreshCmd` | `a.DB()` | 1 |
| `cmd/wacli/groups_refresh_list.go:49:39` | `newGroupsRefreshCmd` | `a.WA()` | 2 |
| `cmd/wacli/groups_refresh_list.go:50:9` | `newGroupsRefreshCmd` | `a.DB()` | 2 |
| `cmd/wacli/groups_refresh_list.go:52:14` | `newGroupsRefreshCmd` | `a.DB()` | 3 |
| `cmd/wacli/groups_refresh_list.go:89:15` | `newGroupsListCmd` | `a.DB()` | 1 |
| `cmd/wacli/media_download.go:57:24` | `downloadExactMedia` | `reader.DB()` | 1 |
| `cmd/wacli/media_download.go:139:15` | `downloadExactMedia` | `roReader.DB()` | 2 |
| `cmd/wacli/media_download.go:177:15` | `executeExactMediaDownload` | `a.DB()` | 1 |
| `cmd/wacli/media_download.go:197:12` | `executeExactMediaDownload` | `a.WA()` | 1 |
| `cmd/wacli/media_download.go:224:13` | `executeExactMediaDownload` | `a.DB()` | 2 |
| `cmd/wacli/messages_delete.go:74:25` | `newMessagesDeleteCmd` | `a.WA()` | 1 |
| `cmd/wacli/messages_delete.go:78:24` | `newMessagesDeleteCmd` | `a.DB()` | 1 |
| `cmd/wacli/messages_delete.go:85:16` | `newMessagesDeleteCmd` | `a.DB()` | 2 |
| `cmd/wacli/messages_delete.go:91:16` | `newMessagesDeleteCmd` | `a.DB()` | 3 |
| `cmd/wacli/messages_delete.go:95:15` | `newMessagesDeleteCmd` | `a.DB()` | 4 |
| `cmd/wacli/messages_delete.go:113:12` | `newMessagesDeleteCmd` | `a.WA()` | 2 |
| `cmd/wacli/messages_delete.go:118:14` | `newMessagesDeleteCmd` | `a.DB()` | 5 |
| `cmd/wacli/messages_delete.go:192:12` | `newMessagesRevokeCmd` | `a.WA()` | 1 |
| `cmd/wacli/messages_delete.go:198:15` | `newMessagesRevokeCmd` | `a.DB()` | 1 |
| `cmd/wacli/messages_edit.go:83:12` | `newMessagesEditCmd` | `a.WA()` | 1 |
| `cmd/wacli/messages_edit.go:88:14` | `newMessagesEditCmd` | `a.DB()` | 1 |
| `cmd/wacli/messages_forward.go:58:18` | `newMessagesForwardCmd` | `a.DB()` | 1 |
| `cmd/wacli/messages_forward.go:74:33` | `newMessagesForwardCmd` | `a.WA()` | 1 |
| `cmd/wacli/messages_forward.go:83:12` | `newMessagesForwardCmd` | `a.WA()` | 2 |
| `cmd/wacli/messages_forward.go:90:16` | `newMessagesForwardCmd` | `a.WA()` | 3 |
| `cmd/wacli/messages_forward.go:92:14` | `newMessagesForwardCmd` | `a.DB()` | 2 |
| `cmd/wacli/messages_forward.go:95:14` | `newMessagesForwardCmd` | `a.DB()` | 3 |
| `cmd/wacli/messages_helpers.go:23:42` | `messageChatJIDFilter` | `a.DB()` | 1 |
| `cmd/wacli/messages_helpers.go:105:37` | `loadMessageMutationTarget` | `a.DB()` | 1 |
| `cmd/wacli/messages_purge.go:46:16` | `newMessagesPurgeCmd` | `a.DB()` | 1 |
| `cmd/wacli/messages_purge.go:69:23` | `newMessagesPurgeCmd` | `a.DB()` | 2 |
| `cmd/wacli/messages_purge.go:76:14` | `newMessagesPurgeCmd` | `a.DB()` | 3 |
| `cmd/wacli/poll_cmd.go:103:33` | `newPollVoteCmd` | `a.WA()` | 1 |
| `cmd/wacli/poll_cmd.go:122:12` | `newPollVoteCmd` | `a.WA()` | 2 |
| `cmd/wacli/poll_cmd.go:231:13` | `buildPollVoteInfoForChats` | `a.DB()` | 1 |
| `cmd/wacli/poll_cmd.go:259:18` | `buildPollVoteInfoForChats` | `a.DB()` | 2 |
| `cmd/wacli/poll_cmd.go:277:34` | `buildPollVoteInfoForChats` | `a.WA()` | 1 |
| `cmd/wacli/poll_cmd.go:339:14` | `persistOutboundVote` | `a.WA()` | 1 |
| `cmd/wacli/poll_cmd.go:341:12` | `persistOutboundVote` | `a.DB()` | 1 |
| `cmd/wacli/poll_cmd.go:344:12` | `persistOutboundVote` | `a.DB()` | 2 |
| `cmd/wacli/poll_cmd.go:355:11` | `persistOutboundVote` | `a.WA()` | 2 |
| `cmd/wacli/poll_cmd.go:359:12` | `persistOutboundVote` | `a.DB()` | 3 |
| `cmd/wacli/poll_cmd.go:401:10` | `executeDelegatedPollVote` | `a.WA()` | 1 |
| `cmd/wacli/poll_cmd.go:477:16` | `getPollForShow` | `a.DB()` | 1 |
| `cmd/wacli/poll_cmd.go:485:17` | `getPollForShow` | `a.DB()` | 2 |
| `cmd/wacli/poll_cmd.go:557:17` | `resolveVoterName` | `a.DB()` | 1 |
| `cmd/wacli/poll_cmd.go:558:16` | `resolveVoterName` | `a.DB()` | 2 |
| `cmd/wacli/poll_cmd.go:635:18` | `newPollsListCmd` | `a.DB()` | 1 |
| `cmd/wacli/recipient.go:39:37` | `resolveRecipient` | `a.DB()` | 1 |
| `cmd/wacli/send.go:121:37` | `newSendTextCmd` | `a.WA()` | 1 |
| `cmd/wacli/send.go:132:33` | `newSendTextCmd` | `a.WA()` | 2 |
| `cmd/wacli/send.go:293:40` | `sendTextMessage` | `a.WA()` | 1 |
| `cmd/wacli/send.go:293:48` | `sendTextMessage` | `a.DB()` | 1 |
| `cmd/wacli/send_file.go:108:12` | `sendFile` | `a.WA()` | 1 |
| `cmd/wacli/send_file.go:128:12` | `sendFile` | `a.DB()` | 1 |
| `cmd/wacli/send_file_cmd.go:94:33` | `newSendFileCmd` | `a.WA()` | 1 |
| `cmd/wacli/send_helpers.go:165:3` | `reconnectForSend` | `a.WA()` | 1 |
| `cmd/wacli/send_ipc.go:609:10` | `executeDelegatedEdit` | `a.WA()` | 1 |
| `cmd/wacli/send_ipc.go:614:12` | `executeDelegatedEdit` | `a.DB()` | 1 |
| `cmd/wacli/send_ipc.go:635:35` | `executeDelegatedText` | `a.WA()` | 1 |
| `cmd/wacli/send_ipc.go:740:10` | `executeDelegatedReact` | `a.WA()` | 1 |
| `cmd/wacli/send_ipc.go:746:38` | `executeDelegatedReact` | `a.DB()` | 1 |
| `cmd/wacli/send_ipc.go:746:46` | `executeDelegatedReact` | `a.WA()` | 2 |
| `cmd/wacli/send_ipc.go:817:30` | `warmupDelegatedRecipient` | `a.WA()` | 1 |
| `cmd/wacli/send_location_cmd.go:103:33` | `newSendLocationCmd` | `a.WA()` | 1 |
| `cmd/wacli/send_location_cmd.go:109:37` | `newSendLocationCmd` | `a.WA()` | 2 |
| `cmd/wacli/send_location_cmd.go:173:42` | `persistOutboundLocation` | `a.DB()` | 1 |
| `cmd/wacli/send_location_cmd.go:173:50` | `persistOutboundLocation` | `a.WA()` | 1 |
| `cmd/wacli/send_location_cmd.go:222:35` | `executeDelegatedLocation` | `a.WA()` | 1 |
| `cmd/wacli/send_poll_cmd.go:92:33` | `newSendPollCmd` | `a.WA()` | 1 |
| `cmd/wacli/send_poll_cmd.go:98:33` | `newSendPollCmd` | `a.WA()` | 2 |
| `cmd/wacli/send_poll_cmd.go:173:14` | `persistOutboundPoll` | `a.WA()` | 1 |
| `cmd/wacli/send_poll_cmd.go:175:12` | `persistOutboundPoll` | `a.DB()` | 1 |
| `cmd/wacli/send_poll_cmd.go:178:12` | `persistOutboundPoll` | `a.DB()` | 2 |
| `cmd/wacli/send_poll_cmd.go:189:12` | `persistOutboundPoll` | `a.DB()` | 3 |
| `cmd/wacli/send_poll_cmd.go:192:47` | `persistOutboundPoll` | `a.WA()` | 2 |
| `cmd/wacli/send_poll_cmd.go:240:31` | `executeDelegatedPoll` | `a.WA()` | 1 |
| `cmd/wacli/send_react_cmd.go:70:32` | `newSendReactCmd` | `a.WA()` | 1 |
| `cmd/wacli/send_react_cmd.go:75:12` | `newSendReactCmd` | `a.WA()` | 2 |
| `cmd/wacli/send_react_cmd.go:82:40` | `newSendReactCmd` | `a.DB()` | 1 |
| `cmd/wacli/send_react_cmd.go:82:48` | `newSendReactCmd` | `a.WA()` | 3 |
| `cmd/wacli/send_select_cmd.go:133:33` | `newSendSelectCmd` | `a.WA()` | 1 |
| `cmd/wacli/send_select_cmd.go:202:31` | `sendButtonListSelection` | `a.WA()` | 1 |
| `cmd/wacli/send_select_cmd.go:230:15` | `loadSelectTargetMessage` | `a.DB()` | 1 |
| `cmd/wacli/send_select_cmd.go:459:14` | `persistOutboundSelection` | `a.WA()` | 1 |
| `cmd/wacli/send_select_cmd.go:461:12` | `persistOutboundSelection` | `a.DB()` | 1 |
| `cmd/wacli/send_select_cmd.go:464:12` | `persistOutboundSelection` | `a.DB()` | 2 |
| `cmd/wacli/send_status_cmd.go:111:39` | `newSendStatusCmd` | `a.WA()` | 1 |
| `cmd/wacli/send_status_cmd.go:123:16` | `newSendStatusCmd` | `a.DB()` | 1 |
| `cmd/wacli/send_sticker.go:71:12` | `sendSticker` | `a.WA()` | 1 |
| `cmd/wacli/send_sticker.go:87:12` | `sendSticker` | `a.DB()` | 1 |
| `cmd/wacli/send_sticker_cmd.go:75:33` | `newSendStickerCmd` | `a.WA()` | 1 |
| `cmd/wacli/send_text_history.go:25:43` | `sendTextWithHistory` | `a.DB()` | 1 |
| `cmd/wacli/send_text_history.go:25:51` | `sendTextWithHistory` | `a.WA()` | 1 |
| `cmd/wacli/send_voice_cmd.go:82:33` | `newSendVoiceCmd` | `a.WA()` | 1 |
| `cmd/wacli/store_cleanup.go:41:18` | `newStoreCleanupCmd` | `a.DB()` | 1 |
| `cmd/wacli/store_cleanup.go:56:17` | `newStoreCleanupCmd` | `a.DB()` | 2 |
| `cmd/wacli/store_cleanup.go:74:18` | `newStoreCleanupCmd` | `a.DB()` | 3 |
| `cmd/wacli/store_cleanup.go:96:17` | `newStoreCleanupCmd` | `a.DB()` | 4 |
| `cmd/wacli/store_cleanup.go:97:15` | `newStoreCleanupCmd` | `a.DB()` | 5 |
| `cmd/wacli/store_media_membership.go:27:20` | `newStoreVerifyMediaCmd` | `a.DB()` | 1 |
| `internal/app/app.go:371:10` | `LocalResolver` | `a.WA()` | 1 |
| `internal/app/chat_state.go:43:14` | `AddChatStatePersistenceHandler` | `a.WA()` | 1 |
