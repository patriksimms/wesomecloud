import SwiftUI
import AppKit
import WesomeCloudMacApp

@main
struct WesomeCloudApplication: App {
    @State private var viewModel: WesomeCloudViewModel?
    @State private var backgroundTasks: BackgroundTaskSyncController?
    @State private var updatePresenter: (any SoftwareUpdatePresenting)?
    @State private var settingsRequestCount = 0
    @State private var startupError: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let viewModel {
                    WesomeCloudRootView(viewModel: viewModel, settingsRequestCount: settingsRequestCount)
                } else {
                    ContentUnavailableView(
                        "WesomeCloud could not start",
                        systemImage: "exclamationmark.triangle",
                        description: Text(startupError ?? "Runtime is not initialized.")
                    )
                    .frame(minWidth: 520, minHeight: 320)
                }
            }
            .task {
                guard viewModel == nil else { return }
                do {
                    let factory = ProductionAppFactory()
                    let model = try factory.makeViewModel()
                    await model.initializeTracking()
                    await model.restoreFinderLocations()
                    viewModel = model
                    updatePresenter = factory.makeSoftwareUpdatePresenter()
                    let controller = try factory.makeBackgroundTaskController()
                    _ = try await controller.registerAndSchedule()
                    backgroundTasks = controller
                } catch {
                    startupError = String(describing: error)
                }
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updatePresenter?.checkForUpdates()
                }
                .disabled(updatePresenter == nil)
            }
        }
        MenuBarExtra("WesomeCloud", systemImage: "icloud") {
            if let viewModel {
                WesomeCloudMenuBarView(
                    accounts: viewModel.accounts,
                    isSyncPaused: viewModel.preferences.sync.isSyncPaused,
                    updateStatus: viewModel.updateStatus,
                    syncNow: {
                        await viewModel.syncNow()
                    },
                    toggleSyncPaused: {
                        await viewModel.toggleSyncPaused()
                    },
                    checkForUpdates: {
                        await viewModel.checkForUpdates()
                    },
                    openApp: {
                        NSApp.activate(ignoringOtherApps: true)
                    },
                    openSettings: {
                        settingsRequestCount += 1
                        NSApp.activate(ignoringOtherApps: true)
                    },
                    quitApp: {
                        NSApp.terminate(nil)
                    }
                )
            } else {
                ContentUnavailableView(
                    "WesomeCloud",
                    systemImage: "icloud.slash",
                    description: Text(startupError ?? "Starting...")
                )
                .frame(width: 280)
            }
        }
    }
}
