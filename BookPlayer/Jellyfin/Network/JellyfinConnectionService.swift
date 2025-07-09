//
//  JellyfinConnectionService.swift
//  BookPlayer
//
//  Created by Lysann Tranvouez on 2024-11-20.
//  Copyright © 2024 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Get
import JellyfinAPI

class JellyfinConnectionService: BPLogger, ObservableObject {
  private let keychainService: KeychainServiceProtocol

  @Published var connection: JellyfinConnectionData?
  var client: JellyfinClient?

  init(keychainService: KeychainServiceProtocol) {
    self.keychainService = keychainService

    self.reloadConnection()
  }

  /// Finds and creates the api-client for the specified server
  public func findServer(at absolutePath: String) async throws -> String {
    guard let client = createClient(serverUrlString: absolutePath) else {
      throw JellyfinError.noClient
    }

    let publicSystemInfo = try await client.send(Paths.getPublicSystemInfo)

    self.client = client

    return publicSystemInfo.value.serverName ?? ""
  }

  /// Sign into the server using the api-client initialized in ``findServer(at:)``
  public func signIn(
    username: String,
    password: String,
    serverName: String
  ) async throws {
    guard let client else {
      fatalError("Client not initialized when attempting to sign in")
    }

    let result = try await client.signIn(username: username, password: password)

    guard
      let accessToken = result.accessToken,
      let userID = result.user?.id
    else {
      throw JellyfinError.unexpectedResponse(code: nil).localizedDescription
    }

    let data = JellyfinConnectionData(
      url: client.configuration.url,
      serverName: serverName,
      userID: userID,
      userName: username,
      accessToken: accessToken
    )

    try keychainService.set(
      data,
      key: .jellyfinConnection
    )

    self.connection = data
    self.client = client
  }

  func deleteConnection() {
    if let client {
      Task {
        // we don't care if this throws
        try await client.signOut()
      }
    }

    do {
      try keychainService.remove(.jellyfinConnection)
    } catch {
      Self.logger.warning("failed to remove connection data from keychain: \(error)")
    }

    connection = nil
    client = nil
  }

  public func fetchTopLevelItems() async throws -> [JellyfinLibraryItem] {
    guard
      let connection
    else {
      throw JellyfinError.noClient
    }

    let parameters = Paths.GetUserViewsParameters(userID: connection.userID, presetViews: [.books])

    let response = try await send(Paths.getUserViews(parameters: parameters))

    try Task.checkCancellation()

    let userViews = response.value.items?.compactMap(JellyfinLibraryItem.init(apiItem:))

    return userViews ?? []
  }

  public func fetchItems(
    in folderID: String,
    startIndex: Int?,
    limit: Int?,
    sortBy: JellyfinLayout.SortBy
  ) async throws -> (items: [JellyfinLibraryItem], nextStartIndex: Int, maxCountItems: Int) {
    let orderBy: [JellyfinAPI.ItemSortBy]
    switch sortBy {
      case .name:
        orderBy = [.name]
      case .smart:
        orderBy = [.isFolder, .sortName]
    }

    let parameters = Paths.GetItemsParameters(
      startIndex: startIndex,
      limit: limit,
      isRecursive: false,
      sortOrder: [.ascending],
      parentID: folderID,
      fields: [.sortName],
      includeItemTypes: [.audioBook, .folder],
      sortBy: orderBy,
      imageTypeLimit: 1
    )

    let response = try await send(Paths.getItems(parameters: parameters))
    try Task.checkCancellation()

    let nextStartItemIndex =
      if let startIndex = response.value.startIndex, let numItems = response.value.items?.count {
        startIndex + numItems
      } else {
        -1
      }
    let maxNumItems = response.value.totalRecordCount ?? 0

    let items = (response.value.items ?? [])
      .filter { item in item.id != nil }
      .compactMap { item -> JellyfinLibraryItem? in
        return JellyfinLibraryItem(apiItem: item)
      }

    return (items, nextStartItemIndex, maxNumItems)
  }

  public func fetchItemDetails(for id: String) async throws -> JellyfinAudiobookDetailsData {
    let response = try await send(Paths.getItem(itemID: id))
    try Task.checkCancellation()

    let itemInfo = response.value
    let artist: String? = itemInfo.albumArtist
    let filePath: String? = itemInfo.mediaSources?.first?.path ?? itemInfo.path
    let fileSize: Int? = itemInfo.mediaSources?.first?.size
    let runtimeInSeconds: TimeInterval? =
      (itemInfo.runTimeTicks != nil) ? TimeInterval(itemInfo.runTimeTicks!) / 10000000.0 : nil

    return JellyfinAudiobookDetailsData(
      artist: artist,
      filePath: filePath,
      fileSize: fileSize,
      overview: itemInfo.overview,
      runtimeInSeconds: runtimeInSeconds
    )
  }

  public func fetchAudiobookDownloadURLs(for folderID: String) async throws -> [URL] {
    let parameters = Paths.GetItemsParameters(
      isRecursive: false,
      parentID: folderID,
      includeItemTypes: [.audioBook]
    )

    let response = try await send(Paths.getItems(parameters: parameters))
    try Task.checkCancellation()

    let audiobooks = (response.value.items ?? [])
      .filter { item in item.id != nil }
      .compactMap { item -> JellyfinLibraryItem? in
        return JellyfinLibraryItem(apiItem: item)
      }

    let downloadURLs = audiobooks.compactMap { audiobook in
      do {
        return try createItemDownloadUrl(audiobook)
      } catch {
        Self.logger.warning("Failed to create download URL for audiobook \(audiobook.id): \(error)")
        return nil
      }
    }

    return downloadURLs
  }

  private func send<T>(
    _ request: Request<T>
  ) async throws -> Response<T> where T: Decodable {
    guard let client else {
      throw JellyfinError.noClient
    }

    return try await client.send(request)
  }

  private func reloadConnection() {
    guard
      let storedConnection: JellyfinConnectionData = try? keychainService.get(.jellyfinConnection),
      isConnectionValid(storedConnection)
    else {
      Self.logger.warning("failed to load connection data from keychain")
      return
    }

    client = createClient(
      serverUrlString: storedConnection.url.absoluteString,
      accessToken: storedConnection.accessToken
    )
    connection = storedConnection
  }

  private func isConnectionValid(_ data: JellyfinConnectionData) -> Bool {
    return !data.userID.isEmpty && !data.accessToken.isEmpty
  }

  private func createClient(serverUrlString: String, accessToken: String? = nil) -> JellyfinClient? {
    let mainBundleInfo = Bundle.main.infoDictionary
    let clientName = mainBundleInfo?[kCFBundleNameKey as String] as? String
    let clientVersion = mainBundleInfo?[kCFBundleVersionKey as String] as? String
    let deviceID = UIDevice.current.identifierForVendor
    guard let url = URL(string: serverUrlString), let clientName, let clientVersion, let deviceID else {
      Self.logger.error(
        "cannot build Jellyfin API client. \(serverUrlString), \(clientName), \(clientVersion), \(String(reflecting: deviceID))"
      )
      return nil
    }
    let configuration = JellyfinClient.Configuration(
      url: url,
      client: clientName,
      deviceName: UIDevice.current.name,
      deviceID: "\(deviceID.uuidString)-\(clientName)",
      version: clientVersion
    )
    return JellyfinClient(configuration: configuration, accessToken: accessToken)
  }

  func createItemDownloadUrl(_ item: JellyfinLibraryItem) throws -> URL {
    guard let client else {
      throw JellyfinError.noClient
    }

    let request = Paths.getDownload(itemID: item.id)
    var components = try createUrlComponentsForApiRequest(request)

    var queryItems = components.queryItems ?? []
    queryItems.append(URLQueryItem(name: "api_key", value: client.accessToken))
    components.queryItems = queryItems

    guard let url = components.url else {
      throw JellyfinError.urlFromComponents(components)
    }

    return url
  }

  func createItemImageURL(_ item: JellyfinLibraryItem, size: CGSize?) throws -> URL {
    var parameters = Paths.GetItemImageParameters()

    if let size {
      parameters.fillWidth = Int(size.width)
      parameters.fillHeight = Int(size.height)
    }

    let request = Paths.getItemImage(itemID: item.id, imageType: "Primary", parameters: parameters)
    let components = try createUrlComponentsForApiRequest(request)

    guard let url = components.url else {
      throw JellyfinError.urlFromComponents(components)
    }

    return url
  }

  private func createUrlComponentsForApiRequest<Response>(
    _ request: Request<Response>
  ) throws -> URLComponents {
    guard let client else {
      throw JellyfinError.noClient
    }

    guard let requestUrl = request.url else {
      throw JellyfinError.urlMalformed(nil)
    }

    let requestAbsoluteUrl =
      requestUrl.scheme == nil
      ? client.configuration.url.appendingPathComponent(requestUrl.absoluteString)
      : requestUrl

    guard var components = URLComponents(url: requestAbsoluteUrl, resolvingAgainstBaseURL: false) else {
      throw JellyfinError.urlMalformed(requestUrl)
    }

    if let query = request.query, !query.isEmpty {
      components.queryItems = query.map(URLQueryItem.init)
    }

    return components
  }
}

// MARK: - Library
extension JellyfinConnectionService {
  public func buildLibraryHierarchy() async throws -> SimpleLibraryItem.Node? {
    guard let serverName = connection?.serverName else { return nil }

    let items = try await fetchLibrary()
    Self.logger.info("Fetched \(items.count) audiobook items from Jellyfin")
    
    let artistHierarchy = buildArtistAlbumHierarchy(from: items, serverName: serverName)
    Self.logger.info("Built Artist->Album hierarchy with \(artistHierarchy.count) artists")
    
    let totalDuration = items.reduce(0.0) { sum, book in
      guard let time = book.runTimeTicks else { return sum }
      return sum + TimeInterval(time) / 10_000_000.0
    }
    
    let rootItem = SimpleLibraryItem(
      title: "Jellyfin (\(serverName))",
      details: "\(artistHierarchy.count) artists",
      speed: 1.0,
      currentTime: 0.0,
      duration: totalDuration,
      percentCompleted: 0.0,
      isFinished: false,
      relativePath: "Jellyfin (\(serverName))".replacingOccurrences(of: "/", with: "_"),
      remoteURL: nil,
      artworkURL: nil,
      orderRank: 0,
      parentFolder: nil,
      originalFileName: "Jellyfin (\(serverName))".replacingOccurrences(of: "/", with: "_"),
      lastPlayDate: nil,
      type: .folder,
      source: .jellyfin
    )

    return SimpleLibraryItem.Node(item: rootItem, children: artistHierarchy)
  }

  private func fetchLibrary() async throws -> [BaseItemDto] {
    let parameters = Paths.GetItemsParameters(
      isRecursive: true,
      sortOrder: [.descending, .ascending],
      fields: [.parentID, .path],
      includeItemTypes: [.audioBook],
      sortBy: [.albumArtist, .album],
      enableUserData: false,
      imageTypeLimit: 1
    )

    let response = try await send(Paths.getItems(parameters: parameters))
    try Task.checkCancellation()

    return response.value.items ?? []
  }

  private func buildArtistAlbumHierarchy(from items: [BaseItemDto], serverName: String) -> [SimpleLibraryItem.Node] {
    let audiobooks = parseAudiobookItems(from: items)
    let groupedByArtist = Dictionary(grouping: audiobooks, by: \.artist)

    let sortedArtists = groupedByArtist.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })

    var artistNodes: [SimpleLibraryItem.Node] = []
    for (index, artistName) in sortedArtists.enumerated() {
      guard let audiobooks = groupedByArtist[artistName] else { continue }
      let artistNode = buildArtistNode(
        artistName: artistName,
        rank: index,
        audiobooks: audiobooks,
        serverName: "Jellyfin (\(serverName))"
      )
      artistNodes.append(artistNode)
    }

    return artistNodes
  }
  
  private func parseAudiobookItems(from items: [BaseItemDto]) -> [AudiobookItem] {
    return items.compactMap { item -> AudiobookItem? in
      guard
        let id = item.id,
        let name = item.name,
        let artist = item.albumArtist,
        let album = item.album,
        let fileName = item.path.map(URL.init(fileURLWithPath:))?.lastPathComponent,
        let duration = item.runTimeTicks.map({ TimeInterval($0) / 10_000_000.0 })
      else {
        Self.logger.warning(
          """
          Skipping item with missing required fields:
            id=\(item.id ?? "nil"),
            name=\(item.name ?? "nil"),
            albumArtist=\(item.albumArtist ?? "nil"),
            album=\(item.album ?? "nil"),
            path=\(item.path ?? "nil")
          """
        )
        return nil
      }

      return AudiobookItem(
        id: id,
        name: name,
        artist: artist,
        album: album,
        fileName: fileName,
        duration: duration
      )
    }
  }
  
  private func buildArtistNode(
    artistName: String,
    rank: Int,
    audiobooks: [AudiobookItem],
    serverName: String
  ) -> SimpleLibraryItem.Node {
    let groupedByAlbum = Dictionary(grouping: audiobooks, by: \.album)
    let bookNodes = buildBookNodes(
      groupedByAlbum: groupedByAlbum,
      artistName: artistName,
      serverName: serverName
    )
    
    let totalArtistDuration = audiobooks.reduce(0.0) { $0 + $1.duration }
    let artistPath = URL(fileURLWithPath: serverName).appendingPathComponent(artistName).path

    let artistItem = SimpleLibraryItem(
      title: artistName,
      details: "\(bookNodes.count) books",
      speed: 1.0,
      currentTime: 0.0,
      duration: totalArtistDuration,
      percentCompleted: 0.0,
      isFinished: false,
      relativePath: artistPath,
      remoteURL: nil,
      artworkURL: nil,
      orderRank: Int16(rank),
      parentFolder: serverName,
      originalFileName: artistName,
      lastPlayDate: nil,
      type: .folder,
      source: .jellyfin
    )
    
    return SimpleLibraryItem.Node(item: artistItem, children: bookNodes)
  }
  
  private func buildBookNodes(
    groupedByAlbum: [String: [AudiobookItem]],
    artistName: String,
    serverName: String
  ) -> [SimpleLibraryItem.Node] {
    var bookNodes: [SimpleLibraryItem.Node] = []

    for (bookName, audiobooks) in groupedByAlbum {
      let parentURL = URL(fileURLWithPath: serverName).appendingPathComponent(artistName)

      let bookNode: SimpleLibraryItem.Node

      if audiobooks.count == 1 {
        bookNode = buildSingleBookNode(audiobook: audiobooks[0], parentURL: parentURL)
      } else {
        bookNode = buildMultiPartBookNode(
          bookName: bookName,
          audiobooks: audiobooks,
          parentURL: parentURL
        )
      }
      
      bookNodes.append(bookNode)
    }
    
    return bookNodes
  }
  
  private func buildSingleBookNode(audiobook: AudiobookItem, parentURL: URL) -> SimpleLibraryItem.Node {
    let bookItem = SimpleLibraryItem(
      title: audiobook.name,
      details: audiobook.artist,
      speed: 1.0,
      currentTime: 0.0,
      duration: audiobook.duration,
      percentCompleted: 0.0,
      isFinished: false,
      relativePath: parentURL.appendingPathComponent(audiobook.fileName).path,
      remoteURL: try? getItemStreamingURL(itemID: audiobook.id),
      artworkURL: nil,
      orderRank: 0,
      parentFolder: parentURL.path,
      originalFileName: audiobook.fileName,
      lastPlayDate: nil,
      type: .book,
      source: .jellyfin
    )
    
    return SimpleLibraryItem.Node(item: bookItem)
  }
  
  private func buildMultiPartBookNode(bookName: String, audiobooks: [AudiobookItem], parentURL: URL) -> SimpleLibraryItem.Node {
    let totalDuration = audiobooks.reduce(0.0) { $0 + $1.duration }

    let bookURL = parentURL.appendingPathComponent(bookName)

    let chapterNodes = buildChapterNodes(audiobooks: audiobooks, bookURL: bookURL)

    let bookItem = SimpleLibraryItem(
      title: bookName,
      details: chapterNodes.first?.item.details ?? "",
      speed: 1.0,
      currentTime: 0.0,
      duration: totalDuration,
      percentCompleted: 0.0,
      isFinished: false,
      relativePath: bookURL.path,
      remoteURL: nil,
      artworkURL: chapterNodes.first?.item.artworkURL,
      orderRank: 0,
      parentFolder: parentURL.path,
      originalFileName: bookName,
      lastPlayDate: nil,
      type: .bound,
      source: .jellyfin
    )
    
    return SimpleLibraryItem.Node(item: bookItem, children: chapterNodes)
  }
  
  private func buildChapterNodes(audiobooks: [AudiobookItem], bookURL: URL) -> [SimpleLibraryItem.Node] {
    let sorted = audiobooks.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    var chapterNodes: [SimpleLibraryItem.Node] = []
    var chapterOrderRank: Int16 = 0

    for book in sorted {
      let chapterURL = bookURL.appendingPathComponent(book.fileName)

      let chapterItem = SimpleLibraryItem(
        title: chapterURL.deletingPathExtension().lastPathComponent,
        details: book.artist,
        speed: 1.0,
        currentTime: 0.0,
        duration: book.duration,
        percentCompleted: 0.0,
        isFinished: false,
        relativePath: chapterURL.path,
        remoteURL: try? getItemStreamingURL(itemID: book.id),
        artworkURL: try? getItemArtworkURL(itemID: book.id),
        orderRank: chapterOrderRank,
        parentFolder: bookURL.path,
        originalFileName: book.fileName,
        lastPlayDate: nil,
        type: .book,
        source: .jellyfin
      )
      
      let chapter = SimpleLibraryItem.Node(item: chapterItem)
      chapterNodes.append(chapter)
      chapterOrderRank += 1
    }
    
    return chapterNodes
  }

  private func getItemStreamingURL(itemID: String) throws -> URL? {
    guard let apiKey = connection?.accessToken else { return nil }

    let parameters = Paths.GetAudioStreamParameters(isStatic: true)
    let request = Paths.getAudioStream(itemID: itemID, parameters: parameters)

    let components = try createUrlComponentsForApiRequest(request)

    guard let streamingURL = components.url else {
      throw JellyfinError.urlFromComponents(components)
    }

    return streamingURL.appending(queryItems: [URLQueryItem(name: "api_key", value: apiKey)])
  }

  private func getItemArtworkURL(itemID: String) throws -> URL? {
    guard let apiKey = connection?.accessToken else { return nil }

    let request = Paths.getItemImage(itemID: itemID, imageType: "Primary")

    let components = try createUrlComponentsForApiRequest(request)

    guard let artworkURL = components.url else {
      throw JellyfinError.urlFromComponents(components)
    }

    return artworkURL.appending(queryItems: [URLQueryItem(name: "api_key", value: apiKey)])
  }
}

extension JellyfinConnectionService {
  struct AudiobookItem {
    let id: String
    let name: String
    let artist: String
    let album: String
    let fileName: String
    let duration: TimeInterval
  }
}

