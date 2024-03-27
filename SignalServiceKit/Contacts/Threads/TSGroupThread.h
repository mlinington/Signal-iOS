//
// Copyright 2017 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

#import <SignalServiceKit/TSGroupModel.h>
#import <SignalServiceKit/TSThread.h>

NS_ASSUME_NONNULL_BEGIN

@class MessageBodyRanges;
@class SDSAnyReadTransaction;
@class SDSAnyWriteTransaction;
@class TSAttachmentStream;
@class TSGroupModelV2;

extern NSString *const TSGroupThreadAvatarChangedNotification;
extern NSString *const TSGroupThread_NotificationKey_UniqueId;

@interface TSGroupThread : TSThread

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithUniqueId:(NSString *)uniqueId NS_UNAVAILABLE;

- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_DESIGNATED_INITIALIZER;

// This method should only be called by GroupManager.
- (instancetype)initWithGroupModelPrivate:(TSGroupModel *)groupModel
                              transaction:(SDSAnyReadTransaction *)transaction NS_DESIGNATED_INITIALIZER;

#ifdef TESTABLE_BUILD

- (instancetype)initWithGroupModelForTests:(TSGroupModel *)groupModel NS_DESIGNATED_INITIALIZER;

#endif

- (instancetype)initWithGrdbId:(int64_t)grdbId
                                       uniqueId:(NSString *)uniqueId
                  conversationColorNameObsolete:(NSString *)conversationColorNameObsolete
                                   creationDate:(nullable NSDate *)creationDate
                            editTargetTimestamp:(nullable NSNumber *)editTargetTimestamp
                             isArchivedObsolete:(BOOL)isArchivedObsolete
                         isMarkedUnreadObsolete:(BOOL)isMarkedUnreadObsolete
                           lastInteractionRowId:(uint64_t)lastInteractionRowId
                         lastSentStoryTimestamp:(nullable NSNumber *)lastSentStoryTimestamp
                      lastVisibleSortIdObsolete:(uint64_t)lastVisibleSortIdObsolete
    lastVisibleSortIdOnScreenPercentageObsolete:(double)lastVisibleSortIdOnScreenPercentageObsolete
                        mentionNotificationMode:(TSThreadMentionNotificationMode)mentionNotificationMode
                                   messageDraft:(nullable NSString *)messageDraft
                         messageDraftBodyRanges:(nullable MessageBodyRanges *)messageDraftBodyRanges
                         mutedUntilDateObsolete:(nullable NSDate *)mutedUntilDateObsolete
                    mutedUntilTimestampObsolete:(uint64_t)mutedUntilTimestampObsolete
                          shouldThreadBeVisible:(BOOL)shouldThreadBeVisible
                                  storyViewMode:(TSThreadStoryViewMode)storyViewMode NS_UNAVAILABLE;

// --- CODE GENERATION MARKER

// This snippet is generated by /Scripts/sds_codegen/sds_generate.py. Do not manually edit it, instead run
// `sds_codegen.sh`.

// clang-format off

- (instancetype)initWithGrdbId:(int64_t)grdbId
                      uniqueId:(NSString *)uniqueId
   conversationColorNameObsolete:(NSString *)conversationColorNameObsolete
                    creationDate:(nullable NSDate *)creationDate
             editTargetTimestamp:(nullable NSNumber *)editTargetTimestamp
              isArchivedObsolete:(BOOL)isArchivedObsolete
          isMarkedUnreadObsolete:(BOOL)isMarkedUnreadObsolete
            lastInteractionRowId:(uint64_t)lastInteractionRowId
          lastSentStoryTimestamp:(nullable NSNumber *)lastSentStoryTimestamp
       lastVisibleSortIdObsolete:(uint64_t)lastVisibleSortIdObsolete
lastVisibleSortIdOnScreenPercentageObsolete:(double)lastVisibleSortIdOnScreenPercentageObsolete
         mentionNotificationMode:(TSThreadMentionNotificationMode)mentionNotificationMode
                    messageDraft:(nullable NSString *)messageDraft
          messageDraftBodyRanges:(nullable MessageBodyRanges *)messageDraftBodyRanges
          mutedUntilDateObsolete:(nullable NSDate *)mutedUntilDateObsolete
     mutedUntilTimestampObsolete:(uint64_t)mutedUntilTimestampObsolete
           shouldThreadBeVisible:(BOOL)shouldThreadBeVisible
                   storyViewMode:(TSThreadStoryViewMode)storyViewMode
                      groupModel:(TSGroupModel *)groupModel
NS_DESIGNATED_INITIALIZER NS_SWIFT_NAME(init(grdbId:uniqueId:conversationColorNameObsolete:creationDate:editTargetTimestamp:isArchivedObsolete:isMarkedUnreadObsolete:lastInteractionRowId:lastSentStoryTimestamp:lastVisibleSortIdObsolete:lastVisibleSortIdOnScreenPercentageObsolete:mentionNotificationMode:messageDraft:messageDraftBodyRanges:mutedUntilDateObsolete:mutedUntilTimestampObsolete:shouldThreadBeVisible:storyViewMode:groupModel:));

// clang-format on

// --- CODE GENERATION MARKER

@property (nonatomic, readonly) TSGroupModel *groupModel;

+ (nullable instancetype)fetchWithGroupId:(NSData *)groupId
                              transaction:(SDSAnyReadTransaction *)transaction
    NS_SWIFT_NAME(fetch(groupId:transaction:));

@property (nonatomic, readonly) NSString *groupNameOrDefault;
@property (nonatomic, readonly, class) NSString *defaultGroupName;

#pragma mark - Update With...

// This method should only be called by GroupManager.
- (void)updateWithGroupModel:(TSGroupModel *)groupModel transaction:(SDSAnyWriteTransaction *)transaction;

/// The `shouldUpdateChatListUi` parameter denotes whether the update of
/// this group thread should trigger an update of the chat list UI (which
/// is expensive; we don't want to do it unless we have to). In practice,
/// `shouldUpdateChatListUi` should be true when the changes are user-facing.
/// Multiple collapsed updates have `shouldUpdateChatListUi` if it is true
/// for any of them.
- (void)updateWithGroupModel:(TSGroupModel *)groupModel
      shouldUpdateChatListUi:(BOOL)shouldUpdateChatListUi
                 transaction:(SDSAnyWriteTransaction *)transaction;

@end

NS_ASSUME_NONNULL_END