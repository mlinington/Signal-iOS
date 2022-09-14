//
//  Copyright (c) 2022 Open Whisper Systems. All rights reserved.
//

import Foundation
import AVFoundation

// A dead simple variant of NSProgressReporting
// Created in order to support AVAssetExportSession
public protocol OWSProgressReporting {
    var progress: Float { get }
}

// A better version of this would probably just conform to ProgressReporting
// outright. I think the only way to do that is to register KVO on the
// progress property of AVAssetExportSession. That's overkill for now, but
// would probably be a great thing to add in the future!
extension AVAssetExportSession: OWSProgressReporting {}
