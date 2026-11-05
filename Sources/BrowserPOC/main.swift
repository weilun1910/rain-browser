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

// The source dry runs read other apps' data from temp copies under the support folder, so they
// honour --data-dir and keep those copies out of the real profile.
if ["--chrome-dry-run", "--notion-dry-run", "--granola-dry-run"].contains(where: args.contains),
   let i = args.firstIndex(of: "--data-dir"), i + 1 < args.count {
    let dir = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
    Paths.overrideRoot = dir
    Paths.ensure(dir)
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

// The demo profile: --seed-demo <empty folder> builds it from Demo/, --demo-eval <profile> scores
// Related against Demo/expected.json on a copy, and --demo-snapshots <out> --profile <profile>
// renders it offscreen. None of them touch the real profile.
if args.contains("--seed-demo") { exit(MainActor.assumeIsolated { DemoSeeder.commandLine(args) }) }
if args.contains("--demo-eval") { exit(DemoEval.commandLine(args)) }
if args.contains("--demo-diag") { exit(EngineDemoDiag.run(args)) }
if args.contains("--quit-check") { exit(EngineQuitCheck.run(args)) }
if args.contains("--demo-snapshots") { exit(MainActor.assumeIsolated { DemoSnapshots.commandLine(args) }) }

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
// --reduce-transparency: the glass falls back to its solid surfaces, as it does when Reduce Transparency is on.
if args.contains("--reduce-transparency") { Theme.GlassStyle.forceReduceTransparency = true }

// --data-dir <dir> runs the app on its own support folder and its own WebKit store, so test
// and demo runs never read or write the real profile.
if let i = args.firstIndex(of: "--data-dir"), i + 1 < args.count {
    let dir = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
    Paths.overrideRoot = dir
    Paths.ensure(dir)
    MainActor.assumeIsolated { BrowserModel.dataStoreID = Paths.storeID(for: dir) }
}
// The Related shelf demo and the motion tours keep nothing of WebKit's on disk.
if args.contains("--shelf-demo") || args.contains("--motion-tour") { MainActor.assumeIsolated { BrowserModel.useEphemeralStore = true } }
// The tours record and capture the window, so their pages keep drawing even when it's covered.
if args.contains("--motion-tour") { MainActor.assumeIsolated { BrowserModel.keepPaintingWhenHidden = true } }

let known: Set<String> = ["--selftest", "--smoketest", "--chrome-dry-run", "--workdir", "--extract-check", "--data-dir",
                          "--render-art", "--render-review", "--profile", "--query", "--motion-tour", "--reduce-motion", "--reduce-transparency",
                          "--eval", "--models-dir", "--verbose", "--notion-dry-run", "--granola-dry-run", "--download-models", "--scale",
                          "--mcp", "--mcp-fixture", "--graph-bench", "--shelf-demo",
                          "--seed-demo", "--demo-content", "--models-from", "--offline", "--no-topics", "--keep-dates",
                          "--demo-eval", "--demo-snapshots", "--demo-diag", "--case", "--quit-check", "--reasons", "--panel", "--passages", "--context-file", "--parts", "--rr"]
if let unknown = args.dropFirst().first(where: { $0.hasPrefix("--") && !known.contains($0) }) {
    print("Unknown flag \(unknown). Flags: --selftest, --smoketest, --chrome-dry-run, each with optional --workdir <dir> for the tests, --data-dir <dir> to run the app on a separate profile, --mcp to serve the index to AI clients, and --mcp-fixture <dir> to write a test profile.")
    exit(2)
}

// The real app holds Related to its power setting, to being on screen and to the dwell. The shelf
// demo and the motion tours show cards whatever the power source.
if !args.contains("--shelf-demo") && !args.contains("--motion-tour") { MainActor.assumeIsolated { RelatedGate.enforced = true } }

// The app itself. A build that hasn't opened this profile before backs it up first, before
// anything in it is read or written.
MainActor.assumeIsolated { DataSafety.prepareLaunch() }
MainActor.assumeIsolated { AppMain.run() }
