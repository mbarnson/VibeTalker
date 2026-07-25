#!/usr/bin/env swift

import Foundation

struct ObserverEvent: Decodable {
    let schemaVersion: UInt8
    let sequence: UInt64
    let timestamp: String
    let source: String
    let kind: String
    let message: String
    let voiceSessionID: UUID?
    let utteranceID: UUID?
    let revision: UInt64?
    let interactionRequestID: UUID?
    let actionJobID: UUID?
}

struct Options {
    var follow = false
    var recent = 200
    var path = URL(
        fileURLWithPath: NSHomeDirectory(),
        isDirectory: true
    )
    .appending(path: "Library/Containers/org.barnson.VibeTalker/Data")
    .appending(path: "Library/Application Support/VibeTalker/EventLedger")
    .appending(path: "events.jsonl")
}

func usage(status: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("""
    usage: vibetalker-observe.swift [--follow] [--recent COUNT] [--path FILE]

    Prints the bounded recent VibeTalker Event Ledger projection. With --follow,
    continues printing new JSONL records until interrupted.

    """.utf8))
    exit(status)
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        switch argument {
        case "--follow", "-f":
            options.follow = true
        case "--recent", "-n":
            guard let value = arguments.first,
                  let count = Int(value),
                  count >= 0 else {
                usage()
            }
            arguments.removeFirst()
            options.recent = min(count, 10_000)
        case "--path":
            guard let value = arguments.first else { usage() }
            arguments.removeFirst()
            options.path = URL(fileURLWithPath: value)
        case "--help", "-h":
            usage(status: 0)
        default:
            usage()
        }
    }
    return options
}

func tailData(_ handle: FileHandle, lineCount: Int) throws -> (Data, UInt64) {
    let end = try handle.seekToEnd()
    guard lineCount > 0, end > 0 else { return (Data(), end) }

    let chunkSize: UInt64 = 64 * 1_024
    let maximumBytes: UInt64 = 8 * 1_024 * 1_024
    var start = end
    var data = Data()
    var newlines = 0
    while start > 0,
          UInt64(data.count) < maximumBytes,
          newlines <= lineCount {
        let length = min(
            chunkSize,
            start,
            maximumBytes - UInt64(data.count)
        )
        start -= length
        try handle.seek(toOffset: start)
        let chunk = try handle.read(upToCount: Int(length)) ?? Data()
        data.insert(contentsOf: chunk, at: 0)
        newlines = data.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
    }
    let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
    let selected = lines.suffix(lineCount)
    var result = Data()
    for line in selected {
        result.append(contentsOf: line)
        result.append(0x0A)
    }
    return (result, end)
}

func render(_ line: Data) {
    guard !line.isEmpty else { return }
    do {
        let event = try JSONDecoder().decode(ObserverEvent.self, from: line)
        let timestamp = event.timestamp
            .replacingOccurrences(of: "T", with: " ")
            .replacingOccurrences(of: "Z", with: "")
        let identity = [
            event.voiceSessionID.map { "voice=\($0.uuidString.prefix(8))" },
            event.utteranceID.map { "utterance=\($0.uuidString.prefix(8))" },
            event.revision.map { "revision=\($0)" },
            event.interactionRequestID.map {
                "interaction=\($0.uuidString.prefix(8))"
            },
            event.actionJobID.map { "job=\($0.uuidString.prefix(8))" }
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        let suffix = identity.isEmpty ? "" : " [\(identity)]"
        print(
            String(
                format: "%06llu  %@  %-10@  %-14@  %@%@",
                event.sequence,
                timestamp as NSString,
                event.kind.uppercased() as NSString,
                event.source as NSString,
                event.message as NSString,
                suffix as NSString
            )
        )
    } catch {
        FileHandle.standardError.write(
            Data("invalid ledger record: \(error.localizedDescription)\n".utf8)
        )
    }
}

func consume(_ data: Data, pending: inout Data) {
    pending.append(data)
    while let newline = pending.firstIndex(of: 0x0A) {
        render(Data(pending[..<newline]))
        pending.removeSubrange(...newline)
    }
}

let options = parseOptions()
guard FileManager.default.fileExists(atPath: options.path.path) else {
    FileHandle.standardError.write(
        Data("VibeTalker Event Ledger not found at \(options.path.path)\n".utf8)
    )
    exit(1)
}

let handle = try FileHandle(forReadingFrom: options.path)
let (recentData, initialEnd) = try tailData(handle, lineCount: options.recent)
var pending = Data()
consume(recentData, pending: &pending)

guard options.follow else {
    try handle.close()
    exit(0)
}

pending.removeAll(keepingCapacity: true)
var offset = initialEnd
while true {
    let end = try handle.seekToEnd()
    if end < offset {
        offset = 0
        pending.removeAll(keepingCapacity: true)
    }
    if end > offset {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: Int(end - offset)) ?? Data()
        offset = end
        consume(data, pending: &pending)
    }
    Thread.sleep(forTimeInterval: 0.2)
}
