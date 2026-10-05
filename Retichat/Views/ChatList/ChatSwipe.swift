//
//  ChatSwipe.swift
//  Retichat
//
//  What a chat row's trailing swipe offers in the chat list. Foundation
//  only, so tests/ChatSwipeTests.swift runs it for real.
//

import Foundation

nonisolated enum ChatSwipe: Equatable {
    /// A pending invite: Decline (asks first; the user's leave, final) and
    /// Accept.
    case invite
    /// A group the user holds: Delete asks first, then leaves and deletes
    /// the group (ChatRepository.deleteChat, which takes quitGroup), exactly
    /// as Delete in the chat info does (James, 2026-10-05). Until then the
    /// swipe only archived a group, so it carried on, its members still
    /// counting the user.
    case leaveGroup
    /// A direct chat: Delete archives it, as before.
    case archive

    static func of(isGroup: Bool, isPendingInvite: Bool) -> ChatSwipe {
        if isPendingInvite { return .invite }
        return isGroup ? .leaveGroup : .archive
    }
}
