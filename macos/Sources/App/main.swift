import AppKit

// Storyboard-less AppKit entry point: install the delegate before
// NSApplicationMain so lifecycle callbacks fire from the very first event.
_ = LaunchClock.start
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
