//
//  AirwaveApp.swift
//  Airwave
//
//  Created by gamer on 19/11/25.
//

import SwiftUI

@main
struct AirwaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    @StateObject private var viewModel: MenuBarViewModel

    init() {
        _viewModel = StateObject(
            wrappedValue: RuntimeEnvironment.isTestHost
                ? MenuBarViewModel.testingInstance()
                : MenuBarViewModel.shared
        )
        // Start silent update discovery with app lifecycle, not Settings lifecycle.
        _ = UpdateManager.shared
    }
    
    var body: some Scene {
        MenuBarExtra {
            AirwaveMenuView()
                .environmentObject(viewModel)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 500, height: 815)
    }
}
