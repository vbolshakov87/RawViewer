import AppKit

// `RawViewer --bench <file>...` times each decode stage without opening any UI.
if let i = CommandLine.arguments.firstIndex(of: "--bench") {
    Bench.run(Array(CommandLine.arguments[(i + 1)...]))
    exit(0)
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
