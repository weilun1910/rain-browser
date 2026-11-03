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

if args.contains("--chrome-dry-run") {
    exit(ChromeHistory.dryRun())
}

let known: Set<String> = ["--selftest", "--smoketest", "--chrome-dry-run", "--workdir"]
if let unknown = args.dropFirst().first(where: { $0.hasPrefix("--") && !known.contains($0) }) {
    print("Unknown flag \(unknown). Flags: --selftest, --smoketest, --chrome-dry-run, each with optional --workdir <dir> for the tests.")
    exit(2)
}

MainActor.assumeIsolated { AppMain.run() }
