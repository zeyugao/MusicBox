import Foundation
import Observation

enum CommentsTargetKind: String, Codable, Hashable {
    case playlist
    case song
}

struct CommentsTarget: Hashable, Codable, Identifiable {
    let kind: CommentsTargetKind
    let resourceID: UInt64
    let name: String
    let subtitle: String?

    var id: String { "\(kind.rawValue)-\(resourceID)" }
    var resourceType: CloudMusicApi.CommentResourceType { kind == .playlist ? .playlist : .music }
    var title: String { subtitle.map { "\(name) - \($0)" } ?? name }
    var windowTitle: String {
        guard let subtitle, !subtitle.isEmpty else { return "评论 · \(name)" }
        return "评论 · \(name) · \(subtitle)"
    }
}

enum CommentsSort: CaseIterable, Identifiable, Equatable {
    case hot
    case recommend
    case time

    var id: Self { self }

    var apiValue: CloudMusicApi.CommentNewSortType {
        switch self {
        case .hot: return .hot
        case .recommend: return .recommend
        case .time: return .time
        }
    }
}

struct CommentFloorThread: Equatable {
    let parentCommentID: UInt64
    var ownerComment: CloudMusicApi.Comment?
    var comments: [CloudMusicApi.Comment]
    var seenCommentIDs: Set<UInt64>
    var hasMore: Bool
    var nextTime: Int64?
    var totalCount: Int
}

@MainActor
@Observable
final class CommentsFeatureModel {
    let target: CommentsTarget
    private let repository: any CommentsRepository
    private var loadTask: Task<Void, Never>?
    private let pageSize = 30
    private var page = 0
    private var cursor: Int64?
    private var seenCommentIDs: Set<UInt64> = []
    private var floorTasks: [UInt64: Task<Void, Never>] = [:]

    var comments: [CloudMusicApi.Comment] = []
    var sort = CommentsSort.hot
    var hasMore = false
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?
    var floorThreads: [UInt64: CommentFloorThread] = [:]
    var floorLoadingIDs: Set<UInt64> = []
    var floorErrorMessages: [UInt64: String] = [:]

    init(target: CommentsTarget, repository: any CommentsRepository) {
        self.target = target
        self.repository = repository
    }

    func load(reset: Bool = true) {
        if reset {
            loadTask?.cancel()
            isLoading = false
            isLoadingMore = false
            page = 0
            cursor = nil
            comments = []
            seenCommentIDs = []
            floorTasks.values.forEach { $0.cancel() }
            floorTasks = [:]
            floorThreads = [:]
            floorLoadingIDs = []
            floorErrorMessages = [:]
        }
        guard !isLoading && !isLoadingMore else { return }
        isLoading = true
        errorMessage = nil
        fetch(nextPage: 1, cursor: nil, replacing: true)
    }

    func changeSort(_ sort: CommentsSort) {
        guard self.sort != sort else { return }
        self.sort = sort
        load()
    }

    func loadMore() {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        fetch(nextPage: page + 1, cursor: sort == .time ? cursor : nil, replacing: false)
    }

    private func fetch(nextPage: Int, cursor: Int64?, replacing: Bool) {
        loadTask?.cancel()
        let target = target
        let sort = sort
        loadTask = Task { [weak self, repository] in
            do {
                let response = try await repository.comments(
                    type: target.resourceType,
                    id: target.resourceID,
                    page: nextPage,
                    pageSize: self?.pageSize ?? 30,
                    sort: sort.apiValue,
                    cursor: cursor
                )
                guard let self, !Task.isCancelled, self.sort == sort else { return }
                let newComments = (response.comments ?? []).filter {
                    self.seenCommentIDs.insert($0.commentId).inserted
                }
                if replacing {
                    self.comments = newComments
                } else {
                    self.comments.append(contentsOf: newComments)
                }
                self.page = nextPage
                self.hasMore = response.hasMore ?? false
                if case let .int(value)? = response.cursor {
                    self.cursor = Int64(value)
                } else if case let .string(value)? = response.cursor {
                    self.cursor = Int64(value)
                }
                self.isLoading = false
                self.isLoadingMore = false
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.isLoading = false
                self.isLoadingMore = false
            }
        }
    }

    func loadFloor(parentCommentID: UInt64) {
        guard floorThreads[parentCommentID] == nil,
              !floorLoadingIDs.contains(parentCommentID)
        else { return }
        fetchFloor(parentCommentID: parentCommentID, time: nil, appending: false)
    }

    func loadMoreFloor(parentCommentID: UInt64) {
        guard let thread = floorThreads[parentCommentID],
              thread.hasMore,
              !floorLoadingIDs.contains(parentCommentID)
        else { return }
        fetchFloor(parentCommentID: parentCommentID, time: thread.nextTime, appending: true)
    }

    func cancelFloor(parentCommentID: UInt64) {
        floorTasks[parentCommentID]?.cancel()
        floorTasks[parentCommentID] = nil
        floorLoadingIDs.remove(parentCommentID)
    }

    private func fetchFloor(parentCommentID: UInt64, time: Int64?, appending: Bool) {
        floorTasks[parentCommentID]?.cancel()
        floorLoadingIDs.insert(parentCommentID)
        floorErrorMessages[parentCommentID] = nil
        let target = target
        floorTasks[parentCommentID] = Task { [weak self, repository] in
            do {
                let page = try await repository.commentFloor(
                    parentCommentID: parentCommentID,
                    resourceID: target.resourceID,
                    type: target.resourceType,
                    limit: 10,
                    time: time
                )
                guard let self, !Task.isCancelled else { return }
                let candidates = (page.bestComments ?? []) + (page.comments ?? [])
                var thread = self.floorThreads[parentCommentID] ?? CommentFloorThread(
                    parentCommentID: parentCommentID,
                    ownerComment: page.ownerComment,
                    comments: [],
                    seenCommentIDs: [],
                    hasMore: false,
                    nextTime: nil,
                    totalCount: 0
                )
                if !appending {
                    thread.comments = []
                    thread.seenCommentIDs = []
                }
                for comment in candidates where thread.seenCommentIDs.insert(comment.commentId).inserted {
                    thread.comments.append(comment)
                }
                thread.ownerComment = page.ownerComment ?? thread.ownerComment
                thread.hasMore = page.hasMore ?? false
                thread.nextTime = page.time
                thread.totalCount = page.totalCount ?? thread.totalCount
                self.floorThreads[parentCommentID] = thread
                self.floorLoadingIDs.remove(parentCommentID)
                self.floorTasks[parentCommentID] = nil
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.floorErrorMessages[parentCommentID] = error.localizedDescription
                self.floorLoadingIDs.remove(parentCommentID)
                self.floorTasks[parentCommentID] = nil
            }
        }
    }
}
