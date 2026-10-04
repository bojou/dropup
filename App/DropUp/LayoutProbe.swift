import AppKit
import SwiftUI
import DropUpCore

/// Temporary probe: renders the onboarding and Settings forms for an SSH key login and prints their size. Not for merging.
@MainActor
enum LayoutProbe {
    static func run(model: AppModel) {
        setvbuf(stdout, nil, _IOLBF, 0)
        func shot<V: View>(_ label: String, _ view: V, size: CGSize = CGSize(width: 600, height: 460)) {
            let host = NSHostingController(rootView: view.frame(width: size.width, height: size.height))
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable]
            window.setContentSize(size)
            window.orderFrontRegardless()
            host.view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
            host.view.layoutSubtreeIfNeeded()
            if let rep = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) {
                host.view.cacheDisplay(in: host.view.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    print("PROBE-PNG \(label) \(png.base64EncodedString())")
                }
            }
            window.orderOut(nil)
        }

        var password = ServerDraft()
        password.host = "files.example.com"
        password.username = "deploy"
        password.password = "pw"

        var key = password
        key.selectLoginMethod(.sshKey)
        key.keyFilePath = "/Users/me/.ssh/id_ed25519"

        var keyEmpty = ServerDraft()
        keyEmpty.selectLoginMethod(.sshKey)
        keyEmpty.showProblems = true

        var ftp = password
        ftp.selectProtocol(.ftp)
        ftp.host = "ftp.example.com"
        ftp.username = "deploy"

        func fitting(_ label: String, _ draft: ServerDraft, failure: String? = nil) {
            let view = OnboardingView(model: model, probeStep: .server, probeDraft: draft) {}
            if let failure { view.tester.probeFail(failure) }
            let host = NSHostingView(rootView: view.probeContent.fixedSize(horizontal: false, vertical: true))
            print("PROBE fit \(label): content needs \(Int(host.fittingSize.height)) pt of 399 available")
        }
        let long = "The server didn't accept this RSA key. Many servers no longer take RSA keys, and an ed25519 key is accepted more widely."
        fitting("password", password)
        fitting("key", key)
        fitting("key, nothing filled in, problems showing", keyEmpty)
        fitting("key, long test failure", key, failure: long)
        fitting("ftp (picker greyed)", ftp)

        shot("onboarding-password", OnboardingView(model: model, probeStep: .server, probeDraft: password) {})
        shot("onboarding-key", OnboardingView(model: model, probeStep: .server, probeDraft: key) {})
        let failing = OnboardingView(model: model, probeStep: .server, probeDraft: key) {}
        failing.tester.probeFail(long)
        shot("onboarding-key-failure", failing)
        shot("onboarding-key-empty", OnboardingView(model: model, probeStep: .server, probeDraft: keyEmpty) {})
        shot("onboarding-ftp", OnboardingView(model: model, probeStep: .server, probeDraft: ftp) {})

        let saved = ServerConfig(
            transferProtocol: .sftp, host: "files.example.com", username: "deploy", remoteDirectory: "/var/www",
            loginMethod: .sshKey, keyFilePath: "/Users/me/.ssh/id_ed25519"
        )
        try? model.save(saved, secret: "")
        shot("settings-key", ConnectionSettings(model: model, close: {}), size: CGSize(width: 600, height: 409))
        print("PROBE done")
    }
}
