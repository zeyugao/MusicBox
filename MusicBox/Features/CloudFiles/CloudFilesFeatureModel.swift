import Foundation
import Observation

@MainActor
@Observable
final class CloudFilesFeatureModel {
    private let repository: any CloudRepository
    private let pageSize = 100
    private var queryTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var moreTask: Task<Void, Never>?

    var files: [CloudMusicApi.CloudFile] = []
    var query = ""
    var isLoading = false
    var isLoadingMore = false
    var hasMore = true
    var errorMessage: String?

    init(repository: any CloudRepository) {
        self.repository = repository
    }

    var filteredFiles: [CloudMusicApi.CloudFile] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return files }
        return files.filter { file in
            file.fileName.lowercased().contains(query)
                || (file.simpleSong?.name?.lowercased().contains(query) ?? false)
        }
    }

    func updateQuery(_ query: String) {
        self.query = query
        queryTask?.cancel()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, hasMore else { return }
        queryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }
            while self.hasMore, !Task.isCancelled {
                self.loadMore()
                while self.isLoadingMore, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
    }

    func load(reset: Bool = false) {
        if reset {
            loadTask?.cancel()
            moreTask?.cancel()
            files = []
            hasMore = true
            isLoading = false
            isLoadingMore = false
        }
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        loadTask?.cancel()
        loadTask = Task { [weak self, repository] in
            let response = await repository.cloudFiles(limit: self?.pageSize ?? 100, offset: 0)
            guard let self, !Task.isCancelled else { return }
            self.files = response ?? []
            self.hasMore = (response?.count ?? 0) == self.pageSize
            self.isLoading = false
            if response == nil {
                self.errorMessage = String(localized: "cloud.load.failed")
            }
        }
    }

    func loadMore() {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        let offset = files.count
        moreTask = Task { [weak self, repository] in
            let response = await repository.cloudFiles(limit: self?.pageSize ?? 100, offset: offset)
            guard let self, !Task.isCancelled else { return }
            let newFiles = response ?? []
            let existing = Set(self.files.map(\.pcId))
            self.files.append(contentsOf: newFiles.filter { !existing.contains($0.pcId) })
            self.hasMore = newFiles.count == self.pageSize
            self.isLoadingMore = false
        }
    }

    func match(_ file: CloudMusicApi.CloudFile, to songID: UInt64, userID: UInt64) async throws {
        try await repository.matchCloudFile(
            userID: userID,
            songID: file.privateCloud.songId,
            adjustedSongID: songID
        )
        load(reset: true)
    }
}
