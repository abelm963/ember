import SwiftUI
import EmberKit

/// 3 · Who's watching? Every profile saved on this Apple TV for this server.
struct ProfilesView: View {
    @EnvironmentObject var app: AppModel
    @State private var editing = false
    @FocusState private var focused: String?

    var body: some View {
        VStack(spacing: 70) {
            Text("ember").font(.display(54)).displayTracking(54).foregroundStyle(C.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 40)
            Spacer(minLength: 0)
            Text(editing ? "Remove a profile" : "Who's watching?")
                .font(.display(84)).displayTracking(84).foregroundStyle(C.text)
            HStack(spacing: 56) {
                ForEach(app.serverAccounts) { acc in
                    profile(acc)
                }
                if !editing {
                    Button {
                        app.phase = .signIn
                    } label: {
                        VStack(spacing: 24) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 50, style: .continuous).fill(C.surface2)
                                Image(systemName: "plus").font(.system(size: 80, weight: .semibold)).foregroundStyle(C.muted)
                            }
                            .frame(width: 230, height: 230)
                            Text("Add Profile").font(.body(30, weight: .semibold)).foregroundStyle(C.muted)
                        }
                    }
                    .buttonStyle(LiftStyle(radius: 50, scale: 1.08))
                    .focused($focused, equals: "add")
                }
            }
            .focusSection()
            Spacer(minLength: 0)
            EmberButton(title: editing ? "Done" : "Manage Profiles", icon: editing ? "checkmark" : "pencil", kind: .ghost,
                        compact: true) { editing.toggle() }
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = app.currentAccountId ?? app.serverAccounts.first?.id }
    }

    private func profile(_ acc: Account) -> some View {
        Button {
            if editing {
                Task {
                    await app.remove(acc)
                    if app.serverAccounts.isEmpty { editing = false }
                }
            } else {
                app.select(acc)
            }
        } label: {
            VStack(spacing: 24) {
                ZStack(alignment: .topTrailing) {
                    Avatar(name: acc.name, image: app.imageURL(for: acc), size: 230)
                    if editing {
                        Image(systemName: "minus.circle.fill").font(.system(size: 54)).foregroundStyle(C.bad)
                            .background(Circle().fill(C.bg)).offset(x: 18, y: -18)
                    }
                }
                Text(acc.name).font(.body(30, weight: .semibold)).foregroundStyle(C.text).lineLimit(1)
            }
            .frame(width: 250)
        }
        .buttonStyle(LiftStyle(radius: 50, scale: 1.08))
        .focused($focused, equals: acc.id)
    }
}
