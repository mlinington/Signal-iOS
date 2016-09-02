//  Copyright © 2016 Open Whisper Systems. All rights reserved.

#import "OWSSyncContactsMessage.h"
#import "Contact.h"
#import "ContactsManagerProtocol.h"
#import "NSDate+millisecondTimeStamp.h"
#import "OWSSignalServiceProtos.pb.h"
#import "TSAttachment.h"
#import "TSAttachmentStream.h"
#import <ProtocolBuffers/CodedOutputStream.h>

NS_ASSUME_NONNULL_BEGIN

@interface OWSSyncContactsMessage ()

@property (nonatomic, readonly) id<ContactsManagerProtocol> contactsManager;

@end

@implementation OWSSyncContactsMessage

- (instancetype)initWithContactsManager:(id<ContactsManagerProtocol>)contactsManager
{
    self = [super initWithTimestamp:[NSDate ows_millisecondTimeStamp] inThread:nil messageBody:nil attachmentIds:@[]];
    if (!self) {
        return self;
    }

    _contactsManager = contactsManager;

    return self;
}

- (OWSSignalServiceProtosSyncMessage *)buildSyncMessage
{
    if (self.attachmentIds.count != 1) {
        DDLogError(@"expected sync contact message to have exactly one attachment, but found %lu",
            (unsigned long)self.attachmentIds.count);
    }

    OWSSignalServiceProtosAttachmentPointer *attachmentProto =
        [self buildAttachmentProtoForAttachmentId:self.attachmentIds[0]];

    OWSSignalServiceProtosSyncMessageContactsBuilder *contactsBuilder =
        [OWSSignalServiceProtosSyncMessageContactsBuilder new];

    [contactsBuilder setBlob:attachmentProto];

    OWSSignalServiceProtosSyncMessageBuilder *syncMessageBuilder = [OWSSignalServiceProtosSyncMessageBuilder new];
    [syncMessageBuilder setContactsBuilder:contactsBuilder];

    return [syncMessageBuilder build];
}

- (NSData *)buildPlainTextAttachmentData
{
    NSString *fileName =
        [NSString stringWithFormat:@"%@_%@", [[NSProcessInfo processInfo] globallyUniqueString], @"contacts.dat"];
    NSURL *fileURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:fileName]];
    NSOutputStream *fileOutputStream = [NSOutputStream outputStreamWithURL:fileURL append:NO];
    [fileOutputStream open];

    PBCodedOutputStream *outputStream = [PBCodedOutputStream streamWithOutputStream:fileOutputStream];
    DDLogInfo(@"Writing contacts data to %@", fileURL);
    for (Contact *contact in self.contactsManager.signalContacts) {
        OWSSignalServiceProtosContactDetailsBuilder *contactBuilder = [OWSSignalServiceProtosContactDetailsBuilder new];

        [contactBuilder setName:contact.fullName];
        [contactBuilder setNumber:contact.textSecureIdentifiers.firstObject];

        NSData *avatarPng;
        if (contact.image) {
            OWSSignalServiceProtosContactDetailsAvatarBuilder *avatarBuilder =
                [OWSSignalServiceProtosContactDetailsAvatarBuilder new];

            [avatarBuilder setContentType:@"image/png"];
            avatarPng = UIImagePNGRepresentation(contact.image);
            [avatarBuilder setLength:(uint32_t)avatarPng.length];
            [contactBuilder setAvatarBuilder:avatarBuilder];
        }

        NSData *contactData = [[contactBuilder build] data];

        uint32_t contactDataLength = (uint32_t)contactData.length;
        [outputStream writeRawVarint32:contactDataLength];
        [outputStream writeRawData:contactData];

        if (contact.image) {
            [outputStream writeRawData:avatarPng];
        }
    }
    [outputStream flush];
    [fileOutputStream close];

    // TODO pass stream to builder rather than data as a singular hulk.
    [NSInputStream inputStreamWithURL:fileURL];
    NSError *error;
    NSData *data = [NSData dataWithContentsOfURL:fileURL options:NSDataReadingMappedIfSafe error:&error];
    if (error) {
        DDLogError(@"Failed to read back contact data after writing it to %@ with error:%@", fileURL, error);
    }
    return data;

    //    TODO delete contacts file.
    //    NSError *error;
    //    NSFileManager *manager = [NSFileManager defaultManager];
    //    [manager removeItemAtURL:fileURL error:&error];
    //    if (error) {
    //        DDLogError(@"Failed removing temp file at url:%@ with error:%@", fileURL, error);
    //    }
}

@end

NS_ASSUME_NONNULL_END
