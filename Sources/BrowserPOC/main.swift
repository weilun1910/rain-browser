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

if args.contains("--graph-bench") {
    exit(GraphBench.run())
}

if args.contains("--chrome-dry-run") {
    exit(ChromeHistory.dryRun())
}

// --render-art <dir>: the app icon in every size, plus mark and startup previews.
if let i = args.firstIndex(of: "--render-art"), i + 1 < args.count {
    let dir = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
    exit(MainActor.assumeIsolated { ArtRenderer.run(dir) })
}

// --render-review <dir>: light and dark snapshots of every main view, offscreen. With
// --profile <data dir> it renders a copy of that profile instead of the test fixtures.
if let i = args.firstIndex(of: "--render-review"), i + 1 < args.count {
    let dir = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
    if let p = args.firstIndex(of: "--profile"), p + 1 < args.count {
        let profile = URL(fileURLWithPath: (args[p + 1] as NSString).expandingTildeInPath, isDirectory: true)
        let q = args.firstIndex(of: "--query").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "cold start"
        exit(MainActor.assumeIsolated { LookRenders.runProfile(out: dir, profile: profile, query: q) })
    }
    exit(MainActor.assumeIsolated { LookRenders.run(out: dir) })
}
// --mcp serves the knowledge index to AI clients over stdio. It reads the profile in --data-dir,
// or the normal one, and never starts the app or creates the folder.
if args.contains("--mcp") {
    if let i = args.firstIndex(of: "--data-dir"), i + 1 < args.count {
        Paths.overrideRoot = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
    }
    exit(MCPServer.runStdio(root: Paths.root))
}

// --mcp-fixture <dir> writes a throwaway profile with made-up content, for MCP tests.
if let i = args.firstIndex(of: "--mcp-fixture"), i + 1 < args.count {
    exit(MCPFixture.run(URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true)))
}

// Engine: resurfacing quality and read-only source checks.
if args.contains("--eval") {
    var workdir: URL?
    if let i = args.firstIndex(of: "--workdir"), i + 1 < args.count {
        workdir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }
    exit(EngineEval.run(workdir: workdir))
}
if args.contains("--notion-dry-run") { exit(NotionSource.dryRun()) }
if args.contains("--download-models") {
    // Downloads the on-device models into a profile's Models folder, with --data-dir.
    if let i = args.firstIndex(of: "--data-dir"), i + 1 < args.count {
        Paths.overrideRoot = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
    }
    exit(ModelDownloader.commandLine())
}
if args.contains("--granola-dry-run") { exit(GranolaSource.dryRun()) }

// --reduce-motion: behave as if Reduce Motion were on, for checking it without changing System Settings.
if args.contains("--reduce-motion") { Motion.forceReduce = true }

// --data-dir <dir> runs the app on its own support folder and its own WebKit store, so test
// and demo runs never read or write the real profile.
if let i = args.firstIndex(of: "--data-dir"), i + 1 < args.count {
    let dir = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
    Paths.overrideRoot = dir
    Paths.ensure(dir)
    MainActor.assumeIsolated { BrowserModel.dataStoreID = Paths.storeID(for: dir) }
}

let known: Set<String> = ["--selftest", "--smoketest", "--chrome-dry-run", "--workdir", "--extract-check", "--data-dir",
                          "--render-art", "--render-review", "--profile", "--query", "--motion-tour", "--reduce-motion",
                          "--eval", "--models-dir", "--verbose", "--notion-dry-run", "--granola-dry-run", "--download-models", "--scale",
                          "--mcp", "--mcp-fixture", "--graph-bench"]
if let unknown = args.dropFirst().first(where: { $0.hasPrefix("--") && !known.contains($0) }) {
    print("Unknown flag \(unknown). Flags: --selftest, --smoketest, --chrome-dry-run, each with optional --workdir <dir> for the tests, --data-dir <dir> to run the app on a separate profile, --mcp to serve the index to AI clients, and --mcp-fixture <dir> to write a test profile.")
    exit(2)
}

MainActor.assumeIsolated { AppMain.run() }
