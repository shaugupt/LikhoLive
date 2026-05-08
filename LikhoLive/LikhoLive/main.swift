import AppKit

// Entry point — cannot use @main on NSObject subclass in Swift 6 AppKit apps
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
