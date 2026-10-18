import SwiftUI

/// How task lists attach the right-click menu and double-click (open in a new window). TEMPORARY
/// (rc1 QA F3 diagnosis, PR #20): the shipped `contextMenu(forSelectionType:primaryAction:)` logs
/// "SelectionManagerBox<String> tried to update multiple times per frame" on macOS 14, and per-row
/// `.contextMenu` + `simultaneousGesture` crashed (EXC_BAD_ACCESS in a cursorUpdate). Variants
/// can be switched without rebuilding:
///     defaults write com.mekari.project debug.taskListInteraction -int <n>   (then relaunch)
/// The default stays the shipped behaviour; this file goes once a variant is chosen.
enum TaskListInteraction: Int {
    /// Shipped: list-level contextMenu(forSelectionType:) with menu + primaryAction (double-click).
    case listMenuAndPrimaryAction = 0
    /// List-level contextMenu(forSelectionType:) menu only; no double-click.
    case listMenuOnly = 1
    /// Per-row .contextMenu only; no double-click.
    case rowMenuOnly = 2
    /// Per-row .contextMenu + simultaneous double-click gesture (#20 at 503614b; crashed).
    case rowMenuAndGesture = 3

    static let current = TaskListInteraction(rawValue: UserDefaults.standard.integer(forKey: "debug.taskListInteraction")) ?? .listMenuAndPrimaryAction
}

@MainActor
extension View {
    /// On the `List`: the list-level variants (0, 1).
    func taskListActions<Items: View>(open: @escaping (String) -> Void, @ViewBuilder menu: @escaping (String) -> Items) -> some View {
        modifier(TaskListActions(open: open, menu: menu))
    }

    /// On each row: the per-row variants (2, 3).
    func taskRowActions<Items: View>(open: @escaping () -> Void, @ViewBuilder menu: () -> Items) -> some View {
        modifier(TaskRowActions(open: open, menu: menu()))
    }
}

@MainActor
private struct TaskListActions<Items: View>: ViewModifier {
    let open: (String) -> Void
    let menu: (String) -> Items

    func body(content: Content) -> some View {
        switch TaskListInteraction.current {
        case .listMenuAndPrimaryAction:
            content.contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first { menu(id) }
            } primaryAction: { ids in
                if let id = ids.first { open(id) }
            }
        case .listMenuOnly:
            content.contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first { menu(id) }
            }
        case .rowMenuOnly, .rowMenuAndGesture:
            content
        }
    }
}

@MainActor
private struct TaskRowActions<Items: View>: ViewModifier {
    let open: () -> Void
    let menu: Items

    func body(content: Content) -> some View {
        switch TaskListInteraction.current {
        case .listMenuAndPrimaryAction, .listMenuOnly:
            content
        case .rowMenuOnly:
            content.contextMenu { menu }
        case .rowMenuAndGesture:
            content
                .contextMenu { menu }
                .simultaneousGesture(TapGesture(count: 2).onEnded { open() })
        }
    }
}
