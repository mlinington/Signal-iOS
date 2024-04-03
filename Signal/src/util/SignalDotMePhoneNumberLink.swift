//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Namespace for logic around Signal Dot Me links pointing to a user's phone
/// number. These URLs look like `https://signal.me/#p/<e164>`.
class SignalDotMePhoneNumberLink: Dependencies {
    private static let pattern = try! NSRegularExpression(pattern: "^https://signal.me/#p/(\\+[0-9]+)$", options: [])

    static func isPossibleUrl(_ url: URL) -> Bool {
        pattern.hasMatch(input: url.absoluteString.lowercased())
    }

    static func openChat(url: URL, fromViewController: UIViewController) {
        open(url: url, fromViewController: fromViewController) { address in
            AssertIsOnMainThread()
            SignalApp.shared.presentConversationForAddress(address, action: .compose, animated: true)
        }
    }

    private static func open(url: URL, fromViewController: UIViewController, block: @escaping (SignalServiceAddress) -> Void) {
        guard let phoneNumber = pattern.parseFirstMatch(inText: url.absoluteString.lowercased()) else { return }

        ModalActivityIndicatorViewController.present(fromViewController: fromViewController, canCancel: true) { modal in
            firstly(on: DispatchQueue.sharedUserInitiated) { () -> Promise<Set<SignalRecipient>> in
                contactDiscoveryManager.lookUp(phoneNumbers: [phoneNumber], mode: .oneOffUserRequest)
            }.done(on: DispatchQueue.main) { signalRecipients in
                modal.dismissIfNotCanceled {
                    guard let recipient = signalRecipients.first else {
                        return OWSActionSheets.showErrorAlert(message: MessageSenderNoSuchSignalRecipientError().userErrorDescription)
                    }
                    block(recipient.address)
                }
            }.catch(on: DispatchQueue.main) { error in
                modal.dismissIfNotCanceled {
                    OWSActionSheets.showErrorAlert(message: error.userErrorDescription)
                }
            }
        }
    }
}
