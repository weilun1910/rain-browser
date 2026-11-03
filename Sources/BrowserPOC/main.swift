import Foundation

let args = CommandLine.arguments

if args.contains("--selftest") {
    var workdir: URL?
    if let i = args.firstIndex(of: "--workdir"), i + 1 < args.count {
        workdir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }
    exit(SelfTest.run(workdir: workdir))
}

if args.contains("--chrome-dry-run") {
    exit(ChromeHistory.dryRun())
}

AppMain.run()
