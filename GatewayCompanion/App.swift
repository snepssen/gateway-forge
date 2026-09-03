import SwiftUI

@main
struct GatewayCompanionApp: App {
    @StateObject private var discovery = DesktopDiscovery()
    @StateObject private var store = CompanionStore()
    @StateObject private var player = CompanionAudioPlayer()

    var body: some Scene {
        WindowGroup {
            CompanionRootView()
                .environmentObject(discovery)
                .environmentObject(store)
                .environmentObject(player)
                .tint(.indigo)
                .task { discovery.start() }
        }
    }
}
