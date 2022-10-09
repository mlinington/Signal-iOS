//
//  Copyright (c) 2022 Open Whisper Systems. All rights reserved.
//

import Foundation
import AVFoundation

public extension Progress {
    /// Creates a discrete Progress object with its completedCount set to its totalCount
    static func createCompletedChild(unitCount: Int64 = 10) -> Progress {
        let progress = Progress.discreteProgress(totalUnitCount: unitCount)
        progress.completedUnitCount = progress.totalUnitCount
        return progress
    }
}

extension AVAssetExportSession {

    /// Constructs and returns an NSProgress subclass that's capable of monitoring
    /// the progress of an export session.
    ///
    /// AVAssetExportSession has a -progress property that's not KVO-compliant and
    /// ineligible for NSProgrss chaining. To work around this, a ProgressPoller will
    /// register a timer to poll the progress at a 0.25s cadence. This timer only runs
    /// while the session status is "exporting". Otherwise, progress is only updated
    /// on a status change.
    ///
    /// Note: This means that each time this function is invoked, a new timer may be
    /// registered on the runloop. Try to avoid keeping unnecessary instances of these
    /// objects around.
    func createProgressPoller() -> ProgressPoller {
        ProgressPoller(session: self)
    }

    public class ProgressPoller: Foundation.Progress {
        private static let kPollInterval = 0.25

        private weak var session: AVAssetExportSession?
        private var observation: NSKeyValueObservation?
        private var timer: Timer?

        fileprivate init(session: AVAssetExportSession) {
            self.session = session
            super.init(parent: nil)
            self.completedUnitCount = 0
            self.totalUnitCount = 100

            observation = session.observe(\.status, options: [.initial]) { [weak self] object, change in
                self?.updateProgress()
            }
        }

        deinit {
            timer?.invalidate()
            timer = nil
        }

        private func updateProgress() {
            guard let session = session else {
                stopMonitoring()
                return
            }

            let isExporting = (session.status == .exporting)
            let currentProgress = session.progress
            completedUnitCount = Int64(Float(totalUnitCount) * currentProgress).clamp(0, totalUnitCount)
            shouldPoll(isExporting)
        }

        private func shouldPoll(_ shouldEnable: Bool) {
            if shouldEnable {
                timer = timer ?? Timer.scheduledTimer(withTimeInterval: Self.kPollInterval, repeats: true) { [weak self] timer in
                    self?.updateProgress()
                }
            } else {
                timer?.invalidate()
                timer = nil
            }
        }

        private func stopMonitoring() {
            // If we decide we want to stop monitoring for whatever reason, we immediately
            // jump to 100% and disregard the session and any progress updates.
            completedUnitCount = 100
            shouldPoll(false)
            observation?.invalidate()
            observation = nil
            session = nil
        }

        override public func cancel() {
            super.cancel()
            session?.cancelExport()
        }
    }
}
