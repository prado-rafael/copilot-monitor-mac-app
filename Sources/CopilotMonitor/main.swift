import AppKit

MainActor.assumeIsolated {
        // Modo linha de comando (`--json`, `--check`, `--help`): responde e sai sem criar o NSApplication.
        let arguments = Array(CommandLine.arguments.dropFirst())
        if CLIRunner.handles(arguments) {
                exit(CLIRunner.run(arguments))
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
}
