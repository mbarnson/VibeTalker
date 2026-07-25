//
//  VibeTalkerApp.swift
//  VibeTalker
//
//  Created by Matthew Barnson on 7/24/26.
//

import SwiftUI

@main
struct VibeTalkerApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
        }
        .defaultSize(width: 1_280, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
