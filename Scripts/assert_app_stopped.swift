import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: assert_app_stopped.swift <app bundle>\n".utf8))
    exit(2)
}
let target = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
let running = NSWorkspace.shared.runningApplications.filter { app in
    !app.isTerminated && app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == target
}
if !running.isEmpty {
    let pids = running.map { String($0.processIdentifier) }.joined(separator: ", ")
    FileHandle.standardError.write(Data(
        "Refusing to replace a running app (PID \(pids)): \(target.path)\nQuit this copy before building. Replacing its signed executable while it runs invalidates macOS privacy approvals.\n".utf8))
    exit(1)
}
