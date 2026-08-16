import AppKit
import SwiftUI

@MainActor
final class CommentsWindowManager: NSObject, NSWindowDelegate {
    static let shared = CommentsWindowManager()

    private var repository: (any CommentsRepository)?
    private var controllers: [CommentsTarget: NSWindowController] = [:]

    func configure(repository: any CommentsRepository) {
        self.repository = repository
    }

    func show(target: CommentsTarget) {
        guard let repository else { return }
        if let existing = controllers[target], let window = existing.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = CommentsWindowView(target: target, repository: repository)
        let controller = NSWindowController(window: NSWindow(contentViewController: NSHostingController(rootView: view)))
        guard let window = controller.window else { return }
        window.title = String(localized: "comments.title") + " - " + target.title
        window.setContentSize(NSSize(width: 780, height: 600))
        window.minSize = NSSize(width: 620, height: 440)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        controllers[target] = controller
        controller.showWindow(nil)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            let target = controllers.first(where: { $0.value.window === window })?.key
        else { return }
        controllers.removeValue(forKey: target)
    }
}

private struct CommentsWindowView: View {
    @State private var model: CommentsFeatureModel

    init(target: CommentsTarget, repository: any CommentsRepository) {
        _model = State(initialValue: CommentsFeatureModel(target: target, repository: repository))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(String(localized: "comments.sort"), selection: Binding(
                    get: { model.sort },
                    set: { model.changeSort($0) }
                )) {
                    Text(String(localized: "comments.hot")).tag(CommentsSort.hot)
                    Text(String(localized: "comments.recommend")).tag(CommentsSort.recommend)
                    Text(String(localized: "comments.time")).tag(CommentsSort.time)
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Spacer()
                Button {
                    model.load()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(String(localized: "action.refresh"))
            }
            .padding(12)
            Divider()

            if model.isLoading && model.comments.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.errorMessage, model.comments.isEmpty {
                ContentUnavailableView(String(localized: "state.error"), systemImage: "exclamationmark.triangle", description: Text(error))
            } else if model.comments.isEmpty {
                ContentUnavailableView(String(localized: "comments.empty"), systemImage: "text.bubble")
            } else {
                List {
                    ForEach(Array(model.comments.enumerated()), id: \.element.id) { index, comment in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(comment.user.nickname).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(comment.timeStr ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(comment.content)
                                .textSelection(.enabled)
                            if let location = comment.ipLocation?.location, !location.isEmpty {
                                Text(location).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 5)
                        .onAppear {
                            if index == model.comments.indices.last { model.loadMore() }
                        }
                    }
                    if model.isLoadingMore {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                }
                .listStyle(.inset)
            }
        }
        .task { model.load() }
    }
}
