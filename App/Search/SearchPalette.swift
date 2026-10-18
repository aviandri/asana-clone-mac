import AppKit
import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

/// ⌘K: tasks, projects and people (SPEC-MAC §5). Min 2 characters and the 250 ms debounce live in
/// SearchStore. ↑/↓ move, Return opens, Escape closes. People open a mail draft (like the web).
struct SearchPalette: View {
    @Bindable var search: SearchStore
    let onOpen: (NavigationTarget) -> Void

    @State private var selected = 0
    @FocusState private var fieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let items = PaletteItem.items(from: search.results)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search tasks, projects and people", text: $search.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .accessibilityIdentifier("search.field")
                    // Return during the debounce would open a result for the previous query.
                    .onSubmit { if !search.isSearching { open(items, at: selected) } }
                    .onKeyPress(.downArrow) { move(+1, count: items.count) }
                    .onKeyPress(.upArrow) { move(-1, count: items.count) }
                if search.isSearching { ProgressView().controlSize(.small) }
            }
            .padding(12)
            Divider()
            results(items)
                .frame(minHeight: 120, maxHeight: 380)
        }
        .frame(width: 560)
        // Fallback if the text field's editor doesn't pass the arrows to the handlers above.
        .onKeyPress(.downArrow) { move(+1, count: items.count) }
        .onKeyPress(.upArrow) { move(-1, count: items.count) }
        .onAppear {
            fieldFocused = true
            selected = 0
        }
        .onChange(of: items.map(\.id)) { _, _ in selected = 0 }
        .onExitCommand { dismiss() }
    }

    @ViewBuilder private func results(_ items: [PaletteItem]) -> some View {
        if let error = search.lastError {
            Text(error.message).foregroundStyle(.red).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if search.query.trimmingCharacters(in: .whitespaces).count < SearchStore.minimumLength {
            Text("Type at least \(SearchStore.minimumLength) characters.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if search.isEmpty {
            Text("No results").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index == 0 || items[index - 1].group != item.group {
                                Text(item.group.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 8)
                            }
                            Button {
                                open(items, at: index)
                            } label: {
                                PaletteRow(item: item, isSelected: index == selected)
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                            .accessibilityIdentifier(item.accessibilityID)
                            // Add and remove explicitly: a conditional add alone leaves the trait behind.
                            .accessibilityAddTraits(index == selected ? .isSelected : [])
                            .accessibilityRemoveTraits(index == selected ? [] : .isSelected)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onChange(of: selected) { _, index in
                    if items.indices.contains(index) { proxy.scrollTo(items[index].id) }
                }
            }
        }
    }

    private func move(_ delta: Int, count: Int) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        selected = (selected + delta + count) % count
        return .handled
    }

    private func open(_ items: [PaletteItem], at index: Int) {
        guard items.indices.contains(index) else { return }
        switch items[index].kind {
        case .task(let id):
            onOpen(search.target(forTask: id))
        case .project(let id):
            onOpen(.project(id: id))
        case .person(let email):
            if let url = URL(string: "mailto:\(email)") { NSWorkspace.shared.open(url) }
        }
        dismiss()
    }
}

/// One palette result, flattened in display order (Tasks, Projects, People).
struct PaletteItem: Identifiable, Equatable {
    enum Group: Equatable {
        case tasks, projects, people
        var title: String {
            switch self {
            case .tasks: "Tasks"
            case .projects: "Projects"
            case .people: "People"
            }
        }
    }
    enum Kind: Equatable { case task(String), project(String), person(email: String) }

    let id: String
    let group: Group
    let kind: Kind
    let title: String
    let subtitle: String?
    let color: String?
    let user: UserSummary?

    /// `search.result.task.<id>`, `search.result.project.<id>`, `search.result.person.<email>` (UI tests).
    var accessibilityID: String {
        switch kind {
        case .task(let id): "search.result.task.\(id)"
        case .project(let id): "search.result.project.\(id)"
        case .person(let email): "search.result.person.\(email)"
        }
    }

    static func items(from results: SearchResults?) -> [PaletteItem] {
        guard let results else { return [] }
        let tasks = results.tasks.map {
            PaletteItem(id: "t:\($0.id)", group: .tasks, kind: .task($0.id), title: $0.title, subtitle: $0.project?.name, color: $0.project?.color, user: nil)
        }
        let projects = results.projects.map {
            PaletteItem(id: "p:\($0.id)", group: .projects, kind: .project($0.id), title: $0.name, subtitle: nil, color: $0.color, user: nil)
        }
        let people = results.users.map {
            PaletteItem(id: "u:\($0.id)", group: .people, kind: .person(email: $0.email), title: $0.name, subtitle: $0.email, color: nil, user: $0)
        }
        return tasks + projects + people
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            switch item.kind {
            case .task:
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
            case .project:
                Circle().fill(Color(hex: item.color ?? "")).frame(width: 10, height: 10)
            case .person:
                Avatar(user: item.user, size: 18)
            }
            Text(item.title).lineLimit(1)
            if let subtitle = item.subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if isSelected {
                Image(systemName: "return").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor.opacity(0.18) : .clear))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
