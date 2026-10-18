import AppKit
import SwiftUI

/// The one "add" text field (tasks in lists, board columns, My Tasks; subtasks): Return adds and keeps
/// focus for the next one, Esc clears and leaves.
///
/// AppKit, not a SwiftUI TextField, on purpose (rc1 QA crash). Inside a `List` row, SwiftUI pushed
/// its text binding into the recycled field editor during row updates. NSTextView's undo
/// registration (NSUndoReplaceCharacters) then threw NSRangeException, which unwound through
/// AttributeGraph/Observation and corrupted memory seconds later. So here:
/// - there is no text binding, and `updateNSView` never writes `stringValue`; the field owns its text;
/// - the cell has `allowsUndo = false`, so its field editor registers no undo (per field: other text
///   fields sharing the window's field editor keep undo);
/// - after an add the field ends editing, clears, and takes focus back on the next turn.
@MainActor
struct AddItemField: NSViewRepresentable {
    var placeholder: String
    var accessibilityID: String
    var accessibilityLabel: String
    let onAdd: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onAdd: onAdd) }

    func makeNSView(context: Context) -> UndoFreeTextField {
        let field = UndoFreeTextField()
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.allowsUndo = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier(accessibilityID)
        field.setAccessibilityLabel(accessibilityLabel)
        return field
    }

    func updateNSView(_ field: UndoFreeTextField, context: Context) {
        context.coordinator.onAdd = onAdd
        // Never touch stringValue here: this runs during List row updates, possibly mid-edit.
        if field.currentEditor() == nil, field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onAdd: (String) -> Void

        init(onAdd: @escaping (String) -> Void) {
            self.onAdd = onAdd
        }

        // nonisolated + assumeIsolated: the delegate protocol is main-actor on the macOS 15 SDK but
        // not necessarily on 14.5 (Xcode 15.4); AppKit calls it on the main thread either way.
        nonisolated func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            MainActor.assumeIsolated { handle(control, textView: textView, selector: selector) }
        }

        private func handle(_ control: NSControl, textView: NSTextView, selector: Selector) -> Bool {
            guard let field = control as? NSTextField else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let title = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return true }
                onAdd(title)
                reset(field, refocus: true)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                reset(field, refocus: false)
                return true
            default:
                return false
            }
        }

        /// End editing first, then clear the (no longer live) cell, then optionally come back.
        private func reset(_ field: NSTextField, refocus: Bool) {
            field.window?.makeFirstResponder(nil)
            field.stringValue = ""
            guard refocus else { return }
            DispatchQueue.main.async { [weak field] in
                MainActor.assumeIsolated {
                    guard let field, let window = field.window else { return }
                    window.makeFirstResponder(field)
                }
            }
        }
    }
}

/// Re-applies "no undo" to the shared field editor each time this field takes it (the cell's
/// `allowsUndo` covers setup; this covers editors set up before the cell changed).
final class UndoFreeTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, let editor = currentEditor() as? NSTextView {
            editor.allowsUndo = false
        }
        return became
    }
}

/// An add row: "+" and the field. `AddTaskRow` for tasks; the subtask field uses `AddItemField` directly.
@MainActor
struct AddTaskRow: View {
    var placeholder = "Add task"
    let onAdd: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").foregroundStyle(.secondary).accessibilityHidden(true)
            AddItemField(placeholder: placeholder, accessibilityID: "addTask.field", accessibilityLabel: "New task title", onAdd: onAdd)
        }
        .selectionDisabled()
    }
}
