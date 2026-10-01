import AppKit
import Observation
import ServiceManagement
import UserNotifications
import DropUpCore
import DropUpTransport

/// Runs "Test Connection" and tracks its result for the form that started it.
@MainActor
@Observable
final class ConnectionTester {
    enum State: Equatable {
        case idle
        case testing
        case success(milliseconds: Int)
        case failure(String)
    }

    private(set) var state = State.idle
    @ObservationIgnored private var task: Task<Void, Never>?

    func test(_ draft: ServerDraft, using browser: ServerBrowser) {
        task?.cancel()
        state = .testing
        let config = draft.config
        let password = draft.password
        task = Task {
            do {
                let result = try await browser.testConnection(config, password: password)
                guard !Task.isCancelled else { return }
                state = .success(milliseconds: Int((result.duration * 1000).rounded()))
            } catch is CancellationError {
                // Superseded by a newer test or by a form change.
            } catch {
                guard !Task.isCancelled else { return }
                state = .failure(ServerBrowser.message(for: error))
            }
        }
    }

    /// Call when the form changes: an old result no longer describes what's typed.
    func reset() {
        task?.cancel()
        state = .idle
    }
}

/// The folder list in onboarding and the Browse… sheet: shows the folders inside `path` and lets you walk through them.
@MainActor
@Observable
final class FolderBrowserModel {
    private(set) var folders: [String] = []
    private(set) var isLoading = false
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    func load(_ path: String, draft: ServerDraft, using browser: ServerBrowser) {
        task?.cancel()
        isLoading = true
        error = nil
        let config = draft.config
        let password = draft.password
        task = Task {
            do {
                let result = try await browser.listDirectories(config, password: password, path: path)
                guard !Task.isCancelled else { return }
                folders = result
                isLoading = false
            } catch is CancellationError {
                // A newer load replaced this one.
            } catch {
                guard !Task.isCancelled else { return }
                folders = []
                isLoading = false
                self.error = ServerBrowser.message(for: error)
            }
        }
    }

    func cancel() {
        task?.cancel()
        isLoading = false
    }
}

/// "Open DropUp at login" through the system's login item service.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// "Show a notification" when a batch of uploads finishes.
enum Notifier {
    static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        Task {
            var settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert])
                settings = await center.notificationSettings()
            }
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
