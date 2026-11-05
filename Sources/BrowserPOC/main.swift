import Foundation

let args = CommandLine.arguments

if args.contains("--selftest") {
    var workdir: URL?
    if let i = args.firstIndex(of: "--workdir"), i + 1 < args.count {
        workdir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }
    exit(SelfTest.run(workdir: workdir))
}

if args.contains("--smoketest") {
    var workdir: URL?
    if let i = args.firstIndex(of: "--workdir"), i + 1 < args.count {
        workdir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }
    let code = MainActor.assumeIsolated { SmokeTest.run(workdir: workdir) }
    exit(code)
}

if let i = args.firstIndex(of: "--extract-check"), i + 1 < args.count {
    let target = args[i + 1]
    exit(MainActor.assumeIsolated { ExtractCheck.run(target) })
}

if args.contains("--chrome-dry-run") {
    exit(ChromeHistory.dryRun())
}

// --data-dir <dir> runs the app on its own support folder and its own WebKit store, so test
// and demo runs never read or write the real profile.
if let i = args.firstIndex(of: "--data-dir"), i + 1 < args.count {
    let dir = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
    Paths.overrideRoot = dir
    Paths.ensure(dir)
    MainActor.assumeIsolated { BrowserModel.dataStoreID = Paths.storeID(for: dir) }
}

let known: Set<String> = ["--selftest", "--smoketest", "--chrome-dry-run", "--workdir", "--extract-check", "--data-dir"]
if let unknown = args.dropFirst().first(where: { $0.hasPrefix("--") && !known.contains($0) }) {
    print("Unknown flag \(unknown). Flags: --selftest, --smoketest, --chrome-dry-run, each with optional --workdir <dir> for the tests, and --data-dir <dir> to run the app on a separate profile.")
    exit(2)
}

MainActor.assumeIsolated { AppMain.run() }
