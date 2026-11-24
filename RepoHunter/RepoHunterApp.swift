import SwiftUI

@main
struct RepoHunterApp: App {
    @StateObject private var search = SearchViewModel()
    @StateObject private var downloader = Downloader()
    @StateObject private var settings = SettingsStore()

    var body: some Scene {
        WindowGroup("RepoHunter") {
            ContentView()
                .environmentObject(search)
                .environmentObject(downloader)
                .environmentObject(settings)
                .frame(minWidth: 1020, minHeight: 640)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(downloader)
        }
    }
}
