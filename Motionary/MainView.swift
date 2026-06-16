//
//  MainView.swift
//  Motionary
//
//  Created by Ryder Thomas on 3/1/25.
//


import SwiftUI

@main
struct MainView: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Home", systemImage: "rectangle.stack.fill") {
                    HomeView()
                }

                Tab("Settings", systemImage: "gearshape.fill") {
                    EmptyView()
                }
            }
            .labelStyle(.iconOnly)
        }
    }
}

