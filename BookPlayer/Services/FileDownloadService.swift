//
//  FileDownloadService.swift
//  BookPlayer
//
//  Created by Jeremy Grenier on 7/8/25.
//  Copyright © 2025 BookPlayer LLC. All rights reserved.
//

import Foundation
import Combine
import BookPlayerKit

public class FileDownloadService: NSObject, BPLogger {
  public enum Event {
    case starting
    case progress(Double)
    case finished
    case error(Error)
  }
  public let eventPublisher = PassthroughSubject<(String, Event), Never>()

  private var activeDownloadTasks: [String: Task<Void, Never>] = [:]
  private var multiFileProgress: [String: (currentIndex: Int, totalFiles: Int, fileProgress: Double)] = [:]
  private var taskToItemMapping: [Int: String] = [:]
  private var taskToParentItemMapping: [Int: String?] = [:]
  private let libraryService: LibraryServiceProtocol
  private lazy var downloadSession: URLSession = URLSession(
    configuration: URLSessionConfiguration.background(withIdentifier: "FileDownloadService"),
    delegate: self,
    delegateQueue: nil
  )

  public init(libraryService: LibraryServiceProtocol) {
    self.libraryService = libraryService
    super.init()
  }
}

extension FileDownloadService {
  public func download(item: SimpleLibraryItem) {
    let task = Task {
      switch item.type {
      case .bound:
        guard let children = libraryService.fetchContents(at: item.relativePath, limit: nil, offset: nil) else {
          let error = BookPlayerError.runtimeError("Failed to fetch children for bound item: \(item.relativePath)")
          eventPublisher.send((item.id, .error(error)))
          return
        }

        let totalChildren = children.count

        multiFileProgress[item.id] = (currentIndex: 0, totalFiles: totalChildren, fileProgress: 0.0)

        eventPublisher.send((item.id, .starting))

        for (index, childItem) in children.enumerated() {
          multiFileProgress[item.id]?.currentIndex = index
          multiFileProgress[item.id]?.fileProgress = 0.0

          await downloadSingleFile(from: childItem, parentItemID: item.id)
        }

        multiFileProgress.removeValue(forKey: item.id)

        eventPublisher.send((item.id, .finished))

      case .book:
        await downloadSingleFile(from: item, parentItemID: nil)

      case .folder:
        let error = BookPlayerError.runtimeError("Cannot download folder items: \(item.relativePath)")
        eventPublisher.send((item.id, .error(error)))
      }
    }

    activeDownloadTasks[item.id] = task
  }

  private func downloadSingleFile(from item: SimpleLibraryItem, parentItemID: String?) async {
    guard let remoteURL = item.remoteURL else {
      let error = BookPlayerError.runtimeError("No remote URL for item: \(item.relativePath)")
      eventPublisher.send((item.id, .error(error)))
      return
    }

    if parentItemID == nil {
      eventPublisher.send((item.id, .starting))
    }

    let request = URLRequest(url: remoteURL)
    let downloadTask = downloadSession.downloadTask(with: request)
    
    taskToItemMapping[downloadTask.taskIdentifier] = item.id
    taskToParentItemMapping[downloadTask.taskIdentifier] = parentItemID
    
    downloadTask.resume()
  }

  private func handleProgress(_ progress: Double, for itemID: String, parentItemID: String?) {
    if let parentID = parentItemID {
      multiFileProgress[parentID]?.fileProgress = progress

      if let multiProgress = multiFileProgress[parentID] {
        let completedFiles = Double(multiProgress.currentIndex)
        let currentFileProgress = progress
        let totalFiles = Double(multiProgress.totalFiles)

        let totalProgress = (completedFiles + currentFileProgress) / totalFiles
        eventPublisher.send((parentID, .progress(totalProgress)))
      }
    } else {
      eventPublisher.send((itemID, .progress(progress)))
    }
  }
}

extension FileDownloadService {
  public func cancelDownload(for itemID: String) {
    activeDownloadTasks[itemID]?.cancel()
    activeDownloadTasks.removeValue(forKey: itemID)

    multiFileProgress.removeValue(forKey: itemID)
    
    downloadSession.getAllTasks { tasks in
      for task in tasks {
        if let mappedItemID = self.taskToItemMapping[task.taskIdentifier], mappedItemID == itemID {
          task.cancel()
        }
      }
    }
  }

  public func cancelAllDownloads() {
    for task in activeDownloadTasks.values {
      task.cancel()
    }
    activeDownloadTasks.removeAll()

    multiFileProgress.removeAll()
    
    downloadSession.getAllTasks { tasks in
      for task in tasks {
        task.cancel()
      }
    }
    
    taskToItemMapping.removeAll()
    taskToParentItemMapping.removeAll()
  }
}

extension FileDownloadService: URLSessionDownloadDelegate {
  public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    guard let itemID = taskToItemMapping[downloadTask.taskIdentifier] else {
      Self.logger.error("No item mapping found for task \(downloadTask.taskIdentifier)")
      return
    }
    
    let parentItemID = taskToParentItemMapping[downloadTask.taskIdentifier] ?? nil
    
    guard let item = libraryService.getSimpleItem(with: itemID) else {
      Self.logger.error("Could not find item for ID: \(itemID)")
      return
    }
    
    let destinationURL = DataManager.getProcessedFolderURL().appendingPathComponent(item.relativePath)
    
    do {
      try FileManager.default.createDirectory(
        at: destinationURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: nil
      )
      
      if FileManager.default.fileExists(atPath: destinationURL.path) {
        try FileManager.default.removeItem(at: destinationURL)
      }
      
      try FileManager.default.moveItem(at: location, to: destinationURL)
      
      if parentItemID == nil {
        eventPublisher.send((itemID, .finished))
      }
    } catch {
      Self.logger.error("Failed to move downloaded file for \(itemID): \(error)")
      let errorEvent = (parentItemID ?? itemID, Event.error(error))
      eventPublisher.send(errorEvent)
    }
    
    taskToItemMapping.removeValue(forKey: downloadTask.taskIdentifier)
    taskToParentItemMapping.removeValue(forKey: downloadTask.taskIdentifier)
  }
  
  public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    guard let itemID = taskToItemMapping[downloadTask.taskIdentifier] else { return }
    
    let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    let parentItemID = taskToParentItemMapping[downloadTask.taskIdentifier] ?? nil
    
    handleProgress(progress, for: itemID, parentItemID: parentItemID)
  }
  
  public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let itemID = taskToItemMapping[task.taskIdentifier] else { return }
    
    let parentItemID = taskToParentItemMapping[task.taskIdentifier] ?? nil
    
    taskToItemMapping.removeValue(forKey: task.taskIdentifier)
    taskToParentItemMapping.removeValue(forKey: task.taskIdentifier)
    
    if let error = error {
      Self.logger.error("Download failed for \(itemID): \(error)")
      let errorEvent = (parentItemID ?? itemID, Event.error(error))
      eventPublisher.send(errorEvent)
    }
  }
}
