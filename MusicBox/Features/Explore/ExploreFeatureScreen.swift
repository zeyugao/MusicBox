import SwiftUI

private enum ExploreRoute: Hashable {
    case playlist(PlaylistDestination)
    case searchResult(UUID)
}

struct ExploreFeatureScreen: View {
    @Environment(AppModel.self) private var app
    @State private var model: ExploreFeatureModel
    @State private var navigationPath = NavigationPath()
    @State private var searchResults: [UUID: [CloudMusicApi.Song]] = [:]

    init(repository: any MusicRepository) {
        _model = State(initialValue: ExploreFeatureModel(repository: repository))
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))]) {
                        ForEach(model.recommendations) { recommendation in
                            RecommendationTile(recommendation: recommendation)
                                .padding()
                                .onTapGesture {
                                    navigationPath.append(
                                        ExploreRoute.playlist(
                                            PlaylistDestination(
                                                id: recommendation.id,
                                                name: recommendation.name
                                            )
                                        )
                                    )
                                }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .contentMargins(.bottom, PlayerOverlayMetrics.contentClearance, for: .scrollContent)
                .searchable(
                    text: Binding(
                        get: { model.query },
                        set: { model.updateQuery($0) }
                    ),
                    suggestions: {
                        ForEach(model.suggestions, id: \.id) { suggestion in
                            let albumName = suggestion.album.name.isEmpty
                                ? "Unknown Album"
                                : suggestion.album.name
                            let displayName = suggestion.name + " - " + albumName
                            let completion = "##%%ID" + String(suggestion.id)
                            Text(displayName)
                            .lineLimit(1)
                            .searchCompletion(completion)
                        }
                    }
                )
                .onSubmit(of: .search) {
                    model.submitSearch()
                }

                if model.isSearching {
                    ProgressView()
                        .controlSize(.regular)
                }
            }
            .navigationDestination(for: ExploreRoute.self) { route in
                switch route {
                case .playlist(let destination):
                    PlaylistFeatureScreen(destination: destination, repository: app.repository)
                        .navigationTitle(destination.name)
                case .searchResult(let id):
                    PlaylistFeatureScreen(
                        destination: PlaylistDestination(id: 0, name: "搜索结果"),
                        repository: app.repository,
                        initialSongs: searchResults[id] ?? []
                    )
                        .navigationTitle("搜索结果")
                }
            }
        }
        .task {
            model.loadRecommendations()
        }
        .onChange(of: model.results) { _, songs in
            guard !songs.isEmpty else { return }
            let id = UUID()
            searchResults[id] = songs
            navigationPath.append(ExploreRoute.searchResult(id))
        }
    }
}

private struct RecommendationTile: View {
    let recommendation: CloudMusicApi.RecommandPlaylistItem

    var body: some View {
        VStack(alignment: .center) {
            if recommendation.picUrl.starts(with: "http") {
                AsyncImage(url: URL(string: recommendation.picUrl.https)) { image in
                    image
                        .resizable()
                        .interpolation(.high)
                } placeholder: {
                    Color.white
                }
                .frame(width: 100, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .frame(width: 100, height: 100)
            } else {
                Image(systemName: recommendation.picUrl)
                    .resizable()
                    .frame(width: 50, height: 50)
                    .frame(width: 100, height: 100)
            }
            Text(recommendation.name)
        }
        .frame(width: 100, height: 150, alignment: .top)
    }
}
