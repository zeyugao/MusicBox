//
//  CloudFiles.swift
//  MusicBox
//
//  Created by Elsa on 2024/5/6.
//

import Foundation
import SwiftUI

struct CloudFilesView: View {
    @State private var cloudFiles: [CloudMusicApi.CloudFile] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var hasMoreFiles = true
    private let pageSize = 30

    var body: some View {
        Group {
            if isLoading {
                VStack {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading cloud files...")
                        .foregroundColor(.secondary)
                        .padding(.top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if cloudFiles.isEmpty {
                VStack {
                    Image(systemName: "icloud.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No cloud files found")
                        .foregroundColor(.secondary)
                        .padding(.top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(cloudFiles) { file in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(file.fileName)
                                        .font(.body)
                                        .lineLimit(1)

                                    Spacer()

                                    Text(file.parseFileSize())
                                        .font(.caption)
                                        .foregroundColor(.secondary)

                                    Image(
                                        systemName: file.isMatched
                                            ? "checkmark.circle.fill" : "xmark.circle.fill"
                                    )
                                    .foregroundColor(file.isMatched ? .green : .red)
                                    .font(.caption)
                                }

                                if let simpleSong = file.simpleSong,
                                    let artistName = simpleSong.ar.first?.name,
                                    let albumName = simpleSong.al.name
                                {
                                    Text("\(artistName) - \(albumName)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .onAppear {
                            if file.id == cloudFiles.last?.id && hasMoreFiles && !isLoadingMore {
                                Task {
                                    await loadMoreFiles()
                                }
                            }
                        }
                    }

                    if isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Loading more...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding()
                    }
                }
                .listStyle(PlainListStyle())
                .refreshable {
                    await loadCloudFiles(reset: true)
                }
            }
        }
        .task {
            await loadCloudFiles()
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
