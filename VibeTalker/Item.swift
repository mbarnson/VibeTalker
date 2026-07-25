//
//  Item.swift
//  VibeTalker
//
//  Created by Matthew Barnson on 7/24/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
