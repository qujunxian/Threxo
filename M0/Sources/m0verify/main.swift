import Foundation

enum Status: String {
    case pass = "PASS"
    case fail = "FAIL"
    case skip = "SKIP"
}

struct CheckResult {
    let name: String
    let status: Status
    let detail: String
}

var results: [CheckResult] = []

func record(_ name: String, _ status: Status, _ detail: String) {
    results.append(CheckResult(name: name, status: status, detail: detail))
    print("[\(status.rawValue)] \(name) — \(detail)")
}

func runTool(_ path: String, _ arguments: [String], workingDirectory: URL? = nil) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectory
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

// MARK: - Setup

let cliArguments = CommandLine.arguments
let default7zz = FileManager.default.currentDirectoryPath + "/bin/7zz"
let sevenZipPath: String
if let index = cliArguments.firstIndex(of: "--7zz"), index + 1 < cliArguments.count {
    sevenZipPath = cliArguments[index + 1]
} else {
    sevenZipPath = default7zz
}

guard FileManager.default.isExecutableFile(atPath: sevenZipPath) else {
    print("FATAL: 7zz not executable at \(sevenZipPath)")
    exit(2)
}

let fileManager = FileManager.default
let work = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("m0-\(UUID().uuidString)", isDirectory: true)
try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: work) }

print("== M0 verification ==")
print("7zz : \(sevenZipPath)")
print("work: \(work.path)")
print("")

let runner = SevenZipRunner(executableURL: URL(fileURLWithPath: sevenZipPath))

// 1. Engine runs and reports version.
do {
    var banner = ""
    let code = try runner.run(arguments: [], onLine: { banner += $0 + "\n" })
    let firstLine = banner.split(separator: "\n").first.map(String.init) ?? "no output"
    record(
        "7zz runs",
        code == 0 && banner.contains("7-Zip") ? .pass : .fail,
        "exit=\(code), banner=\(firstLine)"
    )
}

// 2. Build a sample tree with text files and 8 MB of incompressible data.
let sample = work.appendingPathComponent("sample", isDirectory: true)
try fileManager.createDirectory(
    at: sample.appendingPathComponent("sub", isDirectory: true),
    withIntermediateDirectories: true
)
try "hello threva".write(
    to: sample.appendingPathComponent("a.txt"),
    atomically: true,
    encoding: .utf8
)
try "second file".write(
    to: sample.appendingPathComponent("sub/b.txt"),
    atomically: true,
    encoding: .utf8
)

var random = Data(count: 32 * 1024 * 1024)
random.withUnsafeMutableBytes { pointer in
    if let base = pointer.baseAddress {
        arc4random_buf(base, pointer.count)
    }
}
try random.write(to: sample.appendingPathComponent("random.bin"))

// 3. Compress with progress.
do {
    var progress: [Int] = []
    let code = try runner.run(
        arguments: ["a", "sample.zip", "sample", "-tzip", "-mx=5", "-bsp1", "-bb1"],
        workingDirectory: work,
        onProgress: { progress.append($0.percent) }
    )
    let exists = fileManager.fileExists(atPath: work.appendingPathComponent("sample.zip").path)
    record(
        "compress ZIP",
        code == 0 && exists ? .pass : .fail,
        "exit=\(code), exists=\(exists)"
    )
    record(
        "progress events (compress)",
        progress.isEmpty ? .fail : .pass,
        "count=\(progress.count), max=\(progress.max() ?? -1)"
    )
}

// 4. List entries via `l -slt -ba`.
do {
    let zip = work.appendingPathComponent("sample.zip")
    var listing = ""
    let code = try runner.run(
        arguments: ["l", "-slt", "-ba", zip.path],
        workingDirectory: work,
        onLine: { listing += $0 + "\n" }
    )
    let entries = ArchiveLister.parse(listing)
    let files = entries.filter { !$0.isDirectory }
    let hasA = files.contains { $0.path.hasSuffix("a.txt") }
    let hasB = files.contains { $0.path.hasSuffix("sub/b.txt") }
    record(
        "list archive",
        code == 0 && files.count >= 3 && hasA && hasB ? .pass : .fail,
        "exit=\(code), entries=\(entries.count), files=\(files.count), a=\(hasA), b=\(hasB)"
    )
}

// 5. Extract and verify contents.
do {
    let output = work.appendingPathComponent("out", isDirectory: true)
    try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
    let zip = work.appendingPathComponent("sample.zip")
    var progress: [Int] = []
    let code = try runner.run(
        arguments: ["x", zip.path, "-o\(output.path)", "-y", "-bsp1", "-bb1"],
        workingDirectory: work,
        onProgress: { progress.append($0.percent) }
    )
    let aOK = (try? String(
        contentsOf: output.appendingPathComponent("sample/a.txt"),
        encoding: .utf8
    )) == "hello threva"
    let bOK = (try? String(
        contentsOf: output.appendingPathComponent("sample/sub/b.txt"),
        encoding: .utf8
    )) == "second file"
    let randomOK = fileManager.fileExists(
        atPath: output.appendingPathComponent("sample/random.bin").path
    )
    record(
        "extract archive",
        code == 0 && aOK && bOK && randomOK ? .pass : .fail,
        "exit=\(code), a=\(aOK), b=\(bOK), random=\(randomOK), progress=\(progress.count)"
    )
}

// 6. Malicious paths are detected before extraction.
do {
    let python = """
    import zipfile, sys
    z = zipfile.ZipFile(sys.argv[1], 'w')
    for name in ['../evil.txt', '/abs.txt', 'safe.txt', 'sub/../../escape.txt', 'C:\\\\win.txt']:
        z.writestr(name, 'x')
    z.close()
    """
    try python.write(
        to: work.appendingPathComponent("make_evil.py"),
        atomically: true,
        encoding: .utf8
    )
    let pythonCode = try runTool(
        "/usr/bin/python3",
        ["make_evil.py", "evil.zip"],
        workingDirectory: work
    )
    let evil = work.appendingPathComponent("evil.zip")
    var listing = ""
    let code = try runner.run(
        arguments: ["l", "-slt", "-ba", evil.path],
        workingDirectory: work,
        onLine: { listing += $0 + "\n" }
    )
    let entries = ArchiveLister.parse(listing)
    let unsafe = entries.compactMap { entry -> (String, String)? in
        guard let reason = PathValidator.unsafeReason(entry.path) else { return nil }
        return (entry.path, reason)
    }
    let sampleDescriptions = unsafe.prefix(2).map { "\($0.0) [\($0.1)]" }
    record(
        "path traversal guard",
        pythonCode == 0 && code == 0 && unsafe.count >= 3 ? .pass : .fail,
        "entries=\(entries.count), unsafe=\(unsafe.count), samples=\(sampleDescriptions)"
    )
}

// 7. Cancel a running compression.
do {
    let bigFile = work.appendingPathComponent("big.bin")
    var bigData = Data(count: 16 * 1024 * 1024)
    bigData.withUnsafeMutableBytes { pointer in
        if let base = pointer.baseAddress {
            arc4random_buf(base, pointer.count)
        }
    }
    try bigData.write(to: bigFile)

    var progress: [Int] = []
    let process = try runner.start(
        arguments: ["a", "big.zip", "big.bin", "-tzip", "-mx=9", "-bsp1", "-bb1"],
        workingDirectory: work,
        onProgress: { progress.append($0.percent) }
    )
    Thread.sleep(forTimeInterval: 0.15)
    let wasRunning = process.isRunning
    if wasRunning { process.terminate() }
    process.waitUntilExit()
    let stopped = !process.isRunning

    if wasRunning {
        record(
            "cancel running task",
            stopped && !progress.isEmpty ? .pass : .fail,
            "wasRunning=true, stopped=\(stopped), status=\(process.terminationStatus), progress=\(progress.count)"
        )
    } else {
        record(
            "cancel running task",
            .skip,
            "finished before cancel (status=\(process.terminationStatus), progress=\(progress.count))"
        )
    }
}

// MARK: - Summary

print("")
let passCount = results.filter { $0.status == .pass }.count
let failCount = results.filter { $0.status == .fail }.count
let skipCount = results.filter { $0.status == .skip }.count
print("== summary: PASS=\(passCount) FAIL=\(failCount) SKIP=\(skipCount) ==")

if failCount > 0 {
    print("FAILED checks:")
    for result in results where result.status == .fail {
        print(" - \(result.name): \(result.detail)")
    }
    exit(1)
}
