import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

/// People picker backed by `UserSearch` (`GET /users?q=`, debounced in Features). Guests get a badge (W8).
struct UserPickerView: View {
    @State private var search: UserSearch
    var selectedID: String?
    var allowsNone = false
    var excludedIDs: Set<String> = []
    let onPick: (UserSummary?) -> Void

    init(search: UserSearch, selectedID: String? = nil, allowsNone: Bool = false, excludedIDs: Set<String> = [], onPick: @escaping (UserSummary?) -> Void) {
        // Only the first instance is kept; `UserSearch` does no work until the query changes.
        _search = State(initialValue: search)
        self.selectedID = selectedID
        self.allowsNone = allowsNone
        self.excludedIDs = excludedIDs
        self.onPick = onPick
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search people", text: $search.query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search people")
            List {
                if allowsNone, selectedID != nil {
                    Button {
                        onPick(nil)
                    } label: {
                        Label("No assignee", systemImage: "person.crop.circle.badge.minus")
                    }
                    .buttonStyle(.plain)
                }
                ForEach(search.results.filter { !excludedIDs.contains($0.id) }) { person in
                    Button {
                        onPick(person.user)
                    } label: {
                        PersonRow(person: person, isSelected: person.id == selectedID)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .overlay {
                if let error = search.lastError {
                    Text(error.message).foregroundStyle(.red).font(.callout).multilineTextAlignment(.center).padding()
                } else if search.isLoading && search.results.isEmpty {
                    ProgressView().controlSize(.small)
                } else if !search.isLoading && search.results.isEmpty {
                    Text("No matches").foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(width: 300, height: 320)
        // Open with everyone listed (an empty query loads all pickable people), not "No matches".
        .onAppear { if search.results.isEmpty { search.query = "" } }
    }
}

struct PersonRow: View {
    let person: PickableUser
    var isSelected = false

    var body: some View {
        HStack(spacing: 8) {
            Avatar(user: person.user, size: 22)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(person.name)
                    if person.isGuest { GuestPill() }
                }
                Text(person.email).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("Selected")
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
