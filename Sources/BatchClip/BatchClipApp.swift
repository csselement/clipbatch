import AppKit
import SwiftUI
import UserNotifications

@main
struct BatchClipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = DownloaderStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 860, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Text File...") {
                    store.openTextFile()
                }
                .keyboardShortcut("o", modifiers: [.command])

                .disabled(store.isRunning)

                Button("Start Batch") { store.startBatch() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!store.canStart)

                Button("Stop Batch") {
                    store.cancelBatch()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!store.isRunning || store.isStopping)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
