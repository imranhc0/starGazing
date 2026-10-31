import Foundation

/// How many of the photos the user chose could actually be opened. With limited Photos access
/// the picker can hand over photos the app is not allowed to read, so the two numbers can differ.
nonisolated struct PickReport: Equatable {
    let picked: Int
    let readable: Int

    var skipped: Int { max(0, picked - readable) }
    var isComplete: Bool { skipped == 0 }
    var canStack: Bool { readable >= StackRequest.frameRange.lowerBound }

    /// What to tell the user, or nil when every chosen photo could be opened.
    var message: String? {
        guard !isComplete else { return nil }
        return "StarGazing could open \(readable) of the \(picked) photos you chose. "
            + "With limited access to Photos, the app can only read photos you have shared with it. "
            + "Add the missing photos to what StarGazing can see, or allow full access in Settings."
    }
}
