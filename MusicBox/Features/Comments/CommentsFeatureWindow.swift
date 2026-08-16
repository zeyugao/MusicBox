import AppKit
import Foundation
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
        if let controller = controllers[target], let window = controller.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(
            rootView: CommentsFeatureWindowContent(target: target, repository: repository)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = target.windowTitle
        window.setContentSize(NSSize(width: 920, height: 680))
        window.minSize = NSSize(width: 720, height: 520)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self

        let controller = NSWindowController(window: window)
        controller.shouldCascadeWindows = false
        controllers[target] = controller
        position(window)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let target = controllers.first(where: { $0.value.window === window })?.key
        else { return }
        controllers.removeValue(forKey: target)
    }

    private func position(_ window: NSWindow) {
        guard let anchor = NSApp.mainWindow ?? NSApp.keyWindow else {
            window.center()
            return
        }
        var frame = window.frame
        frame.origin.x = anchor.frame.midX - frame.width / 2
        frame.origin.y = anchor.frame.midY - frame.height / 2
        if let visible = anchor.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: false)
    }
}

private struct CommentsFeatureWindowContent: View {
    @State private var model: CommentsFeatureModel
    @State private var expandedCommentIDs: Set<UInt64> = []

    init(target: CommentsTarget, repository: any CommentsRepository) {
        _model = State(initialValue: CommentsFeatureModel(target: target, repository: repository))
    }

    var body: some View {
        Group {
            if model.isLoading && model.comments.isEmpty {
                ProgressView()
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                commentScrollView
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("", selection: Binding(get: { model.sort }, set: { model.changeSort($0) })) {
                    Text("热门").tag(CommentsSort.hot)
                    Text("推荐").tag(CommentsSort.recommend)
                    Text("时间").tag(CommentsSort.time)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button {
                    expandedCommentIDs.removeAll()
                    model.load()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新")
            }
        }
        .task { model.load() }
        .onChange(of: model.sort) { _, _ in
            expandedCommentIDs.removeAll()
        }
    }

    private var commentScrollView: some View {
        ScrollView {
            HStack(alignment: .top) {
                Spacer(minLength: 0)
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let error = model.errorMessage, !error.isEmpty {
                        Text(error)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if model.comments.isEmpty {
                        if model.errorMessage == nil {
                            Text("暂无评论")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(model.comments) { comment in
                            CommentListItem(
                                comment: comment,
                                thread: model.floorThreads[comment.commentId],
                                isLoading: model.floorLoadingIDs.contains(comment.commentId),
                                error: model.floorErrorMessages[comment.commentId],
                                isExpanded: expandedCommentIDs.contains(comment.commentId),
                                toggleReplies: { toggleReplies(for: comment.commentId) },
                                loadMore: { model.loadMoreFloor(parentCommentID: comment.commentId) }
                            )
                        }
                    }
                    if model.hasMore {
                        HStack {
                            Spacer()
                            ProgressView().controlSize(.small)
                            Spacer()
                        }
                        .id(model.comments.count)
                        .onAppear { model.loadMore() }
                    }
                }
                .padding(.top, 6)
                .frame(maxWidth: 720, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .transaction { $0.animation = nil }
    }

    private func toggleReplies(for id: UInt64) {
        if expandedCommentIDs.contains(id) {
            expandedCommentIDs.remove(id)
            model.cancelFloor(parentCommentID: id)
        } else {
            expandedCommentIDs.insert(id)
            model.loadFloor(parentCommentID: id)
        }
    }
}

private struct CommentListItem: View {
    let comment: CloudMusicApi.Comment
    let thread: CommentFloorThread?
    let isLoading: Bool
    let error: String?
    let isExpanded: Bool
    let toggleReplies: () -> Void
    let loadMore: () -> Void

    private var replyCount: Int { comment.showFloorComment?.replyCount ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CommentRow(comment: comment)
            if replyCount > 0 {
                Button {
                    toggleReplies()
                } label: {
                    Text(isExpanded ? "收起回复" : "展开回复 (\(replyCount))")
                        .font(.caption)
                }
                .buttonStyle(.link)
                .padding(.leading, 38)
            }
            if replyCount > 0, isExpanded {
                FloorReplies(
                    thread: thread,
                    isLoading: isLoading,
                    error: error,
                    loadMore: loadMore
                )
                .padding(.leading, 38)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CommentRow: View {
    let comment: CloudMusicApi.Comment
    var floorOwnerUserID: UInt64?

    private var content: String {
        let normalized = CommentTextSanitizer.sanitize(comment.richContent ?? comment.content)
        return normalized.isEmpty ? CommentTextSanitizer.sanitize(comment.content) : normalized
    }

    private var replyingTo: String? {
        guard let reply = comment.beReplied?.first,
              let original = reply.richContent ?? reply.content
        else { return nil }
        if let floorOwnerUserID, reply.user?.userId == floorOwnerUserID { return nil }
        let text = CommentTextSanitizer.sanitize(original)
        guard !text.isEmpty else { return nil }
        return "↪︎ \(reply.user?.nickname ?? "Unknown"): \(text)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AsyncImage(url: URL(string: comment.user.avatarUrl?.https ?? "")) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Circle().fill(Color.gray.opacity(0.25))
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(comment.user.nickname)
                        .font(.subheadline.weight(.medium))
                    if let time = comment.timeStr {
                        Text(time).font(.caption).foregroundStyle(.secondary)
                    }
                    if let location = comment.ipLocation?.location, !location.isEmpty {
                        Text("· \(location)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let likes = comment.likedCount, likes > 0 {
                        Label("\(likes)", systemImage: "hand.thumbsup")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(content).textSelection(.enabled)
                if let replyingTo {
                    Text(replyingTo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct FloorReplies: View {
    let thread: CommentFloorThread?
    let isLoading: Bool
    let error: String?
    let loadMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let thread {
                if thread.comments.isEmpty, !isLoading {
                    Text("暂无回复").foregroundStyle(.secondary)
                }
                ForEach(thread.comments) { comment in
                    CommentRow(comment: comment, floorOwnerUserID: thread.ownerComment?.user.userId)
                }
                if thread.hasMore {
                    HStack {
                        Spacer()
                        if isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("加载更多评论", action: loadMore)
                                .buttonStyle(.link)
                        }
                        Spacer()
                    }
                }
            } else if isLoading {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
            }
            if let error, !error.isEmpty {
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

private enum CommentTextSanitizer {
    private static let closingCVT = try! NSRegularExpression(
        pattern: "<c0m_cvt\\b[^>]*>.*?</c0m_cvt>|<c0m_cvt\\b[^>]*/>",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let lineBreak = try! NSRegularExpression(pattern: "<br\\s*/?>", options: .caseInsensitive)
    private static let tags = try! NSRegularExpression(pattern: "<[^>]+>", options: [.caseInsensitive, .dotMatchesLineSeparators])

    static func sanitize(_ text: String) -> String {
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        let withoutCVT = closingCVT.stringByReplacingMatches(in: text, range: full, withTemplate: "")
        let brRange = NSRange(withoutCVT.startIndex..<withoutCVT.endIndex, in: withoutCVT)
        let withBreaks = lineBreak.stringByReplacingMatches(in: withoutCVT, range: brRange, withTemplate: "\n")
        let tagRange = NSRange(withBreaks.startIndex..<withBreaks.endIndex, in: withBreaks)
        let stripped = tags.stringByReplacingMatches(in: withBreaks, range: tagRange, withTemplate: "")
        let decoded = CFXMLCreateStringByUnescapingEntities(nil, stripped as CFString, nil) as String? ?? stripped
        return decoded.replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
