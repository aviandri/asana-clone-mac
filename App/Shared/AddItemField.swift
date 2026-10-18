import AppKit
import os
import SwiftUI

/// The one "add" text field (tasks in lists, board columns, My Tasks; subtasks): Return adds and keeps
/// focus for the next one, Esc clears and leaves.
///
/// AppKit, not a SwiftUI TextField, on purpose (rc1 QA crash). Inside a `List` row, SwiftUI pushed
/// its text binding into the recycled field editor during row updates. NSTextView's undo
/// registration (NSUndoReplaceCharacters) then threw NSRangeException, which unwound through
/// AttributeGraph/Observation and corrupted memory seconds later. So here:
/// - there is no text binding, and `updateNSView` never writes `stringValue`; the field owns its text;
/// - the field edits in its OWN field editor (an NSTextView with undo off, from its cell), never the
///   window's shared one, so no undo is registered here and other fields' undo is untouched (a first
///   version turned undo off on the shared editor and broke ⌘Z in the inspector, rc1 QA);
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

        nonisolated func controlTextDidEndEditing(_ notification: Notification) {
            MainActor.assumeIsolated {
                (notification.object as? UndoFreeTextField)?.dropUndo()
            }
        }

        /// End editing first, then clear the (no longer live) cell, then optionally come back.
        private func reset(_ field: NSTextField, refocus: Bool) {
            field.window?.makeFirstResponder(nil)
            field.stringValue = ""
            (field as? UndoFreeTextField)?.dropUndo()
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

/// An NSTextField that edits in a private, undo-free field editor (see `UndoFreeTextFieldCell`).
final class UndoFreeTextField: NSTextField {
    private static let log = Logger(subsystem: "com.mekari.project", category: "AddItemField")

    override class var cellClass: AnyClass? {
        get { UndoFreeTextFieldCell.self }
        set {}
    }

    /// Belt and braces for every build configuration: if AppKit handed this field the window's
    /// SHARED field editor (the cell's `fieldEditor(for:)` not consulted), a SwiftUI TextField that
    /// last used that editor can push its text into it while we type (v0.1.0 Release crash). So
    /// verify, log, and restart editing in the private editor explicitly.
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        guard became, let cell = cell as? UndoFreeTextFieldCell else { return became }
        if let editor = currentEditor(), editor === cell.editor { return became }
        Self.log.error("AddItemField got the shared field editor; switching to its private editor")
        window?.endEditing(for: self)
        if let editor = cell.fieldEditor(for: self) {
            let end = (stringValue as NSString).length
            cell.select(withFrame: bounds, in: self, editor: editor, delegate: self, start: end, length: 0)
        }
        return became
    }

    /// The private field editor, created on first edit.
    var privateEditor: NSTextView? { (cell as? UndoFreeTextFieldCell)?.editor }

    /// Nothing should be registered (undo is off), but make sure no undo entry can outlive an edit
    /// and later run against storage that was cleared.
    func dropUndo() {
        guard let editor = privateEditor else { return }
        let manager = window?.undoManager
        manager?.removeAllActions(withTarget: editor)
        if let storage = editor.textStorage { manager?.removeAllActions(withTarget: storage) }
    }
}

/// Hands its control a private field editor with undo off, instead of the window's shared one.
/// AppKit's editor setup copies the cell's `allowsUndo` onto the editor (default true), so the cell
/// says no too, and the setup is overridden to keep it off.
final class UndoFreeTextFieldCell: NSTextFieldCell {
    private(set) var editor: NSTextView?

    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let text = super.setUpFieldEditorAttributes(textObj)
        (text as? NSTextView)?.allowsUndo = false
        return text
    }

    // No init overrides: a Swift subclass that overrides one designated init stops inheriting the
    // others, and AppKit may create cells through any of them.
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        allowsUndo = false
        if let editor { return editor }
        let editor = NSTextView()
        editor.isFieldEditor = true
        editor.allowsUndo = false
        self.editor = editor
        return editor
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
