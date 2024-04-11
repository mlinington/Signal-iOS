//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient
import SignalCoreKit

public extension TSMessage {

    @objc
    var isIncoming: Bool { self as? TSIncomingMessage != nil }

    @objc
    var isOutgoing: Bool { self as? TSOutgoingMessage != nil }

    // MARK: - Attachments

    @objc
    func bodyAttachmentIds(transaction: SDSAnyReadTransaction) -> [String] {
        return DependenciesBridge.shared.tsResourceStore
            .bodyAttachments(for: self, tx: transaction.asV2Read)
            .map(\.resourceId.bridgeUniqueId)
    }

    @objc
    func hasBodyAttachments(transaction: SDSAnyReadTransaction) -> Bool {
        return DependenciesBridge.shared.tsResourceStore
            .bodyAttachments(for: self, tx: transaction.asV2Read)
            .isEmpty.negated
    }

    @objc
    func bodyAttachments(transaction: SDSAnyReadTransaction) -> [TSAttachment] {
        return DependenciesBridge.shared.tsResourceStore
            .bodyAttachments(for: self, tx: transaction.asV2Read)
            .fetchAll(tx: transaction).map(\.bridge)
    }

    @objc
    func hasMediaAttachments(transaction: SDSAnyReadTransaction) -> Bool {
        return DependenciesBridge.shared.tsResourceStore
            .bodyMediaAttachments(for: self, tx: transaction.asV2Read)
            .isEmpty.negated
    }

    @objc
    func mediaAttachments(transaction: SDSAnyReadTransaction) -> [TSAttachment] {
        return DependenciesBridge.shared.tsResourceStore
            .bodyMediaAttachments(for: self, tx: transaction.asV2Read)
            .fetchAll(tx: transaction).map(\.bridge)
    }

    @objc
    func oversizeTextAttachment(transaction: SDSAnyReadTransaction) -> TSAttachment? {
        return DependenciesBridge.shared.tsResourceStore
            .oversizeTextAttachment(for: self, tx: transaction.asV2Read)?
            .fetch(tx: transaction)?.bridge
    }

    @objc
    func allAttachments(transaction: SDSAnyReadTransaction) -> [TSAttachment] {
        return DependenciesBridge.shared.tsResourceStore
            .allAttachments(for: self, tx: transaction.asV2Read)
            .fetchAll(tx: transaction).map(\.bridge)
    }

    // Returns ids for all attachments, including message ("body") attachments,
    // quoted reply thumbnails, contact share avatars, link preview images, etc.
    @objc
    func allAttachmentIds(transaction: SDSAnyReadTransaction) -> [String] {
        return DependenciesBridge.shared.tsResourceStore
            .allAttachments(for: self, tx: transaction.asV2Read)
            .map(\.resourceId.bridgeUniqueId)
    }

    /// The raw body contains placeholders for things like mentions and is not user friendly.
    /// If you want a constant string representing the body of this message, this is it.
    @objc(rawBodyWithTransaction:)
    func rawBody(transaction: SDSAnyReadTransaction) -> String? {
        if let oversizeText = self.oversizeTextAttachment(transaction: transaction)?.asResourceStream()?.decryptedLongText() {
            return oversizeText
        }
        return self.body?.nilIfEmpty
    }

    func failedAttachments(transaction: SDSAnyReadTransaction) -> [TSAttachmentPointer] {
        let attachments: [TSAttachment] = allAttachments(transaction: transaction)
        let states: [TSAttachmentPointerState] = [.failed]
        return Self.onlyAttachmentPointers(attachments: attachments, withStateIn: Set(states))
    }

    func failedOrPendingAttachments(transaction: SDSAnyReadTransaction) -> [TSAttachmentPointer] {
        let attachments: [TSAttachment] = allAttachments(transaction: transaction)
        let states: [TSAttachmentPointerState] = [.failed, .pendingMessageRequest, .pendingManualDownload]
        return Self.onlyAttachmentPointers(attachments: attachments, withStateIn: Set(states))
    }

    func failedBodyAttachments(transaction: SDSAnyReadTransaction) -> [TSAttachmentPointer] {
        let attachments: [TSAttachment] = bodyAttachments(transaction: transaction)
        let states: [TSAttachmentPointerState] = [.failed]
        return Self.onlyAttachmentPointers(attachments: attachments, withStateIn: Set(states))
    }

    func pendingBodyAttachments(transaction: SDSAnyReadTransaction) -> [TSAttachmentPointer] {
        let attachments: [TSAttachment] = bodyAttachments(transaction: transaction)
        let states: [TSAttachmentPointerState] = [.pendingMessageRequest, .pendingManualDownload]
        return Self.onlyAttachmentPointers(attachments: attachments, withStateIn: Set(states))
    }

    private static func onlyAttachmentPointers(attachments: [TSAttachment],
                                               withStateIn states: Set<TSAttachmentPointerState>) -> [TSAttachmentPointer] {
        return attachments.compactMap { attachment -> TSAttachmentPointer? in
            guard let attachmentPointer = attachment.asTransitTierPointer()?.bridgePointer else {
                return nil
            }
            guard states.contains(attachmentPointer.state) else {
                return nil
            }
            return attachmentPointer
        }
    }

    // MARK: Attachment Deletes

    @objc
    func removeBodyMediaAttachments(tx: SDSAnyWriteTransaction) {
        DependenciesBridge.shared.tsResourceManager.removeAttachments(
            from: self,
            with: .bodyAttachment,
            tx: tx.asV2Write
        )
    }

    @objc
    func removeOversizeTextAttachment(tx: SDSAnyWriteTransaction) {
        DependenciesBridge.shared.tsResourceManager.removeAttachments(
            from: self,
            with: .oversizeText,
            tx: tx.asV2Write
        )
    }

    @objc
    func removeLinkPreviewAttachment(tx: SDSAnyWriteTransaction) {
        DependenciesBridge.shared.tsResourceManager.removeAttachments(
            from: self,
            with: .linkPreview,
            tx: tx.asV2Write
        )
    }

    @objc
    func removeStickerAttachment(tx: SDSAnyWriteTransaction) {
        DependenciesBridge.shared.tsResourceManager.removeAttachments(
            from: self,
            with: .sticker,
            tx: tx.asV2Write
        )
    }

    @objc
    func removeContactShareAvatarAttachment(tx: SDSAnyWriteTransaction) {
        DependenciesBridge.shared.tsResourceManager.removeAttachments(
            from: self,
            with: .contactAvatar,
            tx: tx.asV2Write
        )
    }

    @objc
    func removeAllAttachments(tx: SDSAnyWriteTransaction) {
        DependenciesBridge.shared.tsResourceManager.removeAttachments(
            from: self,
            with: .allTypes,
            tx: tx.asV2Write
        )
    }

    // MARK: - Mentions

    @objc
    func insertMentionsInDatabase(tx: SDSAnyWriteTransaction) {
        guard let bodyRanges else {
            return
        }
        // If we have any mentions, we need to save them to aid in querying for
        // messages that mention a given user. We only need to save one mention
        // record per ACI, even if the same ACI is mentioned multiple times in the
        // message.
        let uniqueMentionedAcis = Set(bodyRanges.mentions.values)
        for mentionedAci in uniqueMentionedAcis {
            let mention = TSMention(uniqueMessageId: uniqueId, uniqueThreadId: uniqueThreadId, aci: mentionedAci)
            mention.anyInsert(transaction: tx)
        }
    }

    // MARK: - Reactions

    var reactionFinder: ReactionFinder {
        return ReactionFinder(uniqueMessageId: uniqueId)
    }

    @objc
    func removeAllReactions(transaction: SDSAnyWriteTransaction) {
        guard !CurrentAppContext().isRunningTests else { return }
        reactionFinder.deleteAllReactions(transaction: transaction.unwrapGrdbWrite)
    }

    @objc
    func allReactionIds(transaction: SDSAnyReadTransaction) -> [String]? {
        return reactionFinder.allUniqueIds(transaction: transaction.unwrapGrdbRead)
    }

    @objc
    func markUnreadReactionsAsRead(transaction: SDSAnyWriteTransaction) {
        let unreadReactions = reactionFinder.unreadReactions(transaction: transaction.unwrapGrdbWrite)
        unreadReactions.forEach { $0.markAsRead(transaction: transaction) }
    }

    func reaction(for reactor: Aci, tx: SDSAnyReadTransaction) -> OWSReaction? {
        return reactionFinder.reaction(for: reactor, tx: tx.unwrapGrdbRead)
    }

    @discardableResult
    func recordReaction(
        for reactor: Aci,
        emoji: String,
        sentAtTimestamp: UInt64,
        receivedAtTimestamp: UInt64,
        tx: SDSAnyWriteTransaction
    ) -> OWSReaction? {
        return self.recordReaction(
            for: reactor,
            emoji: emoji,
            sentAtTimestamp: sentAtTimestamp,
            sortOrder: receivedAtTimestamp,
            tx: tx
        )
    }

    @discardableResult
    func recordReaction(
        for reactor: Aci,
        emoji: String,
        sentAtTimestamp: UInt64,
        sortOrder: UInt64,
        tx: SDSAnyWriteTransaction
    ) -> OWSReaction? {
        guard !wasRemotelyDeleted else {
            owsFailDebug("attempted to record a reaction for a message that was deleted")
            return nil
        }

        assert(emoji.isSingleEmoji)

        // Remove any previous reaction, there can only be one
        removeReaction(for: reactor, tx: tx)

        let reaction = OWSReaction(
            uniqueMessageId: uniqueId,
            emoji: emoji,
            reactor: reactor,
            sentAtTimestamp: sentAtTimestamp,
            receivedAtTimestamp: receivedAtTimestamp
        )

        reaction.anyInsert(transaction: tx)

        // Reactions to messages we send need to be manually marked
        // as read as they trigger notifications we need to clear
        // out. Everything else can be automatically read.
        if !(self is TSOutgoingMessage) { reaction.markAsRead(transaction: tx) }

        databaseStorage.touch(interaction: self, shouldReindex: false, transaction: tx)

        return reaction
    }

    func removeReaction(for reactor: Aci, tx: SDSAnyWriteTransaction) {
        guard let reaction = reaction(for: reactor, tx: tx) else { return }

        reaction.anyRemove(transaction: tx)
        databaseStorage.touch(interaction: self, shouldReindex: false, transaction: tx)

        Self.notificationsManager.cancelNotifications(reactionId: reaction.uniqueId)
    }

    // MARK: - Edits

    @objc
    func removeEdits(transaction: SDSAnyWriteTransaction) {
        try! processEdits(transaction: transaction) { record, message in
            try record.delete(transaction.unwrapGrdbWrite.database)
            message?.anyRemove(transaction: transaction)
        }
    }

    /// Build a list of all related edits based on this message.  An array of record, message pairs are
    /// returned, allowing the caller to operate on one or both of these items at the same time.
    ///
    /// The processing of edit records is unbounded, but the number of edits per message
    /// is limited by both the sender and receiver.
    private func processEdits(
        transaction: SDSAnyWriteTransaction,
        block: ((EditRecord, TSMessage?) throws -> Void)
    ) throws {
        let editsToProcess = try DependenciesBridge.shared.editMessageStore.findEditDeleteRecords(
            for: self,
            tx: transaction.asV2Read
        )
        for edit in editsToProcess {
            try block(edit.0, edit.1)
        }
    }

    // MARK: - Remote Delete

    // A message can be remotely deleted iff:
    //  * you sent this message
    //  * you haven't already remotely deleted this message
    //  * it's not a message with a gift badge
    //  * it has been less than 24 hours since you sent the message
    //    * this includes messages sent in the future
    var canBeRemotelyDeleted: Bool {
        guard let outgoingMessage = self as? TSOutgoingMessage else { return false }
        guard !outgoingMessage.wasRemotelyDeleted else { return false }
        guard outgoingMessage.giftBadge == nil else { return false }

        let (elapsedTime, isInFuture) = Date.ows_millisecondTimestamp().subtractingReportingOverflow(outgoingMessage.timestamp)
        guard isInFuture || (elapsedTime <= (kHourInMs * 24)) else { return false }

        return true
    }

    @objc(OWSRemoteDeleteProcessingResult)
    enum RemoteDeleteProcessingResult: Int, Error {
        case deletedMessageMissing
        case invalidDelete
        case success
    }

    class func tryToRemotelyDeleteMessage(
        fromAuthor authorAci: Aci,
        sentAtTimestamp: UInt64,
        threadUniqueId: String?,
        serverTimestamp: UInt64,
        transaction: SDSAnyWriteTransaction
    ) -> RemoteDeleteProcessingResult {
        guard SDS.fitsInInt64(sentAtTimestamp) else {
            owsFailDebug("Unable to delete a message with invalid sentAtTimestamp: \(sentAtTimestamp)")
            return .invalidDelete
        }

        if let threadUniqueId = threadUniqueId, let messageToDelete = InteractionFinder.findMessage(
            withTimestamp: sentAtTimestamp,
            threadId: threadUniqueId,
            author: SignalServiceAddress(authorAci),
            transaction: transaction
        ) {
            if messageToDelete is TSOutgoingMessage, SignalServiceAddress(authorAci).isLocalAddress {
                messageToDelete.markMessageAsRemotelyDeleted(transaction: transaction)
                return .success
            } else if var incomingMessageToDelete = messageToDelete as? TSIncomingMessage {
                if incomingMessageToDelete.editState == .pastRevision {
                    // The remote delete targeted an old revision, fetch
                    // swap out the target message for the latest (or return an error)
                    // This avoids cases where older edits could be deleted and
                    // leave newer revisions
                    if let latestEdit = DependenciesBridge.shared.editMessageStore.findMessage(
                        fromEdit: incomingMessageToDelete,
                        tx: transaction.asV2Read) as? TSIncomingMessage {
                        incomingMessageToDelete = latestEdit
                    } else {
                        Logger.info("Ignoring delete for missing edit target.")
                        return .invalidDelete
                    }
                }

                guard let messageToDeleteServerTimestamp = incomingMessageToDelete.serverTimestamp?.uint64Value else {
                    // Older messages might be missing this, but since we only allow deleting for a small
                    // window after you send a message we should generally never hit this path.
                    owsFailDebug("can't delete a message without a serverTimestamp")
                    return .invalidDelete
                }

                guard messageToDeleteServerTimestamp < serverTimestamp else {
                    owsFailDebug("Can't delete a message from the future.")
                    return .invalidDelete
                }

                guard serverTimestamp - messageToDeleteServerTimestamp < (2 * kDayInMs) else {
                    owsFailDebug("Ignoring message delete sent more than 48 hours after the original message")
                    return .invalidDelete
                }

                incomingMessageToDelete.markMessageAsRemotelyDeleted(transaction: transaction)

                return .success
            } else {
                owsFailDebug("Only incoming messages can be deleted remotely")
                return .invalidDelete
            }
        } else if let storyMessage = StoryFinder.story(
            timestamp: sentAtTimestamp,
            author: authorAci,
            transaction: transaction
        ) {
            // If there are still valid contexts for this outgoing private story message, don't actually delete the model.
            if storyMessage.groupId == nil,
               case .outgoing(let recipientStates) = storyMessage.manifest,
               !recipientStates.values.flatMap({ $0.contexts }).isEmpty {
                return .success
            }

            storyMessage.anyRemove(transaction: transaction)

            return .success
        } else {
            // The message doesn't exist locally, so nothing to do.
            Logger.info("Attempted to remotely delete a message that doesn't exist \(sentAtTimestamp)")
            return .deletedMessageMissing
        }

    }

    private func markMessageAsRemotelyDeleted(transaction: SDSAnyWriteTransaction) {

        // Delete the current interaction
        updateWithRemotelyDeletedAndRemoveRenderableContent(with: transaction)

        // Delete any past edit revisions.
        try! processEdits(transaction: transaction) { record, message in
            message?.updateWithRemotelyDeletedAndRemoveRenderableContent(with: transaction)
        }
        Self.notificationsManager.cancelNotifications(messageIds: [self.uniqueId])
    }

    // MARK: - Preview text

    @objc(previewTextForGiftBadgeWithTransaction:)
    func previewTextForGiftBadge(transaction: SDSAnyReadTransaction) -> String {
        if let incomingMessage = self as? TSIncomingMessage {
            let senderShortName = contactsManager.displayName(
                for: incomingMessage.authorAddress, tx: transaction
            ).resolvedValue(useShortNameIfAvailable: true)
            let format = OWSLocalizedString(
                "DONATION_ON_BEHALF_OF_A_FRIEND_PREVIEW_INCOMING",
                comment: "A friend has donated on your behalf. This text is shown in the list of chats, when the most recent message is one of these donations. Embeds {friend's short display name}."
            )
            return String(format: format, senderShortName)
        } else if let outgoingMessage = self as? TSOutgoingMessage {
            let recipientShortName: String
            let recipients = outgoingMessage.recipientAddresses()
            if let recipient = recipients.first, recipients.count == 1 {
                recipientShortName = contactsManager.displayName(
                    for: recipient, tx: transaction
                ).resolvedValue(useShortNameIfAvailable: true)
            } else {
                owsFailDebug("[Gifting] Expected exactly 1 recipient but got \(recipients.count)")
                recipientShortName = OWSLocalizedString(
                    "UNKNOWN_USER",
                    comment: "Label indicating an unknown user."
                )
            }
            let format = OWSLocalizedString(
                "DONATION_ON_BEHALF_OF_A_FRIEND_PREVIEW_OUTGOING",
                comment: "You have a made a donation on a friend's behalf. This text is shown in the list of chats, when the most recent message is one of these donations. Embeds {friend's short display name}."
            )
            return String(format: format, recipientShortName)
        } else {
            owsFail("Could not generate preview text because message wasn't incoming or outgoing")
        }
    }

    func notificationPreviewText(_ tx: SDSAnyReadTransaction) -> String {
        switch previewText(tx) {
        case let .body(body, prefix, ranges):
            let hydrated = MessageBody(text: body, ranges: ranges ?? .empty)
                .hydrating(mentionHydrator: ContactsMentionHydrator.mentionHydrator(transaction: tx.asV2Read))
                .asPlaintext()
            guard let prefix else {
                return hydrated.filterForDisplay
            }
            return prefix.appending(hydrated).filterForDisplay
        case let .remotelyDeleted(text),
            let .storyReactionEmoji(text),
            let .viewOnceMessage(text),
            let .contactShare(text),
            let .stickerDescription(text),
            let .giftBadge(text),
            let .infoMessage(text),
            let .paymentMessage(text):
            return text
        case .empty:
            return ""
        }
    }

    func conversationListPreviewText(_ tx: SDSAnyReadTransaction) -> HydratedMessageBody {
        switch previewText(tx) {
        case let .body(body, prefix, ranges):
            let hydrated = MessageBody(text: body, ranges: ranges ?? .empty)
                .hydrating(mentionHydrator: ContactsMentionHydrator.mentionHydrator(transaction: tx.asV2Read))
            guard let prefix else {
                return hydrated
            }
            return hydrated.addingPrefix(prefix)
        case let .remotelyDeleted(text),
            let .storyReactionEmoji(text),
            let .viewOnceMessage(text),
            let .contactShare(text),
            let .stickerDescription(text),
            let .giftBadge(text),
            let .infoMessage(text),
            let .paymentMessage(text):
            return HydratedMessageBody.fromPlaintextWithoutRanges(text)
        case .empty:
            return HydratedMessageBody.fromPlaintextWithoutRanges("")
        }
    }

    func conversationListSearchResultsBody(_ tx: SDSAnyReadTransaction) -> MessageBody? {
        switch previewText(tx) {
        case let .body(body, _, ranges):
            // We ignore the prefix here.
            return MessageBody(text: body, ranges: ranges ?? .empty)
        case .remotelyDeleted,
            .storyReactionEmoji,
            .viewOnceMessage,
            .contactShare,
            .stickerDescription,
            .giftBadge,
            .infoMessage,
            .paymentMessage,
            .empty:
            return nil
        }
    }

    private enum PreviewText {
        case body(String, prefix: String?, ranges: MessageBodyRanges?)
        case remotelyDeleted(String)
        case storyReactionEmoji(String)
        case viewOnceMessage(String)
        case contactShare(String)
        case stickerDescription(String)
        case giftBadge(String)
        case infoMessage(String)
        case paymentMessage(String)
        case empty
    }

    private func previewText(_ tx: SDSAnyReadTransaction) -> PreviewText {
        if let infoMessage = self as? TSInfoMessage {
            return .infoMessage(infoMessage.infoMessagePreviewText(with: tx))
        }

        if self is OWSPaymentMessage {
            return .paymentMessage(OWSLocalizedString(
                "PAYMENTS_THREAD_PREVIEW_TEXT",
                comment: "Payments Preview Text shown in chat list for payments."
            ))
        }

        if self.wasRemotelyDeleted {
            return .remotelyDeleted((self is TSIncomingMessage)
                ? OWSLocalizedString("THIS_MESSAGE_WAS_DELETED", comment: "text indicating the message was remotely deleted")
                : OWSLocalizedString("YOU_DELETED_THIS_MESSAGE", comment: "text indicating the message was remotely deleted by you")
            )
        }

        let bodyDescription = self.rawBody(transaction: tx)
        if
            bodyDescription == nil,
            let storyReactionEmoji,
            storyReactionEmoji.isEmpty.negated
        {
            if let storyAuthorAddress, storyAuthorAddress.isLocalAddress.negated {
                let storyAuthorName = self.contactsManager.displayName(for: storyAuthorAddress, tx: tx)
                return .storyReactionEmoji(String(
                    format: OWSLocalizedString(
                        "STORY_REACTION_REMOTE_AUTHOR_PREVIEW_FORMAT",
                        comment: "inbox and notification text for a reaction to a story authored by another user. Embeds {{ %1$@ reaction emoji, %2$@ story author name }}"
                    ),
                    storyReactionEmoji,
                    storyAuthorName.resolvedValue(useShortNameIfAvailable: true)
                ))
            } else {
                return .storyReactionEmoji(String(
                    format: OWSLocalizedString(
                        "STORY_REACTION_LOCAL_AUTHOR_PREVIEW_FORMAT",
                        comment: "inbox and notification text for a reaction to a story authored by the local user. Embeds {{reaction emoji}}"
                    ),
                    storyReactionEmoji
                ))
            }
        }

        let mediaAttachment = self.mediaAttachments(transaction: tx).first
        let attachmentEmoji = mediaAttachment?.emoji(forContainingMessage: self, transaction: tx)
        let attachmentDescription = mediaAttachment?.previewText(forContainingMessage: self, transaction: tx)

        if isViewOnceMessage {
            if self is TSOutgoingMessage || mediaAttachment == nil {
                return .viewOnceMessage(OWSLocalizedString(
                    "PER_MESSAGE_EXPIRATION_NOT_VIEWABLE",
                    comment: "inbox cell and notification text for an already viewed view-once media message."
                ))
            } else if mediaAttachment?.isVideoMimeType == true {
                return .viewOnceMessage(OWSLocalizedString(
                    "PER_MESSAGE_EXPIRATION_VIDEO_PREVIEW",
                    comment: "inbox cell and notification text for a view-once video."
                ))
            } else {
                // Make sure that if we add new types we cover them here.
                switch mediaAttachment?.getAnimatedMimeType() {
                case nil, .notAnimated:
                    owsAssertDebug(
                        mediaAttachment?.isImageMimeType == true
                        || mediaAttachment?.isLoopingVideo(inContainingMessage: self, transaction: tx) == true
                    )
                case .maybeAnimated, .animated:
                    break
                }

                return .viewOnceMessage(OWSLocalizedString(
                    "PER_MESSAGE_EXPIRATION_PHOTO_PREVIEW",
                    comment: "inbox cell and notification text for a view-once photo."
                ))
            }
        }

        if let bodyDescription = bodyDescription?.nilIfEmpty {
            return .body(bodyDescription, prefix: attachmentEmoji?.nilIfEmpty?.appending(" "), ranges: bodyRanges)
        } else if let attachmentDescription = attachmentDescription?.nilIfEmpty {
            return .body(attachmentDescription, prefix: nil, ranges: bodyRanges)
        } else if let contactShare {
            return .contactShare("👤".appending(" ").appending(contactShare.name.displayName))
        } else if let messageSticker {
            let stickerDescription = OWSLocalizedString(
                "STICKER_MESSAGE_PREVIEW",
                comment: "Preview text shown in notifications and conversation list for sticker messages."
            )
            if let stickerEmoji = StickerManager.firstEmoji(inEmojiString: messageSticker.emoji)?.nilIfEmpty {
                return .stickerDescription(stickerEmoji.appending(" ").appending(stickerDescription))
            } else {
                return .stickerDescription(stickerDescription)
            }
        } else if giftBadge != nil {
            return .giftBadge(self.previewTextForGiftBadge(transaction: tx))
        } else {
            // This can happen when initially saving outgoing messages
            // with camera first capture over the conversation list.
            return .empty
        }
    }

    // MARK: - Stories

    @objc
    enum ReplyCountIncrement: Int {
        case noIncrement
        case newReplyAdded
        case replyDeleted
    }

    @objc
    func touchStoryMessageIfNecessary(
        replyCountIncrement: ReplyCountIncrement,
        transaction: SDSAnyWriteTransaction
    ) {
        guard
            self.isStoryReply,
            let storyAuthorAci,
            let storyTimestamp
        else {
            return
        }
        let storyMessage = StoryFinder.story(
            timestamp: storyTimestamp.uint64Value,
            author: storyAuthorAci.wrappedAciValue,
            transaction: transaction
        )
        if let storyMessage {
            // Note that changes are aggregated; the touch below won't double
            // up observer notifications.
            self.databaseStorage.touch(storyMessage: storyMessage, transaction: transaction)
            switch replyCountIncrement {
            case .noIncrement:
                break
            case .newReplyAdded:
                storyMessage.incrementReplyCount(transaction)
            case .replyDeleted:
                storyMessage.decrementReplyCount(transaction)
            }
        }
    }

    // MARK: - Indexing

    @objc
    internal func _anyDidInsert(tx: SDSAnyWriteTransaction) {
        FullTextSearchIndexer.insert(self, tx: tx)
    }

    @objc
    internal func _anyDidUpdate(tx: SDSAnyWriteTransaction) {
        FullTextSearchIndexer.update(self, tx: tx)
    }

    @objc
    internal func _anyDidRemove(tx: SDSAnyWriteTransaction) {
        FullTextSearchIndexer.delete(self, tx: tx)

        if !self.attachmentIds.isEmpty {
            MediaGalleryRecordManager.recordTimestamp(forRemovedMessage: self, transaction: tx)
        }
    }
}

// MARK: - Renderable content

extension TSMessage {

    /// Unsafe to use before insertion; until attachments are inserted (which happens after message insertion)
    /// this may not return accurate results.
    public func insertedMessageHasRenderableContent(
        rowId: Int64,
        tx: SDSAnyReadTransaction
    ) -> Bool {
        var fetchedAttachments: [TSResourceReference]?
        func fetchAttachments() -> [TSResourceReference] {
            if let fetchedAttachments { return fetchedAttachments }
            let attachments = DependenciesBridge.shared.tsResourceStore.bodyAttachments(
                for: self,
                tx: tx.asV2Read
            )
            fetchedAttachments = attachments
            return attachments
        }

        return TSMessageBuilder.hasRenderableContent(
            hasNonemptyBody: body?.nilIfEmpty != nil,
            hasBodyAttachmentsOrOversizeText: fetchAttachments().isEmpty.negated,
            hasLinkPreview: linkPreview != nil,
            hasQuotedReply: quotedMessage != nil,
            hasContactShare: contactShare != nil,
            hasSticker: messageSticker != nil,
            hasGiftBadge: giftBadge != nil,
            isStoryReply: isStoryReply,
            storyReactionEmoji: storyReactionEmoji
        )
    }
}

extension TSMessageBuilder {

    public func hasRenderableContent(
        hasBodyAttachments: Bool,
        hasLinkPreview: Bool,
        hasQuotedReply: Bool,
        hasContactShare: Bool,
        hasSticker: Bool
    ) -> Bool {
        return Self.hasRenderableContent(
            hasNonemptyBody: messageBody?.nilIfEmpty != nil,
            hasBodyAttachmentsOrOversizeText: hasBodyAttachments,
            hasLinkPreview: hasLinkPreview,
            hasQuotedReply: hasQuotedReply,
            hasContactShare: hasContactShare,
            hasSticker: hasSticker,
            hasGiftBadge: giftBadge != nil,
            isStoryReply: storyAuthorAci != nil && storyTimestamp != nil,
            storyReactionEmoji: storyReactionEmoji
        )
    }

    public static func hasRenderableContent(
        hasNonemptyBody: Bool,
        hasBodyAttachmentsOrOversizeText: @autoclosure () -> Bool,
        hasLinkPreview: Bool,
        hasQuotedReply: Bool,
        hasContactShare: Bool,
        hasSticker: Bool,
        hasGiftBadge: Bool,
        isStoryReply: Bool,
        storyReactionEmoji: String?
    ) -> Bool {
        // Story replies currently only support a subset of message features, so may not
        // be renderable in some circumstances where a normal message would be.
        if isStoryReply {
            return hasNonemptyBody || (storyReactionEmoji?.isSingleEmoji ?? false)
        }

        // We DO NOT consider a message with just a linkPreview
        // or quotedMessage to be renderable.
        if hasNonemptyBody || hasContactShare || hasSticker || hasGiftBadge {
            return true
        }

        if hasBodyAttachmentsOrOversizeText() {
            return true
        }

        return false
    }
}
