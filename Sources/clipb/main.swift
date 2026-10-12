import AppKit

// `clipb copy ...` is a command-line client for the running app.
if CommandLine.arguments.dropFirst().first == "copy" {
    exit(CopyCommand.run(Array(CommandLine.arguments.dropFirst(2))))
}

if CommandLine.arguments.dropFirst().first == "route" {
    exit(RouteCommand.run(Array(CommandLine.arguments.dropFirst(2))))
}

if CommandLine.arguments.dropFirst().first == "install-native-host" {
    exit(NativeHostInstaller.run(Array(CommandLine.arguments.dropFirst(2))))
}

// Chrome starts a native messaging host with the caller's origin as argument 1.
if CommandLine.arguments.dropFirst().first?.hasPrefix("chrome-extension://") == true {
    exit(NativeHost.run())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
