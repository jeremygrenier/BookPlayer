//
//  SimpleItemSource.swift
//  BookPlayer
//
//  Created by Jeremy Grenier on 7/7/25.
//  Copyright © 2025 BookPlayer LLC. All rights reserved.
//

import Foundation

public enum SimpleItemSource: Int16, CaseIterable, Codable {
  case local
  case remote
  case jellyfin
}
