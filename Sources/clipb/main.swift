import AppKit

// `clipb copy ...` is a command-line client for the running app.
if CommandLine.arguments.dropFirst().first == "copy" {
    exit(CopyCommand.run(Array(CommandLine.arguments.dropFirst(2))))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
