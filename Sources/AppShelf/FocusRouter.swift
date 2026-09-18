import Combine
import Foundation

/// Lets menu commands drive state that lives inside the window's view tree.
///
/// `.commands` is declared on the `App`, which has no access to a window's `@FocusState`.
/// Bumping a token here is the smallest bridge that does not require a third-party
/// focus library, and it keeps ⌘F working whichever window is frontmost.
@MainActor
final class FocusRouter: ObservableObject {
    static let shared = FocusRouter()

    @Published private(set) var searchFocusToken = 0

    private init() {}

    func focusSearch() { searchFocusToken += 1 }
}
