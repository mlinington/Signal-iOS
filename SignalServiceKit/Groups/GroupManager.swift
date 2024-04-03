//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient
import SignalCoreKit

// * The "local" methods are used in response to the local user's interactions.
// * The "remote" methods are used in response to remote activity (incoming messages,
//   sync transcripts, group syncs, etc.).
@objc
public class GroupManager: NSObject {

    // Never instantiate this class.
    private override init() {}

    // MARK: -

    // GroupsV2 TODO: Finalize this value with the designers.
    public static let groupUpdateTimeoutDuration: TimeInterval = 30

    public static var groupsV2MaxGroupSizeRecommended: UInt {
        return RemoteConfig.groupsV2MaxGroupSizeRecommended
    }

    public static var groupsV2MaxGroupSizeHardLimit: UInt {
        return RemoteConfig.groupsV2MaxGroupSizeHardLimit
    }

    public static let maxGroupNameEncryptedByteCount: Int = 1024
    public static let maxGroupNameGlyphCount: Int = 32

    public static let maxGroupDescriptionEncryptedByteCount: Int = 8192
    public static let maxGroupDescriptionGlyphCount: Int = 480

    // Epoch 1: Group Links
    // Epoch 2: Group Description
    // Epoch 3: Announcement-Only Groups
    // Epoch 4: Banned Members
    // Epoch 5: Promote pending PNI members
    public static let changeProtoEpoch: UInt32 = 5

    // This matches kOversizeTextMessageSizeThreshold.
    public static let maxEmbeddedChangeProtoLength: UInt = 2 * 1024

    // MARK: - Group IDs

    static func groupIdLength(for groupsVersion: GroupsVersion) -> Int32 {
        switch groupsVersion {
        case .V1:
            return kGroupIdLengthV1
        case .V2:
            return kGroupIdLengthV2
        }
    }

    @objc
    public static func isV1GroupId(_ groupId: Data) -> Bool {
        groupId.count == groupIdLength(for: .V1)
    }

    @objc
    public static func isV2GroupId(_ groupId: Data) -> Bool {
        groupId.count == groupIdLength(for: .V2)
    }

    @objc
    public static func isValidGroupId(_ groupId: Data, groupsVersion: GroupsVersion) -> Bool {
        let expectedLength = groupIdLength(for: groupsVersion)
        guard groupId.count == expectedLength else {
            owsFailDebug("Invalid groupId: \(groupId.count) != \(expectedLength)")
            return false
        }
        return true
    }

    @objc
    public static func isValidGroupIdOfAnyKind(_ groupId: Data) -> Bool {
        return isV1GroupId(groupId) || isV2GroupId(groupId)
    }

    // MARK: -

    public static func canLocalUserLeaveGroupWithoutChoosingNewAdmin(
        localAci: Aci,
        groupMembership: GroupMembership
    ) -> Bool {
        let fullMembers = Set(groupMembership.fullMembers.compactMap { $0.serviceId as? Aci })
        let fullMemberAdmins = Set(groupMembership.fullMemberAdministrators.compactMap { $0.serviceId as? Aci })
        return canLocalUserLeaveGroupWithoutChoosingNewAdmin(
            localAci: localAci,
            fullMembers: fullMembers,
            admins: fullMemberAdmins
        )
    }

    public static func canLocalUserLeaveGroupWithoutChoosingNewAdmin(
        localAci: Aci,
        fullMembers: Set<Aci>,
        admins: Set<Aci>
    ) -> Bool {
        // If the current user is the only admin and they're not the only member of
        // the group, then they must select a new admin.
        if Set([localAci]) == admins && Set([localAci]) != fullMembers {
            return false
        }
        return true
    }

    // MARK: - Group Models

    @objc
    public static func fakeGroupModel(groupId: Data) -> TSGroupModel? {
        do {
            var builder = TSGroupModelBuilder()
            builder.groupId = groupId

            if GroupManager.isV1GroupId(groupId) {
                builder.groupsVersion = .V1
            } else if GroupManager.isV2GroupId(groupId) {
                builder.groupsVersion = .V2
            } else {
                throw OWSAssertionError("Invalid group id: \(groupId).")
            }

            return try builder.build()
        } catch {
            owsFailDebug("Error: \(error)")
            return nil
        }
    }

    /// Confirms that a given address supports V2 groups.
    ///
    /// This check will succeed for any currently-registered users. It is
    /// possible that contacts dating from the V1 group era will fail this
    /// check.
    ///
    /// This method should only be used in contexts in which it is possible we
    /// are dealing with very old historical contacts, and need to filter them
    /// for those that are GV2-compatible.
    public static func doesUserSupportGroupsV2(address: SignalServiceAddress) -> Bool {
        guard address.isValid else {
            Logger.warn("Invalid address: \(address).")
            return false
        }

        guard address.serviceId != nil else {
            Logger.warn("Member without UUID.")
            return false
        }

        return true
    }

    // MARK: - Create New Group

    /// Create a new group locally, and upload it to the service.
    ///
    /// - Parameter groupId
    /// A fixed group ID. Intended for use exclusively in tests.
    public static func localCreateNewGroup(
        members membersParam: [SignalServiceAddress],
        groupId: Data? = nil,
        name: String? = nil,
        avatarData: Data? = nil,
        disappearingMessageToken: DisappearingMessageToken,
        newGroupSeed: NewGroupSeed? = nil,
        shouldSendMessage: Bool
    ) async throws -> TSGroupThread {
        guard let localIdentifiers = DependenciesBridge.shared.tsAccountManager.localIdentifiersWithMaybeSneakyTransaction else {
            throw OWSAssertionError("Missing localIdentifiers.")
        }

        try await ensureLocalProfileHasCommitmentIfNecessary()

        // Build member list.
        //
        // The group creator is an administrator;
        // the other members are normal users.
        var builder = GroupMembership.Builder()
        builder.addFullMembers(Set(membersParam), role: .normal)
        builder.remove(localIdentifiers.aci)
        builder.addFullMember(localIdentifiers.aci, role: .administrator)
        let initialGroupMembership = builder.build()

        // Try to get profile key credentials for all group members, since
        // we need them to fully add (rather than merely inviting) members.
        try await groupsV2.tryToFetchProfileKeyCredentials(
            for: initialGroupMembership.allMembersOfAnyKind.compactMap { $0.serviceId as? Aci },
            ignoreMissingProfiles: false,
            forceRefresh: false
        )

        let groupAccess = GroupAccess.defaultForV2
        let separatedGroupMembership = databaseStorage.read { tx in
            // Before we create the group, we need to separate out the
            // pending and full members.
            return separateInvitedMembersForNewGroup(
                withMembership: initialGroupMembership,
                transaction: tx
            )
        }

        guard separatedGroupMembership.isFullMember(localIdentifiers.aci) else {
            throw OWSAssertionError("Local ACI is missing from group membership.")
        }

        // The avatar URL path will be filled in later.
        var groupModelBuilder = TSGroupModelBuilder()
        groupModelBuilder.groupId = groupId
        groupModelBuilder.name = name
        groupModelBuilder.avatarData = avatarData
        groupModelBuilder.avatarUrlPath = nil
        groupModelBuilder.groupMembership = separatedGroupMembership
        groupModelBuilder.groupAccess = groupAccess
        groupModelBuilder.newGroupSeed = newGroupSeed
        var proposedGroupModel = try groupModelBuilder.buildAsV2()

        if let avatarData = avatarData {
            // Upload avatar.
            let avatarUrlPath = try await groupsV2.uploadGroupAvatar(
                avatarData: avatarData,
                groupSecretParamsData: proposedGroupModel.secretParamsData
            )

            // Fill in the avatarUrl on the group model.
            var builder = proposedGroupModel.asBuilder
            builder.avatarUrlPath = avatarUrlPath
            proposedGroupModel = try builder.buildAsV2()
        }

        try await groupsV2.createNewGroupOnService(
            groupModel: proposedGroupModel,
            disappearingMessageToken: disappearingMessageToken
        )

        let groupV2Snapshot = try await groupsV2.fetchCurrentGroupV2Snapshot(
            groupModel: proposedGroupModel
        )

        let thread = try await databaseStorage.awaitableWrite { tx in
            let builder = try TSGroupModelBuilder.builderForSnapshot(
                groupV2Snapshot: groupV2Snapshot,
                transaction: tx
            )
            let groupModel = try builder.buildAsV2()

            if proposedGroupModel != groupModel {
                owsFailDebug("Proposed group model does not match created group model.")
            }

            let thread = self.insertGroupThreadInDatabaseAndCreateInfoMessage(
                groupModel: groupModel,
                disappearingMessageToken: disappearingMessageToken,
                groupUpdateSource: .localUser(originalSource: .aci(localIdentifiers.aci)),
                localIdentifiers: localIdentifiers,
                spamReportingMetadata: .createdByLocalAction,
                transaction: tx
            )
            self.profileManager.addThread(toProfileWhitelist: thread, transaction: tx)
            return thread
        }

        if shouldSendMessage {
            try await sendDurableNewGroupMessage(forThread: thread).awaitable()
        }
        return thread
    }

    // Separates pending and non-pending members.
    // We cannot add non-pending members unless:
    //
    // * We know their profile key.
    // * We have a profile key credential for them.
    private static func separateInvitedMembersForNewGroup(
        withMembership newGroupMembership: GroupMembership,
        transaction tx: SDSAnyReadTransaction
    ) -> GroupMembership {
        guard let localAci = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx.asV2Read)?.aci else {
            owsFailDebug("Missing localAci.")
            return newGroupMembership
        }
        var builder = GroupMembership.Builder()

        let newMembers = newGroupMembership.allMembersOfAnyKind

        // We only need to separate new members.
        for address in newMembers {
            // We must call this _after_ we try to fetch profile key credentials for
            // all members.
            let hasCredential = groupsV2.hasProfileKeyCredential(for: address, transaction: tx)
            guard let role = newGroupMembership.role(for: address) else {
                owsFailDebug("Missing role: \(address)")
                continue
            }

            guard let serviceId = address.serviceId else {
                owsFailDebug("Missing serviceId.")
                continue
            }

            if let aci = serviceId as? Aci, hasCredential {
                builder.addFullMember(aci, role: role)
            } else {
                builder.addInvitedMember(serviceId, role: role, addedByAci: localAci)
            }
        }
        return builder.build()
    }

    // MARK: - Tests

    #if TESTABLE_BUILD

    @objc
    public static func createGroupForTests(members: [SignalServiceAddress],
                                           name: String? = nil,
                                           avatarData: Data? = nil) throws -> TSGroupThread {

        return try databaseStorage.write { transaction in
            return try createGroupForTests(members: members,
                                           name: name,
                                           avatarData: avatarData,
                                           transaction: transaction)
        }
    }

    @objc
    public static func createGroupForTestsObjc(members: [SignalServiceAddress],
                                               name: String? = nil,
                                               avatarData: Data? = nil,
                                               transaction: SDSAnyWriteTransaction) -> TSGroupThread {
        do {
            return try createGroupForTests(members: members,
                                           name: name,
                                           avatarData: avatarData,
                                           groupsVersion: .V1, // Tests historically hardcode V1 groups.
                                           transaction: transaction)
        } catch {
            owsFail("Error: \(error)")
        }
    }

    public static func createGroupForTests(members: [SignalServiceAddress],
                                           name: String? = nil,
                                           descriptionText: String? = nil,
                                           avatarData: Data? = nil,
                                           groupId: Data? = nil,
                                           groupsVersion: GroupsVersion = .V1,
                                           transaction: SDSAnyWriteTransaction) throws -> TSGroupThread {

        guard let localIdentifiers = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: transaction.asV2Read) else {
            throw OWSAssertionError("Missing localIdentifiers.")
        }

        // GroupsV2 TODO: Elaborate tests to include admins, pending members, etc.
        let groupMembership = GroupMembership(v1Members: Set(members))
        // GroupsV2 TODO: Let tests specify access levels.
        // GroupsV2 TODO: Fill in avatarUrlPath when we test v2 groups.
        let groupAccess = GroupAccess.defaultForV1
        // Use buildGroupModel() to fill in defaults, like it was a new group.

        var builder = TSGroupModelBuilder()
        builder.groupId = groupId
        builder.name = name
        builder.descriptionText = descriptionText
        builder.avatarData = avatarData
        builder.avatarUrlPath = nil
        builder.groupMembership = groupMembership
        builder.groupAccess = groupAccess
        builder.groupsVersion = groupsVersion
        let groupModel = try builder.build()

        // Just create it in the database, don't create it on the service.
        return try remoteUpsertExistingGroupForTests(
            groupModel: groupModel,
            disappearingMessageToken: nil,
            groupUpdateSource: .localUser(originalSource: .aci(localIdentifiers.aci)),
            localIdentifiers: localIdentifiers,
            transaction: transaction
        )
    }

    // If disappearingMessageToken is nil, don't update the disappearing messages configuration.
    private static func remoteUpsertExistingGroupForTests(
        groupModel: TSGroupModel,
        disappearingMessageToken: DisappearingMessageToken?,
        groupUpdateSource: GroupUpdateSource,
        infoMessagePolicy: InfoMessagePolicy = .always,
        localIdentifiers: LocalIdentifiers,
        transaction: SDSAnyWriteTransaction
    ) throws -> TSGroupThread {
        owsAssertDebug(groupModel.groupsVersion == .V1)

        return try self.tryToUpsertExistingGroupThreadInDatabaseAndCreateInfoMessage(
            newGroupModel: groupModel,
            newDisappearingMessageToken: disappearingMessageToken,
            newlyLearnedPniToAciAssociations: [:],
            groupUpdateSource: groupUpdateSource,
            didAddLocalUserToV2Group: false,
            infoMessagePolicy: infoMessagePolicy,
            localIdentifiers: localIdentifiers,
            spamReportingMetadata: .unreportable,
            transaction: transaction
        )
    }

    #endif

    // MARK: - Disappearing Messages

    @objc
    public static func remoteUpdateDisappearingMessages(
        withContactThread thread: TSContactThread,
        disappearingMessageToken: DisappearingMessageToken,
        changeAuthor: AciObjC?,
        localIdentifiers: LocalIdentifiersObjC,
        transaction: SDSAnyWriteTransaction
    ) {
        let changeAuthor: GroupUpdateSource = {
            if let changeAuthor, changeAuthor.wrappedAciValue == localIdentifiers.aci.wrappedAciValue {
                return .localUser(originalSource: .aci(changeAuthor.wrappedAciValue))
            } else if let changeAuthor {
                return .aci(changeAuthor.wrappedAciValue)
            } else {
                return .unknown
            }
        }()
        _ = self.updateDisappearingMessagesInDatabaseAndCreateMessages(
            token: disappearingMessageToken,
            thread: thread,
            shouldInsertInfoMessage: true,
            changeAuthor: changeAuthor,
            transaction: transaction
        )
    }

    private static func localUpdateDisappearingMessageToken(
        _ disappearingMessageToken: DisappearingMessageToken,
        inContactOrGroupV1Thread thread: TSThread,
        tx: SDSAnyWriteTransaction
    ) {
        guard let localIdentifiers = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx.asV2Read) else {
            owsFailDebug("Not registered.")
            return
        }
        let updateResult = self.updateDisappearingMessagesInDatabaseAndCreateMessages(
            token: disappearingMessageToken,
            thread: thread,
            shouldInsertInfoMessage: true,
            changeAuthor: .localUser(originalSource: .aci(localIdentifiers.aci)),
            transaction: tx
        )
        self.sendDisappearingMessagesConfigurationMessage(
            updateResult: updateResult,
            thread: thread,
            transaction: tx
        )
    }

    public static func localUpdateDisappearingMessageToken(
        _ disappearingMessageToken: DisappearingMessageToken,
        inContactThread thread: TSContactThread,
        tx: SDSAnyWriteTransaction
    ) {
        localUpdateDisappearingMessageToken(disappearingMessageToken, inContactOrGroupV1Thread: thread, tx: tx)
    }

    public static func localUpdateDisappearingMessages(
        thread: TSThread,
        disappearingMessageToken: DisappearingMessageToken
    ) -> Promise<Void> {
        if let groupV2Model = (thread as? TSGroupThread)?.groupModel as? TSGroupModelV2 {
            return updateGroupV2(groupModel: groupV2Model, description: "Update disappearing messages") { changeSet in
                changeSet.setNewDisappearingMessageToken(disappearingMessageToken)
            }.asVoid()
        } else {
            return databaseStorage.write(.promise) { tx in
                localUpdateDisappearingMessageToken(disappearingMessageToken, inContactOrGroupV1Thread: thread, tx: tx)
            }
        }
    }

    private struct UpdateDMConfigurationResult {
        let oldConfiguration: OWSDisappearingMessagesConfiguration
        let newConfiguration: OWSDisappearingMessagesConfiguration
    }

    private static func updateDisappearingMessagesInDatabaseAndCreateMessages(
        token newToken: DisappearingMessageToken,
        thread: TSThread,
        shouldInsertInfoMessage: Bool,
        changeAuthor: GroupUpdateSource,
        transaction: SDSAnyWriteTransaction
    ) -> UpdateDMConfigurationResult {
        let dmConfigurationStore = DependenciesBridge.shared.disappearingMessagesConfigurationStore
        let result = dmConfigurationStore.set(token: newToken, for: .thread(thread), tx: transaction.asV2Write)

        // Skip redundant updates.
        if result.newConfiguration != result.oldConfiguration {
            if shouldInsertInfoMessage {

                let remoteContactName: String?
                switch changeAuthor {
                case .unknown, .localUser:
                    remoteContactName = nil
                case .legacyE164(let e164):
                    remoteContactName = contactsManager.displayName(
                        for: .legacyAddress(serviceId: nil, phoneNumber: e164.stringValue),
                        tx: transaction
                    ).resolvedValue()
                case .aci(let aci):
                    remoteContactName = contactsManager.displayName(
                        for: .init(aci),
                        tx: transaction
                    ).resolvedValue()
                case .rejectedInviteToPni(let pni):
                    remoteContactName = contactsManager.displayName(
                        for: .init(pni),
                        tx: transaction
                    ).resolvedValue()
                }

                let infoMessage = OWSDisappearingConfigurationUpdateInfoMessage(
                    thread: thread,
                    configuration: result.newConfiguration,
                    createdByRemoteName: remoteContactName,
                    createdInExistingGroup: false
                )
                infoMessage.anyInsert(transaction: transaction)
            }

            databaseStorage.touch(thread: thread, shouldReindex: false, transaction: transaction)
        }

        return UpdateDMConfigurationResult(
            oldConfiguration: result.oldConfiguration,
            newConfiguration: result.newConfiguration
        )
    }

    private static func sendDisappearingMessagesConfigurationMessage(
        updateResult: UpdateDMConfigurationResult,
        thread: TSThread,
        transaction: SDSAnyWriteTransaction
    ) {
        guard updateResult.newConfiguration != updateResult.oldConfiguration else {
            // The update was redundant, don't send an update message.
            return
        }
        guard !thread.isGroupV2Thread else {
            // Don't send DM configuration messages for v2 groups.
            return
        }
        let newConfiguration = updateResult.newConfiguration
        let message = OWSDisappearingMessagesConfigurationMessage(configuration: newConfiguration, thread: thread, transaction: transaction)
        SSKEnvironment.shared.messageSenderJobQueueRef.add(message: message.asPreparer, transaction: transaction)
    }

    // MARK: - Accept Invites

    public static func localAcceptInviteToGroupV2(
        groupModel: TSGroupModelV2,
        waitForMessageProcessing: Bool = false
    ) -> Promise<TSGroupThread> {
        firstly { () -> Promise<Void> in
            if waitForMessageProcessing {
                return GroupManager.messageProcessingPromise(for: groupModel, description: "Accept invite")
            }

            return Promise.value(())
        }.then { () -> Promise<Void> in
            self.databaseStorage.write(.promise) { transaction in
                self.profileManager.addGroupId(toProfileWhitelist: groupModel.groupId,
                                               userProfileWriter: .localUser,
                                               transaction: transaction)
            }
        }.then(on: DispatchQueue.global()) { _ -> Promise<TSGroupThread> in
            return updateGroupV2(
                groupModel: groupModel,
                description: "Accept invite"
            ) { groupChangeSet in
                groupChangeSet.setLocalShouldAcceptInvite()
            }
        }
    }

    // MARK: - Leave Group / Decline Invite

    public static func localLeaveGroupOrDeclineInvite(
        groupThread: TSGroupThread,
        replacementAdminAci: Aci? = nil,
        waitForMessageProcessing: Bool = false,
        tx: SDSAnyWriteTransaction
    ) -> Promise<TSGroupThread> {
        return SSKEnvironment.shared.localUserLeaveGroupJobQueueRef.addJob(
            groupThread: groupThread,
            replacementAdminAci: replacementAdminAci,
            waitForMessageProcessing: waitForMessageProcessing,
            tx: tx
        )
    }

    @objc
    public static func leaveGroupOrDeclineInviteAsyncWithoutUI(groupThread: TSGroupThread,
                                                               transaction: SDSAnyWriteTransaction,
                                                               success: (() -> Void)?) {

        guard groupThread.isLocalUserMemberOfAnyKind else {
            owsFailDebug("unexpectedly trying to leave group for which we're not a member.")
            return
        }

        transaction.addAsyncCompletionOffMain {
            firstly {
                databaseStorage.write(.promise) { transaction in
                    self.localLeaveGroupOrDeclineInvite(groupThread: groupThread, tx: transaction).asVoid()
                }
            }.done { _ in
                success?()
            }.catch { error in
                owsFailDebug("Leave group failed: \(error)")
            }
        }
    }

    // MARK: - Remove From Group / Revoke Invite

    public static func removeFromGroupOrRevokeInviteV2(
        groupModel: TSGroupModelV2,
        serviceIds: [ServiceId]
    ) -> Promise<TSGroupThread> {
        updateGroupV2(groupModel: groupModel, description: "Remove from group or revoke invite") { groupChangeSet in
            for serviceId in serviceIds {
                owsAssertDebug(!groupModel.groupMembership.isRequestingMember(serviceId))

                groupChangeSet.removeMember(serviceId)

                // Do not ban when revoking an invite
                if let aci = serviceId as? Aci, !groupModel.groupMembership.isInvitedMember(serviceId) {
                    groupChangeSet.addBannedMember(aci)
                }
            }
        }
    }

    public static func revokeInvalidInvites(groupModel: TSGroupModelV2) -> Promise<TSGroupThread> {
        updateGroupV2(groupModel: groupModel,
                      description: "Revoke invalid invites") { groupChangeSet in
            groupChangeSet.revokeInvalidInvites()
        }
    }

    // MARK: - Change Member Role

    public static func changeMemberRoleV2(
        groupModel: TSGroupModelV2,
        aci: Aci,
        role: TSGroupMemberRole
    ) -> Promise<TSGroupThread> {
        updateGroupV2(groupModel: groupModel, description: "Change member role") { groupChangeSet in
            groupChangeSet.changeRoleForMember(aci, role: role)
        }
    }

    // MARK: - Change Group Access

    public static func changeGroupAttributesAccessV2(groupModel: TSGroupModelV2,
                                                     access: GroupV2Access) -> Promise<TSGroupThread> {
        updateGroupV2(groupModel: groupModel,
                      description: "Change group attributes access") { groupChangeSet in
            groupChangeSet.setAccessForAttributes(access)
        }
    }

    public static func changeGroupMembershipAccessV2(groupModel: TSGroupModelV2,
                                                     access: GroupV2Access) -> Promise<TSGroupThread> {
        updateGroupV2(groupModel: groupModel,
                      description: "Change group membership access") { groupChangeSet in
            groupChangeSet.setAccessForMembers(access)
        }
    }

    // MARK: - Group Links

    public static func updateLinkModeV2(groupModel: TSGroupModelV2,
                                        linkMode: GroupsV2LinkMode) -> Promise<TSGroupThread> {
        updateGroupV2(groupModel: groupModel,
                      description: "Change group link mode") { groupChangeSet in
            groupChangeSet.setLinkMode(linkMode)
        }
    }

    public static func resetLinkV2(groupModel: TSGroupModelV2) -> Promise<TSGroupThread> {
        updateGroupV2(groupModel: groupModel,
                      description: "Rotate invite link password") { groupChangeSet in
            groupChangeSet.rotateInviteLinkPassword()
        }
    }

    public static let inviteLinkPasswordLengthV2: UInt = 16

    public static func generateInviteLinkPasswordV2() -> Data {
        Cryptography.generateRandomBytes(inviteLinkPasswordLengthV2)
    }

    public static func groupInviteLink(forGroupModelV2 groupModelV2: TSGroupModelV2) throws -> URL {
        try groupsV2.groupInviteLink(forGroupModelV2: groupModelV2)
    }

    @objc
    public static func isPossibleGroupInviteLink(_ url: URL) -> Bool {
        let possibleHosts: [String]
        if url.scheme == "https" {
            possibleHosts = ["signal.group"]
        } else {
            return false
        }
        guard let host = url.host else {
            return false
        }
        return possibleHosts.contains(host)
    }

    @objc
    public static func parseGroupInviteLink(_ url: URL) -> GroupInviteLinkInfo? {
        groupsV2.parseGroupInviteLink(url)
    }

    public static func joinGroupViaInviteLink(
        groupId: Data,
        groupSecretParamsData: Data,
        inviteLinkPassword: Data,
        groupInviteLinkPreview: GroupInviteLinkPreview,
        avatarData: Data?
    ) async throws -> TSGroupThread {
        try await ensureLocalProfileHasCommitmentIfNecessary()
        let groupThread = try await NSObject.groupsV2.joinGroupViaInviteLink(
            groupId: groupId,
            groupSecretParamsData: groupSecretParamsData,
            inviteLinkPassword: inviteLinkPassword,
            groupInviteLinkPreview: groupInviteLinkPreview,
            avatarData: avatarData
        )

        await NSObject.databaseStorage.awaitableWrite { transaction in
            NSObject.profileManager.addGroupId(
                toProfileWhitelist: groupId,
                userProfileWriter: .localUser,
                transaction: transaction
            )
        }
        return groupThread
    }

    public static func acceptOrDenyMemberRequestsV2(
        groupModel: TSGroupModelV2,
        aci: Aci,
        shouldAccept: Bool
    ) -> Promise<TSGroupThread> {
        let description = (shouldAccept ? "Accept group member request" : "Deny group member request")
        return updateGroupV2(groupModel: groupModel, description: description) { groupChangeSet in
            if shouldAccept {
                groupChangeSet.addMember(aci, role: .`normal`)
            } else {
                groupChangeSet.removeMember(aci)
                groupChangeSet.addBannedMember(aci)
            }
        }
    }

    public static func cancelMemberRequestsV2(groupModel: TSGroupModelV2) -> Promise<TSGroupThread> {

        let description = "Cancel Member Request"

        return firstly(on: DispatchQueue.global()) {
            Promise.wrapAsync {
                try await self.groupsV2.cancelMemberRequests(groupModel: groupModel)
            }
        }.timeout(seconds: Self.groupUpdateTimeoutDuration, description: description) {
            GroupsV2Error.timeout
        }
    }

    @objc
    public static func cachedGroupInviteLinkPreview(groupInviteLinkInfo: GroupInviteLinkInfo) -> GroupInviteLinkPreview? {
        do {
            let groupContextInfo = try self.groupsV2.groupV2ContextInfo(forMasterKeyData: groupInviteLinkInfo.masterKey)
            return groupsV2.cachedGroupInviteLinkPreview(groupSecretParamsData: groupContextInfo.groupSecretParamsData)
        } catch {
            owsFailDebug("Error: \(error)")
            return nil
        }
    }

    // MARK: - Announcements

    public static func setIsAnnouncementsOnly(groupModel: TSGroupModelV2,
                                              isAnnouncementsOnly: Bool) -> Promise<TSGroupThread> {
        updateGroupV2(groupModel: groupModel,
                      description: "Update isAnnouncementsOnly") { groupChangeSet in
            groupChangeSet.setIsAnnouncementsOnly(isAnnouncementsOnly)
        }
    }

    // MARK: - Local profile key

    public static func updateLocalProfileKey(groupModel: TSGroupModelV2) -> Promise<TSGroupThread> {
        updateGroupV2(groupModel: groupModel, description: "Update local profile key") { changes in
            changes.setShouldUpdateLocalProfileKey()
        }
    }

    // MARK: - Removed from Group or Invite Revoked

    public static func handleNotInGroup(groupId: Data, transaction: SDSAnyWriteTransaction) {
        guard let localIdentifiers = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: transaction.asV2Read) else {
            owsFailDebug("Missing localIdentifiers.")
            return
        }
        guard let groupThread = TSGroupThread.fetch(groupId: groupId, transaction: transaction) else {
            // Local user may have just deleted the thread via the UI.
            // Or we maybe be trying to restore a group from storage service
            // that we are no longer a member of.
            Logger.warn("Missing group in database.")
            return
        }

        let groupModel = groupThread.groupModel

        let removeLocalUserBlock: (SDSAnyWriteTransaction) -> Void = { transaction in
            // Remove local user from group.
            // We do _not_ bump the revision number since this (unlike all other
            // changes to group state) is inferred from a 403. This is fine; if
            // we're ever re-added to the group the groups v2 machinery will
            // recover.
            var groupMembershipBuilder = groupModel.groupMembership.asBuilder
            groupMembershipBuilder.remove(localIdentifiers.aci)
            var groupModelBuilder = groupModel.asBuilder
            do {
                groupModelBuilder.groupMembership = groupMembershipBuilder.build()
                let newGroupModel = try groupModelBuilder.build()

                // groupUpdateSource is unknown because we don't (and can't) know who removed
                // us or revoked our invite.
                //
                // newDisappearingMessageToken is nil because we don't want to change DM
                // state.
                _ = try updateExistingGroupThreadInDatabaseAndCreateInfoMessage(
                    newGroupModel: newGroupModel,
                    newDisappearingMessageToken: nil,
                    newlyLearnedPniToAciAssociations: [:],
                    groupUpdateSource: .unknown,
                    infoMessagePolicy: .always,
                    localIdentifiers: localIdentifiers,
                    spamReportingMetadata: .createdByLocalAction,
                    transaction: transaction
                )
            } catch {
                owsFailDebug("Error: \(error)")
            }
        }

        if
            let groupModelV2 = groupModel as? TSGroupModelV2,
            groupModelV2.isJoinRequestPlaceholder
        {
            Logger.warn("Ignoring 403 for placeholder group.")
            Task {
                try? await groupsV2.tryToUpdatePlaceholderGroupModelUsingInviteLinkPreview(
                    groupModel: groupModelV2,
                    removeLocalUserBlock: removeLocalUserBlock
                )
            }
        } else {
            removeLocalUserBlock(transaction)
        }
    }

    // MARK: - Messages

    public static func sendGroupUpdateMessage(thread: TSGroupThread,
                                              changeActionsProtoData: Data? = nil) -> Promise<Void> {
        guard thread.isGroupV2Thread else {
            owsFail("[GV1] Should be impossible to send V1 group messages!")
        }

        return databaseStorage.write(.promise) { transaction in
            let dmConfigurationStore = DependenciesBridge.shared.disappearingMessagesConfigurationStore

            let message = OutgoingGroupUpdateMessage(
                in: thread,
                groupMetaMessage: .update,
                expiresInSeconds: dmConfigurationStore.durationSeconds(for: thread, tx: transaction.asV2Read),
                changeActionsProtoData: changeActionsProtoData,
                additionalRecipients: Self.invitedMembers(in: thread),
                transaction: transaction
            )

            SSKEnvironment.shared.messageSenderJobQueueRef.add(message: message.asPreparer, transaction: transaction)
        }
    }

    private static func sendDurableNewGroupMessage(forThread thread: TSGroupThread) -> Promise<Void> {
        guard thread.isGroupV2Thread else {
            owsFail("[GV1] Should be impossible to send V1 group messages!")
        }

        return databaseStorage.write(.promise) { tx in
            let dmConfigurationStore = DependenciesBridge.shared.disappearingMessagesConfigurationStore
            let message = OutgoingGroupUpdateMessage(
                in: thread,
                groupMetaMessage: .new,
                expiresInSeconds: dmConfigurationStore.durationSeconds(for: thread, tx: tx.asV2Read),
                additionalRecipients: Self.invitedMembers(in: thread),
                transaction: tx
            )
            SSKEnvironment.shared.messageSenderJobQueueRef.add(message: message.asPreparer, transaction: tx)
        }
    }

    private static func invitedMembers(in thread: TSGroupThread) -> Set<SignalServiceAddress> {
        thread.groupModel.groupMembership.invitedMembers.filter { doesUserSupportGroupsV2(address: $0) }
    }

    private static func invitedOrRequestedMembers(in thread: TSGroupThread) -> Set<SignalServiceAddress> {
        thread.groupModel.groupMembership.invitedOrRequestMembers.filter { doesUserSupportGroupsV2(address: $0) }
    }

    @objc
    public static func shouldMessageHaveAdditionalRecipients(_ message: TSOutgoingMessage,
                                                             groupThread: TSGroupThread) -> Bool {
        guard groupThread.groupModel.groupsVersion == .V2 else {
            return false
        }
        switch message.groupMetaMessage {
        case .update, .new:
            return true
        default:
            return false
        }
    }

    // MARK: - Group Database

    @objc
    public enum InfoMessagePolicy: UInt {
        case always
        case insertsOnly
        case updatesOnly
        case never
    }

    // If disappearingMessageToken is nil, don't update the disappearing messages configuration.
    public static func insertGroupThreadInDatabaseAndCreateInfoMessage(
        groupModel: TSGroupModel,
        disappearingMessageToken: DisappearingMessageToken?,
        groupUpdateSource: GroupUpdateSource,
        infoMessagePolicy: InfoMessagePolicy = .always,
        localIdentifiers: LocalIdentifiers,
        spamReportingMetadata: GroupUpdateSpamReportingMetadata,
        transaction: SDSAnyWriteTransaction
    ) -> TSGroupThread {

        if let groupThread = TSGroupThread.fetch(groupId: groupModel.groupId, transaction: transaction) {
            owsFail("Inserting existing group thread: \(groupThread.uniqueId).")
        }

        let groupThread = TSGroupThread(groupModelPrivate: groupModel,
                                        transaction: transaction)
        groupThread.anyInsert(transaction: transaction)

        TSGroupThread.setGroupIdMapping(groupThread.uniqueId,
                                        forGroupId: groupModel.groupId,
                                        transaction: transaction)

        let newDisappearingMessageToken = disappearingMessageToken ?? DisappearingMessageToken.disabledToken
        _ = updateDisappearingMessagesInDatabaseAndCreateMessages(
            token: newDisappearingMessageToken,
            thread: groupThread,
            shouldInsertInfoMessage: false,
            changeAuthor: groupUpdateSource,
            transaction: transaction
        )

        autoWhitelistGroupIfNecessary(
            oldGroupModel: nil,
            newGroupModel: groupModel,
            groupUpdateSource: groupUpdateSource,
            localIdentifiers: localIdentifiers,
            tx: transaction
        )

        switch infoMessagePolicy {
        case .always, .insertsOnly:
            insertGroupUpdateInfoMessageForNewGroup(
                localIdentifiers: localIdentifiers,
                spamReportingMetadata: spamReportingMetadata,
                groupThread: groupThread,
                groupModel: groupModel,
                disappearingMessageToken: newDisappearingMessageToken,
                groupUpdateSource: groupUpdateSource,
                transaction: transaction
            )
        default:
            break
        }

        notifyStorageServiceOfInsertedGroup(groupModel: groupModel,
                                            transaction: transaction)

        return groupThread
    }

    /// Update persisted group-related state for the provided models, or insert
    /// it if this group does not already exist. If appropriate, inserts an info
    /// message into the group thread describing what has changed about the
    /// group.
    ///
    /// - Parameter newlyLearnedPniToAciAssociations
    /// Associations between PNIs and ACIs that were learned as a result of this
    /// group update.
    public static func tryToUpsertExistingGroupThreadInDatabaseAndCreateInfoMessage(
        newGroupModel: TSGroupModel,
        newDisappearingMessageToken: DisappearingMessageToken?,
        newlyLearnedPniToAciAssociations: [Pni: Aci],
        groupUpdateSource: GroupUpdateSource,
        didAddLocalUserToV2Group: Bool,
        infoMessagePolicy: InfoMessagePolicy = .always,
        localIdentifiers: LocalIdentifiers,
        spamReportingMetadata: GroupUpdateSpamReportingMetadata,
        transaction: SDSAnyWriteTransaction
    ) throws -> TSGroupThread {

        TSGroupThread.ensureGroupIdMapping(forGroupId: newGroupModel.groupId, transaction: transaction)
        let threadId = TSGroupThread.threadId(forGroupId: newGroupModel.groupId, transaction: transaction)

        if TSGroupThread.anyExists(uniqueId: threadId, transaction: transaction) {
            return try updateExistingGroupThreadInDatabaseAndCreateInfoMessage(
                newGroupModel: newGroupModel,
                newDisappearingMessageToken: newDisappearingMessageToken,
                newlyLearnedPniToAciAssociations: newlyLearnedPniToAciAssociations,
                groupUpdateSource: groupUpdateSource,
                infoMessagePolicy: infoMessagePolicy,
                localIdentifiers: localIdentifiers,
                spamReportingMetadata: spamReportingMetadata,
                transaction: transaction
            )
        } else {
            // When inserting a v2 group into the database for the
            // first time, we don't want to attribute all of the group
            // state to the author of the most recent revision.
            //
            // We only want to attribute the changes if we've just been
            // added, so that we can say "Alice added you to the group,"
            // etc.
            var shouldAttributeAuthor = true
            if newGroupModel.groupsVersion == .V2 {
                if didAddLocalUserToV2Group, newGroupModel.groupMembers.contains(localIdentifiers.aciAddress) {
                    // Do attribute.
                } else {
                    // Don't attribute.
                    shouldAttributeAuthor = false
                }
            }

            return insertGroupThreadInDatabaseAndCreateInfoMessage(
                groupModel: newGroupModel,
                disappearingMessageToken: newDisappearingMessageToken,
                groupUpdateSource: shouldAttributeAuthor ? groupUpdateSource : .unknown,
                infoMessagePolicy: infoMessagePolicy,
                localIdentifiers: localIdentifiers,
                spamReportingMetadata: spamReportingMetadata,
                transaction: transaction
            )
        }
    }

    /// Update persisted group-related state for the provided models. If
    /// appropriate, inserts an info message into the group thread describing
    /// what has changed about the group.
    ///
    /// - Parameter newlyLearnedPniToAciAssociations
    /// Associations between PNIs and ACIs that were learned as a result of this
    /// group update.
    public static func updateExistingGroupThreadInDatabaseAndCreateInfoMessage(
        newGroupModel: TSGroupModel,
        newDisappearingMessageToken: DisappearingMessageToken?,
        newlyLearnedPniToAciAssociations: [Pni: Aci],
        groupUpdateSource: GroupUpdateSource,
        infoMessagePolicy: InfoMessagePolicy = .always,
        localIdentifiers: LocalIdentifiers,
        spamReportingMetadata: GroupUpdateSpamReportingMetadata,
        transaction: SDSAnyWriteTransaction
    ) throws -> TSGroupThread {
        // Step 1: First reload latest thread state. This ensures:
        //
        // * The thread (still) exists in the database.
        // * The update is working off latest database state.
        //
        // We always have the groupThread at the call sites of this method, but this
        // future-proofs us against bugs.
        guard let groupThread = TSGroupThread.fetch(groupId: newGroupModel.groupId, transaction: transaction) else {
            throw OWSAssertionError("Missing groupThread.")
        }

        guard
            let newGroupModel = newGroupModel as? TSGroupModelV2,
            let oldGroupModel = groupThread.groupModel as? TSGroupModelV2
        else {
            owsFail("[GV1] Should be impossible to update a V1 group!")
        }

        // Step 2: Update DM configuration in database, if necessary.
        let updateDMResult: UpdateDMConfigurationResult
        if let newDisappearingMessageToken = newDisappearingMessageToken {
            // shouldInsertInfoMessage is false because we only want to insert a
            // single info message if we update both DM config and thread model.
            updateDMResult = updateDisappearingMessagesInDatabaseAndCreateMessages(
                token: newDisappearingMessageToken,
                thread: groupThread,
                shouldInsertInfoMessage: false,
                changeAuthor: groupUpdateSource,
                transaction: transaction
            )
        } else {
            let dmConfigurationStore = DependenciesBridge.shared.disappearingMessagesConfigurationStore
            let dmConfiguration = dmConfigurationStore.fetchOrBuildDefault(for: .thread(groupThread), tx: transaction.asV2Read)
            updateDMResult = UpdateDMConfigurationResult(oldConfiguration: dmConfiguration, newConfiguration: dmConfiguration)
        }

        // Step 3: If any member was removed, make sure we rotate our sender key
        // session.
        //
        // If *we* were removed, check if the group contained any blocked
        // members and make a best-effort attempt to rotate our profile key if
        // this was our only mutual group with them.
        do {
            let oldMembers = oldGroupModel.membership.allMembersOfAnyKindServiceIds
            let newMembers = newGroupModel.membership.allMembersOfAnyKindServiceIds

            if oldMembers.subtracting(newMembers).isEmpty == false {
                senderKeyStore.resetSenderKeySession(for: groupThread, transaction: transaction)
            }

            if
                DependenciesBridge.shared.tsAccountManager.registrationState(tx: transaction.asV2Read).isPrimaryDevice ?? true,
                let localAci = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: transaction.asV2Read)?.aci,
                oldGroupModel.membership.hasProfileKeyInGroup(serviceId: localAci),
                !newGroupModel.membership.hasProfileKeyInGroup(serviceId: localAci)
            {
                // If our profile key is no longer exposed to the group - for
                // example, we've left the group - check if the group had any
                // blocked users to whom our profile key was exposed.
                var shouldRotateProfileKey = false
                for member in oldMembers {
                    let memberAddress = SignalServiceAddress(member)

                    if
                        (
                            blockingManager.isAddressBlocked(memberAddress, transaction: transaction)
                            || DependenciesBridge.shared.recipientHidingManager.isHiddenAddress(memberAddress, tx: transaction.asV2Read)
                        ),
                        newGroupModel.membership.canViewProfileKeys(serviceId: member)
                    {
                        // Make a best-effort attempt to find other groups with
                        // this blocked user in which our profile key is
                        // exposed.
                        //
                        // We can only efficiently query for groups in which
                        // they are a full member, although that may not be all
                        // the groups in which they can see your profile key.
                        // Best effort.
                        let mutualGroupThreads = Self.mutualGroupThreads(
                            with: member,
                            localAci: localAci,
                            tx: transaction
                        )

                        // If there is exactly one group, it's the one we are leaving!
                        // We should rotate, as it's the last group we have in common.
                        if mutualGroupThreads.count == 1 {
                            shouldRotateProfileKey = true
                            break
                        }
                    }
                }

                if shouldRotateProfileKey {
                    profileManager.forceRotateLocalProfileKeyForGroupDeparture(with: transaction)
                }
            }
        }

        // Step 4: Update group in database, if necessary.
        let hasUserFacingUpdate: Bool = {
            guard newGroupModel.revision > oldGroupModel.revision else {
                /// Local group state must never revert to an earlier revision.
                ///
                /// Races exist in the GV2 code, so if we find ourselves with a
                /// redundant update we'll simply drop it.
                ///
                /// Note that (excepting bugs elsewhere in the GV2 code) no
                /// matter which codepath learned about a particular revision,
                /// the group models each codepath constructs for that revision
                /// should be equivalent.
                Logger.warn("Skipping redundant update for V2 group.")
                return false
            }

            autoWhitelistGroupIfNecessary(
                oldGroupModel: oldGroupModel,
                newGroupModel: newGroupModel,
                groupUpdateSource: groupUpdateSource,
                localIdentifiers: localIdentifiers,
                tx: transaction
            )

            TSGroupThread.ensureGroupIdMapping(
                forGroupId: newGroupModel.groupId,
                transaction: transaction
            )

            let hasUserFacingGroupModelChange = newGroupModel.hasUserFacingChangeCompared(
                to: oldGroupModel
            )

            let hasDMUpdate = updateDMResult.newConfiguration != updateDMResult.oldConfiguration

            let hasUserFacingUpdate = hasUserFacingGroupModelChange || hasDMUpdate

            groupThread.update(
                with: newGroupModel,
                shouldUpdateChatListUi: hasUserFacingUpdate,
                transaction: transaction
            )

            return hasUserFacingUpdate
        }()

        guard hasUserFacingUpdate else {
            return groupThread
        }

        switch infoMessagePolicy {
        case .always, .updatesOnly:
            insertGroupUpdateInfoMessage(
                groupThread: groupThread,
                oldGroupModel: oldGroupModel,
                newGroupModel: newGroupModel,
                oldDisappearingMessageToken: updateDMResult.oldConfiguration.asToken,
                newDisappearingMessageToken: updateDMResult.newConfiguration.asToken,
                newlyLearnedPniToAciAssociations: newlyLearnedPniToAciAssociations,
                groupUpdateSource: groupUpdateSource,
                localIdentifiers: localIdentifiers,
                spamReportingMetadata: spamReportingMetadata,
                transaction: transaction
            )
        default:
            break
        }

        return groupThread
    }

    private static func mutualGroupThreads(
        with member: ServiceId,
        localAci: Aci,
        tx: SDSAnyReadTransaction
    ) -> [TSGroupThread] {
        return DependenciesBridge.shared.groupMemberStore
            .groupThreadIds(
                withFullMember: member,
                tx: tx.asV2Read
            )
            .lazy
            .compactMap { groupThreadId in
                return TSGroupThread.anyFetchGroupThread(uniqueId: groupThreadId, transaction: tx)
            }
            .filter { groupThread in
                return groupThread.groupMembership.hasProfileKeyInGroup(serviceId: localAci)
            }
    }

    public static func hasMutualGroupThread(
        with member: ServiceId,
        localAci: Aci,
        tx: SDSAnyReadTransaction
    ) -> Bool {
        let mutualGroupThreads = Self.mutualGroupThreads(
            with: member,
            localAci: localAci,
            tx: tx
        )
        return !mutualGroupThreads.isEmpty
    }

    // MARK: - Storage Service

    private static func notifyStorageServiceOfInsertedGroup(groupModel: TSGroupModel,
                                                            transaction: SDSAnyReadTransaction) {
        guard let groupModel = groupModel as? TSGroupModelV2 else {
            // We only need to notify the storage service about v2 groups.
            return
        }
        guard !groupsV2.isGroupKnownToStorageService(groupModel: groupModel,
                                                          transaction: transaction) else {
            // To avoid redundant storage service writes,
            // don't bother notifying the storage service
            // about v2 groups it already knows about.
            return
        }

        storageServiceManager.recordPendingUpdates(groupModel: groupModel)
    }

    // MARK: - Profiles

    private static func autoWhitelistGroupIfNecessary(
        oldGroupModel: TSGroupModel?,
        newGroupModel: TSGroupModel,
        groupUpdateSource: GroupUpdateSource,
        localIdentifiers: LocalIdentifiers,
        tx: SDSAnyWriteTransaction
    ) {
        let justAdded = wasLocalUserJustAddedToTheGroup(
            oldGroupModel: oldGroupModel,
            newGroupModel: newGroupModel,
            localIdentifiers: localIdentifiers
        )
        guard justAdded else {
            return
        }

        let shouldAddToWhitelist: Bool
        switch groupUpdateSource {
        case .unknown, .legacyE164, .rejectedInviteToPni:
            // Invalid updaters, shouldn't add.
            shouldAddToWhitelist = false
        case .aci(let aci):
            shouldAddToWhitelist = profileManager.isUser(inProfileWhitelist: SignalServiceAddress(aci), transaction: tx)
        case .localUser:
            // Always whitelist if its the local user updating.
            shouldAddToWhitelist = true
        }

        guard shouldAddToWhitelist else {
            return
        }

        // Ensure the thread is in our profile whitelist if we're a member of the group.
        // We don't want to do this if we're just a pending member or are leaving/have
        // already left the group.
        self.profileManager.addGroupId(
            toProfileWhitelist: newGroupModel.groupId, userProfileWriter: .localUser, transaction: tx
        )
    }

    private static func wasLocalUserJustAddedToTheGroup(
        oldGroupModel: TSGroupModel?,
        newGroupModel: TSGroupModel,
        localIdentifiers: LocalIdentifiers
    ) -> Bool {
        if let oldGroupModel, oldGroupModel.groupMembership.isFullMember(localIdentifiers.aci) {
            // Local user already was a member.
            return false
        }
        if !newGroupModel.groupMembership.isFullMember(localIdentifiers.aci) {
            // Local user is not a member.
            return false
        }
        return true
    }

    // MARK: -

    /// A profile key is considered "authoritative" when it comes in on a group
    /// change action and the owner of the profile key matches the group change
    /// action author. We consider an "authoritative" profile key the source of
    /// truth. Even if we have a different profile key for this user already,
    /// we consider this authoritative profile key the correct, most up-to-date
    /// one. A "non-authoritative" profile key, on the other hand, may or may
    /// not be the most up to date profile key for a user (such as if one user
    /// adds another to a group without having their latest profile key), and we
    /// only use it if we have no other profile key for the user already.
    ///
    /// - Parameter allProfileKeysByAci: contains both authoritative and
    ///   non-authoritative profile keys.
    ///
    /// - Parameter authoritativeProfileKeysByAci: contains just authoritative
    ///   profile keys. If authoritative profile keys cannot be determined, pass
    ///   nil.
    public static func storeProfileKeysFromGroupProtos(
        allProfileKeysByAci: [Aci: Data],
        authoritativeProfileKeysByAci: [Aci: Data]?
    ) {
        var allProfileKeysByAddress = [SignalServiceAddress: Data]()
        for (aci, profileKeyData) in allProfileKeysByAci {
            allProfileKeysByAddress[SignalServiceAddress(aci)] = profileKeyData
        }
        var authoritativeProfileKeysByAddress = [SignalServiceAddress: Data]()
        if let authoritativeProfileKeysByAci {
            for (aci, profileKeyData) in authoritativeProfileKeysByAci {
                let address = SignalServiceAddress(aci)
                if !address.isLocalAddress {
                    // We trust what is locally-stored as the local user's profile
                    // key to be more authoritative than what is stored in the group
                    // state on the server.
                    authoritativeProfileKeysByAddress[address] = profileKeyData
                }
            }
        }
        profileManager.fillInProfileKeys(
            allProfileKeys: allProfileKeysByAddress,
            authoritativeProfileKeys: authoritativeProfileKeysByAddress,
            userProfileWriter: .groupState,
            authedAccount: .implicit()
        )
    }

    /// Ensure that we have a profile key commitment for our local profile
    /// available on the service.
    ///
    /// We (and other clients) need profile key credentials for group members in
    /// order to perform GV2 operations. However, other clients can't request
    /// our profile key credential from the service until we've uploaded a profile
    /// key commitment to the service.
    public static func ensureLocalProfileHasCommitmentIfNecessary() async throws {
        let accountManager = DependenciesBridge.shared.tsAccountManager

        func hasProfileKeyCredential() throws -> Bool {
            return try NSObject.databaseStorage.read { tx in
                guard accountManager.registrationState(tx: tx.asV2Read).isRegistered else {
                    return false
                }
                guard let localAddress = accountManager.localIdentifiers(tx: tx.asV2Read)?.aciAddress else {
                    throw OWSAssertionError("Missing localAddress.")
                }
                return NSObject.groupsV2.hasProfileKeyCredential(for: localAddress, transaction: tx)
            }
        }

        guard try !hasProfileKeyCredential() else {
            return
        }

        // If we don't have a local profile key credential we should first
        // check if it is simply expired, by asking for a new one (which we
        // would get as part of fetching our local profile).
        _ = try await NSObject.profileManager.fetchLocalUsersProfile(mainAppOnly: false, authedAccount: .implicit()).awaitable()

        guard try !hasProfileKeyCredential() else {
            return
        }

        guard
            CurrentAppContext().isMainApp,
            NSObject.databaseStorage.read(block: { tx in
                accountManager.registrationState(tx: tx.asV2Read).isRegisteredPrimaryDevice
            })
        else {
            Logger.warn("Skipping upload of local profile key commitment, not in main app!")
            return
        }

        // We've never uploaded a profile key commitment - do so now.
        Logger.info("No profile key credential available for local account - uploading local profile!")
        _ = await databaseStorage.awaitableWrite { tx in
            NSObject.profileManager.reuploadLocalProfile(unsavedRotatedProfileKey: nil, authedAccount: .implicit(), tx: tx.asV2Write)
        }
    }
}

// MARK: -

public extension GroupManager {
    class func messageProcessingPromise(for thread: TSThread,
                                        description: String) -> Promise<Void> {
        guard thread.isGroupV2Thread else {
            return Promise.value(())
        }

        return messageProcessingPromise(description: description)
    }

    class func messageProcessingPromise(for groupModel: TSGroupModel,
                                        description: String) -> Promise<Void> {
        guard groupModel.groupsVersion == .V2 else {
            return Promise.value(())
        }

        return messageProcessingPromise(description: description)
    }

    private class func messageProcessingPromise(description: String) -> Promise<Void> {
        return firstly {
            self.messageProcessor.waitForFetchingAndProcessing()
        }.timeout(seconds: GroupManager.groupUpdateTimeoutDuration,
                  description: description) {
            GroupsV2Error.timeout
        }
    }
}

// MARK: - Add/Invite to group

extension GroupManager {
    public static func addOrInvite(
        serviceIds: [ServiceId],
        toExistingGroup existingGroupModel: TSGroupModel
    ) -> Promise<TSGroupThread> {
        guard let existingGroupModel = existingGroupModel as? TSGroupModelV2 else {
            owsFail("[GV1] Mutations on V1 groups should be impossible!")
        }

        return firstly { () -> Promise<Void> in
            // Ensure we have fetched profile key credentials before performing
            // the add below, since we depend on credential state to decide
            // whether to add or invite a user.

            Promise.wrapAsync {
                try await self.groupsV2.tryToFetchProfileKeyCredentials(
                    for: serviceIds.compactMap { $0 as? Aci },
                    ignoreMissingProfiles: false,
                    forceRefresh: false
                )
            }
        }.then(on: DispatchQueue.global()) { () -> Promise<TSGroupThread> in
            updateGroupV2(
                groupModel: existingGroupModel,
                description: "Add/Invite new non-admin members"
            ) { groupChangeSet in
                self.databaseStorage.read { transaction in
                    for serviceId in serviceIds {
                        owsAssertDebug(!existingGroupModel.groupMembership.isMemberOfAnyKind(serviceId))

                        // Important that at this point we already have the
                        // profile keys for these users
                        let hasCredential = self.groupsV2.hasProfileKeyCredential(
                            for: SignalServiceAddress(serviceId),
                            transaction: transaction
                        )

                        if let aci = serviceId as? Aci, hasCredential {
                            groupChangeSet.addMember(aci, role: .normal)
                        } else {
                            groupChangeSet.addInvitedMember(serviceId, role: .normal)
                        }

                        if let aci = serviceId as? Aci, existingGroupModel.groupMembership.isBannedMember(aci) {
                            groupChangeSet.removeBannedMember(aci)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Update attributes

extension GroupManager {
    public static func updateGroupAttributes(
        title: String?,
        description: String?,
        avatarData: Data?,
        inExistingGroup existingGroupModel: TSGroupModel
    ) -> Promise<TSGroupThread> {
        guard let existingGroupModel = existingGroupModel as? TSGroupModelV2 else {
            owsFail("[GV1] Mutations on V1 groups should be impossible!")
        }

        return firstly(on: DispatchQueue.global()) { () -> Promise<String?> in
            guard let avatarData = avatarData else {
                return .value(nil)
            }

            // Skip upload if the new avatar data is the same as the existing
            if
                let existingAvatarHash = existingGroupModel.avatarHash,
                try existingAvatarHash == TSGroupModel.hash(forAvatarData: avatarData)
            {
                return .value(nil)
            }

            return Promise.wrapAsync {
                try await self.groupsV2.uploadGroupAvatar(
                    avatarData: avatarData,
                    groupSecretParamsData: existingGroupModel.secretParamsData
                )
            }.map { Optional.some($0) }
        }.then(on: DispatchQueue.global()) { (avatarUrlPath: String?) -> Promise<TSGroupThread> in
            var message = "Update attributes:"
            message += title != nil ? " title" : ""
            message += description != nil ? " description" : ""
            message += avatarData != nil ? " settingAvatarData" : " clearingAvatarData"

            return self.updateGroupV2(
                groupModel: existingGroupModel,
                description: message
            ) { groupChangeSet in
                if
                    let title = title?.ows_stripped(),
                    title != existingGroupModel.groupName
                {
                    groupChangeSet.setTitle(title)
                }

                if
                    let description = description?.ows_stripped(),
                    description != existingGroupModel.descriptionText
                {
                    groupChangeSet.setDescriptionText(description)
                } else if
                    description == nil,
                    existingGroupModel.descriptionText != nil
                {
                    groupChangeSet.setDescriptionText(nil)
                }

                // Having a URL from the previous step means this data
                // represents a new avatar, which we have already uploaded.
                if
                    let avatarData = avatarData,
                    let avatarUrlPath = avatarUrlPath
                {
                    groupChangeSet.setAvatar((data: avatarData, urlPath: avatarUrlPath))
                } else if
                    avatarData == nil,
                    existingGroupModel.avatarData != nil
                {
                    groupChangeSet.setAvatar(nil)
                }
            }
        }
    }
}
