//
//  ItemSource.swift
//  BookPlayer
//
//  Created by Jeremy Grenier on 7/7/25.
//  Copyright © 2025 BookPlayer LLC. All rights reserved.
//

import Foundation

@objc public enum ItemSource: Int16, CaseIterable {
  case local = 0
  case remote = 1
  case jellyfin = 2
}

extension ItemSource {
  public var simpleSource: SimpleItemSource {
    switch self {
    case .local:
      return .local
    case .remote:
      return .remote
    case .jellyfin:
      return .jellyfin
    }
  }
}

extension SimpleItemSource {
  public var itemSource: ItemSource {
    switch self {
    case .local:
      return .local
    case .remote:
      return .remote
    case .jellyfin:
      return .jellyfin
    }
  }
}
