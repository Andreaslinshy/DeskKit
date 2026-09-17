import AppKit
if CommandLine.arguments.contains("--script-worker") { ScriptWorker.main() }
else {
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
