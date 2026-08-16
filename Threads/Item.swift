//
//  Item.swift
//  Threads
//
//  Created by Anmol  Jandaur on 8/16/26.
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
