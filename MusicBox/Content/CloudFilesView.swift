//
//  CloudFiles.swift
//  MusicBox
//
//  Created by Elsa on 2024/5/6.
//

import Cocoa
import Foundation
import SwiftUI

struct CloudFilesView: View {
    @EnvironmentObject var userInfo: UserInfo
    @State private var cloudFiles: [CloudMusicApi.CloudFile] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var hasMoreFiles = true
    @State private var selectedFileForMatch: CloudMusicApi.CloudFile?
    private let pageSize = 100

    var body: some View {
        Group {

            VStack {
                CloudFileTableView(
                    cloudFiles: cloudFiles,
                    isLoadingMore: isLoadingMore,
                    hasMoreFiles: hasMoreFiles,
                    pageSize: pageSize,
                    onLoadMore: {
                        if hasMoreFiles && !isLoadingMore {
                            Task {
                                await loadMoreFiles()
                            }
                        }
                    },
                    onMatchWith: { file in
                        selectedFileForMatch = file
                    }
                )

                if isLoading {
                    LoadingIndicatorView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task {
            await loadCloudFiles()
        }
        .sheet(item: $selectedFileForMatch) { file in
            MatchWithModalView(cloudFile: file, userInfo: userInfo) {
                Task {
                    await loadCloudFiles(reset: true)
                }
            }
        }
    }

    private func loadCloudFiles(reset: Bool = false) async {
        if reset {
            DispatchQueue.main.async {
                self.cloudFiles = []
                self.hasMoreFiles = true
            }
        }

        isLoading = true
        if let files = await CloudMusicApi().user_cloud(limit: pageSize, offset: 0) {
            DispatchQueue.main.async {
                self.cloudFiles = files
                self.hasMoreFiles = files.count == self.pageSize
                self.isLoading = false
            }
        } else {
            DispatchQueue.main.async {
                self.cloudFiles = []
                self.hasMoreFiles = false
                self.isLoading = false
            }
        }
    }

    private func loadMoreFiles() async {
        guard !isLoadingMore && hasMoreFiles else { return }

        isLoadingMore = true
        let offset = cloudFiles.count

        if let newFiles = await CloudMusicApi().user_cloud(limit: pageSize, offset: offset) {
            DispatchQueue.main.async {
                self.cloudFiles.append(contentsOf: newFiles)
                self.hasMoreFiles = newFiles.count == self.pageSize
                self.isLoadingMore = false
            }
        } else {
            DispatchQueue.main.async {
                self.hasMoreFiles = false
                self.isLoadingMore = false
            }
        }
    }
}

// MARK: - Custom NSTableCellView Classes

class CloudFileNameTableCellView: NSTableCellView {
    private let nameLabel = NSTextField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        nameLabel.isEditable = false
        nameLabel.isBordered = false
        nameLabel.drawsBackground = false
        nameLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        nameLabel.lineBreakMode = .byTruncatingTail

        addSubview(nameLabel)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(with cloudFile: CloudMusicApi.CloudFile) {
        nameLabel.stringValue = cloudFile.fileName
    }
}

class CloudFileStatusTableCellView: NSTableCellView {
    private let statusIcon = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        statusIcon.imageScaling = .scaleProportionallyUpOrDown

        addSubview(statusIcon)
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusIcon.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusIcon.widthAnchor.constraint(equalToConstant: 16),
            statusIcon.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    func configure(with cloudFile: CloudMusicApi.CloudFile) {
        let iconName = cloudFile.isMatched ? "checkmark.circle.fill" : "xmark.circle.fill"
        let iconColor = cloudFile.isMatched ? NSColor.systemGreen : NSColor.systemRed

        if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
            statusIcon.image = image
            statusIcon.contentTintColor = iconColor
        }
    }
}

class CloudFileInfoTableCellView: NSTableCellView {
    private let infoLabel = NSTextField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        infoLabel.isEditable = false
        infoLabel.isBordered = false
        infoLabel.drawsBackground = false
        infoLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        infoLabel.textColor = NSColor.labelColor
        infoLabel.lineBreakMode = .byTruncatingTail

        addSubview(infoLabel)
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            infoLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            infoLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            infoLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(with cloudFile: CloudMusicApi.CloudFile) {
        if let simpleSong = cloudFile.simpleSong,
            let artistName = simpleSong.ar.first?.name,
            let albumName = simpleSong.al.name,
            let name = simpleSong.name
        {
            infoLabel.stringValue = "\(name) - \(artistName) - \(albumName)"
        } else {
            infoLabel.stringValue = ""
        }
    }
}

class CloudFileSizeTableCellView: NSTableCellView {
    private let sizeLabel = NSTextField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        sizeLabel.isEditable = false
        sizeLabel.isBordered = false
        sizeLabel.drawsBackground = false
        sizeLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        sizeLabel.textColor = NSColor.secondaryLabelColor
        sizeLabel.alignment = .right

        addSubview(sizeLabel)
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sizeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            sizeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            sizeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(with cloudFile: CloudMusicApi.CloudFile) {
        sizeLabel.stringValue = cloudFile.parseFileSize()
    }
}

// MARK: - CloudFile Table View Controller

class CloudFileTableViewController: NSViewController {
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    var cloudFiles: [CloudMusicApi.CloudFile] = [] {
        didSet {
            tableView.reloadData()
        }
    }

    var isLoadingMore: Bool = false
    var hasMoreFiles: Bool = true
    var pageSize: Int = 100
    var onLoadMore: (() -> Void)?
    var onMatchWith: ((CloudMusicApi.CloudFile) -> Void)?

    override func loadView() {
        view = NSView()
        setupTableView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupColumns()
    }

    private func setupTableView() {
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        // Add scroll notification observer for infinite scrolling
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )

        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsColumnSelection = false
        tableView.allowsMultipleSelection = false
        tableView.allowsColumnReordering = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowSizeStyle = .default
        tableView.target = self

        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupColumns() {
        // Status column
        let statusColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        statusColumn.title = ""
        statusColumn.width = 24
        statusColumn.minWidth = 24
        statusColumn.maxWidth = 24
        statusColumn.resizingMask = []
        tableView.addTableColumn(statusColumn)

        // File Name column
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("fileName"))
        nameColumn.title = "File Name"
        nameColumn.width = 300
        nameColumn.minWidth = 150
        tableView.addTableColumn(nameColumn)

        // Matched Song Info column
        let infoColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("matchedInfo"))
        infoColumn.title = "Matched Song"
        infoColumn.width = 300
        infoColumn.minWidth = 150
        tableView.addTableColumn(infoColumn)

        // File Size column
        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("fileSize"))
        sizeColumn.title = "Size"
        sizeColumn.width = 80
        sizeColumn.minWidth = 60
        sizeColumn.maxWidth = 100
        tableView.addTableColumn(sizeColumn)
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        guard let scrollView = notification.object as? NSScrollView else { return }

        let visibleRect = scrollView.documentVisibleRect
        let documentRect = scrollView.documentView?.bounds ?? .zero
        
        // Calculate remaining rows to trigger loading more aggressively
        let rowHeight: CGFloat = 24 // As defined in heightOfRow
        let totalRows = cloudFiles.count
        let visibleRowsFromTop = Int(visibleRect.minY / rowHeight)
        let visibleRowsCount = Int(visibleRect.height / rowHeight)
        let lastVisibleRow = visibleRowsFromTop + visibleRowsCount
        
        // Trigger loading when we have pageSize/3 or fewer items remaining
        let remainingRows = totalRows - lastVisibleRow
        let loadThreshold = pageSize / 3 // About 33 items with pageSize = 100
        let shouldLoadMore = remainingRows <= loadThreshold

        if shouldLoadMore && hasMoreFiles && !isLoadingMore {
            onLoadMore?()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - NSTableViewDataSource

extension CloudFileTableViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return cloudFiles.count
    }
}

// MARK: - NSTableViewDelegate

extension CloudFileTableViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard row < cloudFiles.count else { return nil }
        let cloudFile = cloudFiles[row]

        guard let identifier = tableColumn?.identifier else { return nil }

        switch identifier.rawValue {
        case "status":
            let cellView = CloudFileStatusTableCellView()
            cellView.configure(with: cloudFile)
            return cellView

        case "fileName":
            let cellView = CloudFileNameTableCellView()
            cellView.configure(with: cloudFile)
            return cellView

        case "matchedInfo":
            let cellView = CloudFileInfoTableCellView()
            cellView.configure(with: cloudFile)
            return cellView

        case "fileSize":
            let cellView = CloudFileSizeTableCellView()
            cellView.configure(with: cloudFile)
            return cellView

        default:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 24
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        return true
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = tableView.convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: point)

        guard row >= 0, row < cloudFiles.count else { return }

        // Select the row if it's not already selected
        if !tableView.selectedRowIndexes.contains(row) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        let cloudFile = cloudFiles[row]
        let menu = createContextMenu(for: cloudFile, row: row)

        NSMenu.popUpContextMenu(menu, with: event, for: tableView)
    }

    private func createContextMenu(for cloudFile: CloudMusicApi.CloudFile, row: Int) -> NSMenu {
        let menu = NSMenu()
        let matchWithItem = NSMenuItem(
            title: "Match with",
            action: #selector(matchWithAction(_:)),
            keyEquivalent: ""
        )
        matchWithItem.target = self
        matchWithItem.tag = row
        menu.addItem(matchWithItem)

        return menu
    }
}

// MARK: - Context Menu Actions

extension CloudFileTableViewController {
    @objc private func matchWithAction(_ sender: NSMenuItem) {
        let row = sender.tag
        guard row >= 0 && row < cloudFiles.count else { return }
        onMatchWith?(cloudFiles[row])
    }
}

// MARK: - SwiftUI Wrapper

struct CloudFileTableView: NSViewControllerRepresentable {
    let cloudFiles: [CloudMusicApi.CloudFile]
    let isLoadingMore: Bool
    let hasMoreFiles: Bool
    let pageSize: Int
    let onLoadMore: () -> Void
    let onMatchWith: (CloudMusicApi.CloudFile) -> Void

    func makeNSViewController(context: Context) -> CloudFileTableViewController {
        let controller = CloudFileTableViewController()
        controller.onLoadMore = onLoadMore
        controller.onMatchWith = onMatchWith
        controller.pageSize = pageSize
        return controller
    }

    func updateNSViewController(_ nsViewController: CloudFileTableViewController, context: Context)
    {
        nsViewController.cloudFiles = cloudFiles
        nsViewController.isLoadingMore = isLoadingMore
        nsViewController.hasMoreFiles = hasMoreFiles
        nsViewController.pageSize = pageSize
    }
}

struct MatchWithModalView: View {
    let cloudFile: CloudMusicApi.CloudFile
    let userInfo: UserInfo
    let onMatchSuccess: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPlaylist: CloudMusicApi.PlayListItem?
    @State private var playlistSongs: [CloudMusicApi.Song] = []
    @State private var isLoadingPlaylist = false
    @State private var selectedSongForMatch: CloudMusicApi.Song?

    var body: some View {
        NavigationSplitView {
            // Left sidebar - Playlist selection
            if userInfo.playlists.isEmpty {
                VStack {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No playlists found")
                        .foregroundColor(.secondary)
                        .padding(.top)
                    Text("Create some playlists first")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Select Playlist")
            } else {
                List(userInfo.playlists, id: \.id, selection: $selectedPlaylist) { playlist in
                    PlaylistRowView(playlist: playlist)
                        .tag(playlist)
                }
                .listStyle(SidebarListStyle())
                .navigationTitle("Select Playlist")
                .onChange(of: selectedPlaylist) { _, newPlaylist in
                    if let playlist = newPlaylist {
                        Task {
                            await loadPlaylistSongs(playlist: playlist)
                        }
                    }
                }
            }
        } detail: {
            // Right detail view - Playlist songs
            if let selectedPlaylist = selectedPlaylist {
                if isLoadingPlaylist {
                    VStack {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Loading songs...")
                            .foregroundColor(.secondary)
                            .padding(.top)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(selectedPlaylist.name)
                } else {
                    List(playlistSongs, id: \.id) { song in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(song.name)
                                    .font(.body)
                                    .lineLimit(1)
                                Text(song.ar.map { $0.name }.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            let duration = song.parseDuration()
                            Text(String(format: "%02d:%02d", duration.minute, duration.second))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }.contentShape(Rectangle())
                            .padding(.vertical, 2)
                            .padding(.horizontal, 8)
                            .background(
                                selectedSongForMatch?.id == song.id
                                    ? Color.blue.opacity(0.2) : Color.clear
                            )
                            .cornerRadius(8)
                            .onTapGesture {
                                selectedSongForMatch = song
                            }
                    }
                    .listStyle(PlainListStyle())
                    .navigationTitle(selectedPlaylist.name)
                }
            } else {
                VStack {
                    Image(systemName: "music.note")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Select a playlist")
                        .foregroundColor(.secondary)
                        .padding(.top)
                    Text("Choose a playlist from the sidebar to see its songs")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Songs")
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Confirm") {
                    if let selectedSong = selectedSongForMatch {
                        Task {
                            await matchCloudFile(targetSong: selectedSong)
                        }
                    }
                }
                .disabled(selectedSongForMatch == nil)
            }
        }
    }

    private func loadPlaylistSongs(playlist: CloudMusicApi.PlayListItem) async {
        isLoadingPlaylist = true

        if let result = await CloudMusicApi().playlist_detail(id: playlist.id) {
            DispatchQueue.main.async {
                self.playlistSongs = result.tracks
                self.isLoadingPlaylist = false
            }
        } else {
            DispatchQueue.main.async {
                self.playlistSongs = []
                self.isLoadingPlaylist = false
            }
        }
    }

    private func matchCloudFile(targetSong: CloudMusicApi.Song) async {
        guard let userId = userInfo.profile?.userId else { return }

        do {
            try await CloudMusicApi().cloud_match(
                userId: UInt64(userId),
                songId: cloudFile.privateCloud.songId,
                adjustSongId: targetSong.id
            )

            DispatchQueue.main.async {
                onMatchSuccess()
                dismiss()
            }

        } catch let error as RequestError {
            DispatchQueue.main.async {
                dismiss()
                AlertModal.showAlert(error.localizedDescription)
            }
        } catch {
            DispatchQueue.main.async {
                dismiss()
                AlertModal.showAlert(error.localizedDescription)
            }
        }
    }
}
