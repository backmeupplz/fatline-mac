import SwiftUI

/// The people this account follows. Hiding someone changes the feed behind it right away.
struct PeopleView: View {
    let model: FeedModel

    @State private var error: String?

    var body: some View {
        let people = model.people
        VStack(spacing: 0) {
            FatlineDivider()
            // Above the scroll view, so a failed toggle far down the list is still seen.
            if let message = error ?? (model.peopleRefreshFailed ? "Couldn’t refresh. Try again in a minute." : nil) {
                FeedMessage(text: message)
                CastDivider()
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(people) { person in
                        row(person)
                        if person.id != people.last?.id { CastDivider() }
                    }
                    Text("To change who you follow, use the Farcaster app.")
                        .font(FatlineStyle.meta)
                        .foregroundStyle(FatlineStyle.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, FatlineStyle.gutter)
                        .padding(.vertical, FatlineStyle.rowPadding)
                }
            }
        }
        .background(FatlineStyle.paper)
        .navigationTitle("People")
        .settingsTitleBar()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                refreshButton
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }

    /// Only this button rereads the list, because it costs credits and the feed doesn't need it to stay current.
    private var refreshButton: some View {
        Button {
            Task { await model.refreshPeople() }
        } label: {
            ZStack {
                Image(systemName: "arrow.clockwise")
                    .font(FatlineStyle.body)
                    .foregroundStyle(FatlineStyle.secondary)
                    .opacity(model.refreshingPeople ? 0 : 1)
                if model.refreshingPeople { ProgressView().controlSize(.small) }
            }
        }
        .disabled(model.refreshingPeople)
        .accessibilityLabel(model.refreshingPeople ? "Refreshing people you follow" : "Refresh people you follow")
        .accessibilityIdentifier("refresh-people")
    }

    private func row(_ person: FeedModel.Person) -> some View {
        let hidden = model.isHidden(person)
        let action = hidden ? "Unhide" : "Hide"
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(person.handle)
                .font(FatlineStyle.bodyStrong)
                .foregroundStyle(hidden ? FatlineStyle.secondary : FatlineStyle.ink)
            Spacer(minLength: 8)
            Button {
                do {
                    try model.toggleVisibility(person)
                    error = nil
                } catch { self.error = "Couldn’t save the change." }
            } label: {
                Text(action)
                    .font(FatlineStyle.body)
                    .foregroundStyle(hidden ? FatlineStyle.ink : FatlineStyle.secondary)
                    .frame(minWidth: 56, minHeight: FatlineStyle.compactButtonHeight, alignment: .trailing)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(action) \(person.handle)")
        }
        .padding(.horizontal, FatlineStyle.gutter)
        .padding(.vertical, 3)
    }
}
