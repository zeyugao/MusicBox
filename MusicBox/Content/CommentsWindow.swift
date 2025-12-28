//
//  CommentsWindow.swift
//  MusicBox
//
//  Created by Elsa on 2025/12/28.
//

import Cocoa
import SwiftUI

private enum CommentTextSanitizer {
    static let cvtSelfClosingRegex = try! NSRegularExpression(
        pattern: "<c0m_cvt\\b[^>]*/>",
        options: [.caseInsensitive]
    )
    static let cvtWrappedRegex = try! NSRegularExpression(
        pattern: "<c0m_cvt\\b[^>]*>.*?</c0m_cvt>",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    static func sanitize(_ text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let withoutWrapped = cvtWrappedRegex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: ""
        )
        let range2 = NSRange(withoutWrapped.startIndex..<withoutWrapped.endIndex, in: withoutWrapped)
        return cvtSelfClosingRegex.stringByReplacingMatches(
            in: withoutWrapped,
            options: [],
            range: range2,
            withTemplate: ""
        )
    }
}

private extension String {
    var sanitizedCommentText: String {
        CommentTextSanitizer.sanitize(self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CommentsTargetKind: String, Codable, Hashable {
    case playlist
    case song
}

struct CommentsTarget: Hashable, Codable, Identifiable {
    let kind: CommentsTargetKind
    let resourceId: UInt64
    let name: String
    let subtitle: String?

    var id: String { "\(kind.rawValue)-\(resourceId)" }

    var resourceType: CloudMusicApi.CommentResourceType {
        switch kind {
        case .playlist:
            return .playlist
        case .song:
            return .music
        }
    }

    var windowTitle: String {
        switch kind {
        case .playlist:
            return "评论 · \(name)"
        case .song:
            if let subtitle, !subtitle.isEmpty {
                return "评论 · \(name) · \(subtitle)"
            }
            return "评论 · \(name)"
        }
    }

    static func playlist(id: UInt64, name: String) -> Self {
        CommentsTarget(kind: .playlist, resourceId: id, name: name, subtitle: nil)
    }

    static func song(id: UInt64, name: String, subtitle: String? = nil) -> Self {
        CommentsTarget(kind: .song, resourceId: id, name: name, subtitle: subtitle)
    }
}

enum CommentsSortOption: CaseIterable, Hashable, Identifiable {
    case hot
    case recommend
    case time

    var id: String { title }

    var title: String {
        switch self {
        case .hot:
            return "热门"
        case .recommend:
            return "推荐"
        case .time:
            return "时间"
        }
    }

    var apiSortType: CloudMusicApi.CommentNewSortType {
        switch self {
        case .hot:
            return .hot
        case .recommend:
            return .recommend
        case .time:
            return .time
        }
    }
}

@MainActor
final class CommentsWindowManager: NSObject, NSWindowDelegate {
    static let shared = CommentsWindowManager()

    private var controllers: [CommentsTarget: NSWindowController] = [:]

    private static func position(_ window: NSWindow, near anchorWindow: NSWindow) {
        var frame = window.frame
        let anchorFrame = anchorWindow.frame

        frame.origin.x = anchorFrame.midX - frame.width / 2
        frame.origin.y = anchorFrame.midY - frame.height / 2

        let screen = anchorWindow.screen ?? NSScreen.main
        if let visibleFrame = screen?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - frame.height)
        }

        window.setFrame(frame, display: false)
    }

    func show(target: CommentsTarget) {
        if let existing = controllers[target], let window = existing.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = CommentsWindowView(target: target)
        let hostingController = NSHostingController(rootView: rootView)

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

        if let mainWindow = AppDelegate.mainWindow, mainWindow.isVisible {
            Self.position(window, near: mainWindow)
        } else if let keyWindow = NSApp.keyWindow, keyWindow.isVisible {
            Self.position(window, near: keyWindow)
        } else {
            window.center()
        }

        controller.showWindow(nil)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let (target, _) = controllers.first(where: { $0.value.window === window }) {
            controllers.removeValue(forKey: target)
        }
    }
}

@MainActor
final class CommentsViewModel: ObservableObject {
    struct FloorThread: Equatable {
        let parentCommentId: UInt64
        var ownerComment: CloudMusicApi.Comment?
        var bestComments: [CloudMusicApi.Comment]
        var comments: [CloudMusicApi.Comment]
        var hasMore: Bool
        var nextTime: Int64?
        var totalCount: Int
    }

    let target: CommentsTarget

    @Published private(set) var comments: [CloudMusicApi.Comment] = []
    @Published private(set) var totalCount: Int = 0
    @Published private(set) var hasMore: Bool = false
    @Published private(set) var isLoading: Bool = true
    @Published private(set) var isLoadingMore: Bool = false
    @Published private(set) var errorMessage: String?

    @Published private(set) var floorThreads: [UInt64: FloorThread] = [:]
    @Published private(set) var floorLoadingIds: Set<UInt64> = []
    @Published private(set) var floorErrorMessages: [UInt64: String] = [:]

    private let pageSize: Int = 30
    private var pageNo: Int = 1
    private var timeCursor: Int64? = nil
    private var sortOption: CommentsSortOption = .hot

    private var loadTask: Task<Void, Never>?
    private var loadMoreTask: Task<Void, Never>?
    private var floorTasks: [UInt64: Task<Void, Never>] = [:]

    init(target: CommentsTarget) {
        self.target = target
    }

    func changeSort(to option: CommentsSortOption) {
        guard sortOption != option else { return }
        sortOption = option
        loadInitial()
    }

    func loadInitial() {
        loadTask?.cancel()
        loadMoreTask?.cancel()
        for task in floorTasks.values {
            task.cancel()
        }
        floorTasks.removeAll()
        isLoading = true
        errorMessage = nil
        comments = []
        hasMore = false
        totalCount = 0
        isLoadingMore = false
        pageNo = 1
        timeCursor = nil
        floorThreads = [:]
        floorLoadingIds.removeAll()
        floorErrorMessages = [:]

        let target = target
        let sortOption = sortOption
        let pageSize = pageSize
        loadTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let page = try await Self.fetchComments(
                    target: target,
                    pageNo: 1,
                    pageSize: pageSize,
                    sortOption: sortOption,
                    cursor: nil
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    guard self.sortOption == sortOption else { return }
                    self.comments = page.comments ?? []
                    self.totalCount = page.totalCount ?? 0
                    self.hasMore = page.hasMore ?? false
                    self.pageNo = 1
                    if sortOption == .time {
                        self.timeCursor = Self.extractTimeCursor(from: page.cursor)
                    }
                    self.isLoading = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    func loadMore() {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        loadMoreTask?.cancel()
        isLoadingMore = true
        errorMessage = nil

        let target = target
        let sortOption = sortOption
        let pageSize = pageSize
        let nextPageNo = pageNo + 1
        let cursor = sortOption == .time ? timeCursor : nil
        loadMoreTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let page = try await Self.fetchComments(
                    target: target,
                    pageNo: nextPageNo,
                    pageSize: pageSize,
                    sortOption: sortOption,
                    cursor: cursor
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    guard self.sortOption == sortOption else { return }
                    let newComments = page.comments ?? []
                    if !newComments.isEmpty {
                        self.comments.append(contentsOf: newComments)
                    }
                    self.hasMore = page.hasMore ?? false
                    self.totalCount = page.totalCount ?? self.totalCount
                    self.pageNo = nextPageNo
                    if sortOption == .time {
                        self.timeCursor = Self.extractTimeCursor(from: page.cursor)
                    }
                    self.isLoadingMore = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.errorMessage = error.localizedDescription
                    self.isLoadingMore = false
                }
            }
        }
    }

    private static func extractTimeCursor(from cursor: IntOrString?) -> Int64? {
        guard let cursor else { return nil }
        switch cursor {
        case .int(let value):
            return Int64(value)
        case .string(let value):
            return Int64(value)
        }
    }

    func loadFloorThread(parentCommentId: UInt64) {
        guard floorThreads[parentCommentId] == nil else { return }
        guard !floorLoadingIds.contains(parentCommentId) else { return }
        floorTasks[parentCommentId]?.cancel()
        floorLoadingIds.insert(parentCommentId)
        floorErrorMessages[parentCommentId] = nil

        let target = target
        floorTasks[parentCommentId] = Task.detached(priority: .utility) { [weak self] in
            do {
                let data = try await Self.fetchFloor(
                    target: target,
                    parentCommentId: parentCommentId,
                    limit: 10,
                    time: nil
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.floorThreads[parentCommentId] = FloorThread(
                        parentCommentId: parentCommentId,
                        ownerComment: data.ownerComment,
                        bestComments: data.bestComments ?? [],
                        comments: data.comments ?? [],
                        hasMore: data.hasMore ?? false,
                        nextTime: data.time,
                        totalCount: data.totalCount ?? 0
                    )
                    self.floorLoadingIds.remove(parentCommentId)
                    self.floorTasks[parentCommentId] = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.floorErrorMessages[parentCommentId] = error.localizedDescription
                    self.floorLoadingIds.remove(parentCommentId)
                    self.floorTasks[parentCommentId] = nil
                }
            }
        }
    }

    func loadMoreFloorReplies(parentCommentId: UInt64) {
        guard let thread = floorThreads[parentCommentId], thread.hasMore else { return }
        guard !floorLoadingIds.contains(parentCommentId) else { return }
        floorTasks[parentCommentId]?.cancel()
        floorLoadingIds.insert(parentCommentId)
        floorErrorMessages[parentCommentId] = nil
        let target = target
        let nextTime = thread.nextTime
        floorTasks[parentCommentId] = Task.detached(priority: .utility) { [weak self] in
            do {
                let data = try await Self.fetchFloor(
                    target: target,
                    parentCommentId: parentCommentId,
                    limit: 10,
                    time: nextTime
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, var thread = self.floorThreads[parentCommentId] else { return }

                    let newComments = data.comments ?? []
                    if !newComments.isEmpty {
                        thread.comments.append(contentsOf: newComments)
                    }
                    thread.hasMore = data.hasMore ?? false
                    thread.nextTime = data.time
                    thread.totalCount = data.totalCount ?? thread.totalCount
                    self.floorThreads[parentCommentId] = thread
                    self.floorLoadingIds.remove(parentCommentId)
                    self.floorTasks[parentCommentId] = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.floorErrorMessages[parentCommentId] = error.localizedDescription
                    self.floorLoadingIds.remove(parentCommentId)
                    self.floorTasks[parentCommentId] = nil
                }
            }
        }
    }

    func cancelFloorThread(parentCommentId: UInt64) {
        floorTasks[parentCommentId]?.cancel()
        floorTasks[parentCommentId] = nil
        floorLoadingIds.remove(parentCommentId)
    }

    nonisolated private static func fetchComments(
        target: CommentsTarget,
        pageNo: Int,
        pageSize: Int,
        sortOption: CommentsSortOption,
        cursor: Int64?
    ) async throws -> CloudMusicApi.CommentNewPage.DataPayload {
        try await CloudMusicApi(cacheTtl: 15).comment_new(
            type: target.resourceType,
            id: target.resourceId,
            pageNo: pageNo,
            pageSize: pageSize,
            sortType: sortOption.apiSortType,
            cursor: cursor
        )
    }

    nonisolated private static func fetchFloor(
        target: CommentsTarget,
        parentCommentId: UInt64,
        limit: Int,
        time: Int64?
    ) async throws -> CloudMusicApi.FloorCommentsPage.DataPayload {
        try await CloudMusicApi(cacheTtl: 15).comment_floor(
            parentCommentId: parentCommentId,
            id: target.resourceId,
            type: target.resourceType,
            limit: limit,
            time: time
        )
    }
}

struct CommentsWindowView: View {
    let target: CommentsTarget

    @State private var expandedParentCommentIds: Set<UInt64> = []
    @State private var sortOption: CommentsSortOption = .hot
    @StateObject private var model: CommentsViewModel

    init(target: CommentsTarget) {
        self.target = target
        _model = StateObject(wrappedValue: CommentsViewModel(target: target))
    }

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView()
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                commentsScrollView()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("", selection: $sortOption) {
                    ForEach(CommentsSortOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Button {
                    expandedParentCommentIds.removeAll()
                    model.loadInitial()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新")
            }
        }
        .onAppear {
            model.loadInitial()
        }
        .onChange(of: sortOption) { _, newValue in
            expandedParentCommentIds.removeAll()
            model.changeSort(to: newValue)
        }
    }

    private func toggleReplies(parentCommentId: UInt64) {
        withAnimation(nil) {
            if expandedParentCommentIds.contains(parentCommentId) {
                expandedParentCommentIds.remove(parentCommentId)
                model.cancelFloorThread(parentCommentId: parentCommentId)
                return
            }

            expandedParentCommentIds.insert(parentCommentId)
            model.loadFloorThread(parentCommentId: parentCommentId)
        }
    }

    private func commentsScrollView() -> some View {
        let maxContentWidth: CGFloat = 720

        return ScrollView {
            HStack(alignment: .top) {
                Spacer(minLength: 0)

                LazyVStack(alignment: .leading, spacing: 12) {
                    if let errorMessage = model.errorMessage, !errorMessage.isEmpty {
                        Text(errorMessage)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text(sortOption.title)
                        .font(.headline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if model.comments.isEmpty {
                        if model.errorMessage == nil || model.errorMessage?.isEmpty == true {
                            Text("暂无评论")
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        ForEach(model.comments) { comment in
                            CommentListItemView(
                                comment: comment,
                                model: model,
                                isExpanded: expandedParentCommentIds.contains(comment.commentId),
                                onToggleReplies: toggleReplies(parentCommentId:)
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if model.hasMore {
                        HStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                            Spacer()
                        }
                        .id(model.comments.count)
                        .onAppear {
                            model.loadMore()
                        }
                    }
                }
                .frame(maxWidth: maxContentWidth, alignment: .leading)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

struct CommentRowView: View {
    let comment: CloudMusicApi.Comment
    var showsRepliesIndicator: Bool = true
    var floorOwnerUserId: UInt64? = nil

    private var bodyText: String {
        let text = (comment.richContent ?? comment.content).sanitizedCommentText
        return text.isEmpty ? comment.content.sanitizedCommentText : text
    }

    private var replyingToText: String? {
        guard
            let firstReply = comment.beReplied?.first,
            let repliedUser = firstReply.user
        else { return nil }

        if let floorOwnerUserId, repliedUser.userId == floorOwnerUserId {
            return nil
        }

        return "回复 \(repliedUser.nickname)："
    }

    private var repliesText: String? {
        guard let count = comment.showFloorComment?.replyCount, count > 0 else { return nil }
        return "\(count) 条回复"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AsyncImageWithCache(url: URL(string: comment.user.avatarUrl?.https ?? "")) { image in
                image.resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Circle()
                    .fill(Color.gray.opacity(0.25))
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(comment.user.nickname)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    if let timeStr = comment.timeStr {
                        Text(timeStr)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let location = comment.ipLocation?.location, !location.isEmpty {
                        Text("· \(location)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if let likedCount = comment.likedCount, likedCount > 0 {
                        Label("\(likedCount)", systemImage: "hand.thumbsup")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                }

                Text(bodyText).textSelection(.enabled)

                if let replyingToText {
                    Text(replyingToText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if let repliesText {
                    if showsRepliesIndicator {
                        Text(repliesText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct CommentListItemView: View {
    let comment: CloudMusicApi.Comment
    @ObservedObject var model: CommentsViewModel
    let isExpanded: Bool
    let onToggleReplies: (UInt64) -> Void

    private var replyCount: Int {
        comment.showFloorComment?.replyCount ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CommentRowView(comment: comment, showsRepliesIndicator: false)

            if replyCount > 0 {
                Button {
                    onToggleReplies(comment.commentId)
                } label: {
                    Text(isExpanded ? "收起回复" : "展开回复 (\(replyCount))")
                        .font(.caption)
                }
                .buttonStyle(.link)
                .padding(.leading, 38)
            }

            if replyCount > 0, isExpanded {
                FloorRepliesInlineView(
                    thread: model.floorThreads[comment.commentId],
                    isLoading: model.floorLoadingIds.contains(comment.commentId),
                    errorMessage: model.floorErrorMessages[comment.commentId],
                    onLoadMore: {
                        model.loadMoreFloorReplies(parentCommentId: comment.commentId)
                    }
                )
                .padding(.leading, 38)
            }
        }
        .padding(.vertical, 4)
    }
}

struct FloorRepliesInlineView: View {
    let thread: CommentsViewModel.FloorThread?
    let isLoading: Bool
    let errorMessage: String?
    let onLoadMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let thread {
                if !thread.comments.isEmpty {
                    ForEach(thread.comments) { comment in
                        CommentRowView(
                            comment: comment,
                            showsRepliesIndicator: false,
                            floorOwnerUserId: thread.ownerComment?.user.userId
                        )
                    }
                } else if !isLoading {
                    Text("暂无回复")
                        .foregroundColor(.secondary)
                }

                if thread.hasMore {
                    HStack {
                        Spacer()
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button("加载更多评论") {
                                onLoadMore()
                            }
                            .buttonStyle(.link)
                        }
                        Spacer()
                    }
                }
            } else if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
            }

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}
