import Foundation
import CloakKit

// MARK: - cloak CLI
//
//   cloak doctor            check on-device Foundation Model availability
//   cloak scrub [--json]    read text on stdin, print the scrubbed text
//                           (--json: full result for the eval harness)
//   cloak rehydrate         read "<mapping-json>\n---\n<text>" and reverse it
//   cloak proxy [--port N]  run the local Anthropic-compatible scrubbing proxy
//
// `scrub` is the eval hook (a deterministic stdin->JSON path), so the
// Python harness in evals/ can score detection recall + over-scrub reproducibly.

let argv = Array(CommandLine.arguments.dropFirst())
let cmd = argv.first ?? ""
let flags = Set(argv.dropFirst())

func readStdin() -> String {
    String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

func emitJSON(_ obj: Any) {
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
       let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}

switch cmd {
case "doctor":
    if let err = FoundationModelSpanFinder.availabilityError() {
        FileHandle.standardError.write(Data("✗ \(err)\n".utf8)); exit(1)
    }
    print("✓ on-device Foundation Model is available"); exit(0)

case "scrub":
    let input = readStdin()
    do {
        let result = try await ScrubEngine().scrub(input)
        if flags.contains("--json") {
            emitJSON([
                "scrubbed": result.scrubbed,
                "spans": result.spans.map { [
                    "text": $0.text, "fake": $0.fake, "category": $0.category,
                    "source": $0.source, "essential": $0.essential, "scrubbed": $0.scrubbed,
                ] },
                "mapping": result.map.fakeToReal,
            ])
        } else {
            print(result.scrubbed)
        }
        for w in result.warnings { FileHandle.standardError.write(Data("⚠ \(w)\n".utf8)) }
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1)
    }
    exit(0)

case "scrub-file":
    // cloak scrub-file <input> [output]
    // Scrub a txt/docx/pdf file; writes the scrubbed file + a sibling
    // <output>.cloakmap.json. Mirrors what the GUI does — used to test docx/pdf.
    let positional = argv.dropFirst().filter { !$0.hasPrefix("--") }
    guard let inPath = positional.first else {
        FileHandle.standardError.write(Data("usage: cloak scrub-file <input> [output]\n".utf8)); exit(2)
    }
    let inURL = URL(fileURLWithPath: inPath)
    do {
        let doc = try DocumentIO.readText(from: inURL)
        let result = try await ScrubEngine().scrub(doc.text)
        let outURL = positional.count > 1
            ? URL(fileURLWithPath: positional[1])
            : DocumentIO.suggestedOutputURL(for: doc)
        try DocumentIO.writeScrubbed(doc: doc, scrubbedFullText: result.scrubbed, map: result.map, to: outURL)
        // Save the mapping next to the output so `cloak rehydrate` can reverse it.
        let mapURL = outURL.deletingPathExtension().appendingPathExtension("cloakmap.json")
        let mapData = try JSONSerialization.data(withJSONObject: result.map.fakeToReal, options: [.prettyPrinted, .sortedKeys])
        try mapData.write(to: mapURL)
        let kept = result.spans.filter { !$0.scrubbed }.count
        let msg = "✓ \(doc.kind.rawValue): scrubbed \(result.spans.count - kept) span(s), kept \(kept)\n"
            + "  → \(outURL.path)\n  → \(mapURL.path)\n"
        FileHandle.standardError.write(Data(msg.utf8))
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1)
    }
    exit(0)

case "rehydrate":
    // Input: a JSON object {fake: real, ...}, then a line "---", then the text.
    let raw = readStdin()
    guard let sep = raw.range(of: "\n---\n") else {
        FileHandle.standardError.write(Data("expected '<mapping-json>\\n---\\n<text>'\n".utf8)); exit(2)
    }
    let mapJSON = String(raw[..<sep.lowerBound])
    let text = String(raw[sep.upperBound...])
    guard let data = mapJSON.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
        FileHandle.standardError.write(Data("invalid mapping JSON\n".utf8)); exit(2)
    }
    let map = SubstitutionMap()
    for (fake, real) in dict { _ = map.adopt(fake: fake, real: real) }
    let r = StreamingRehydrator(map: map)
    var out = r.feed(text); out += r.flush()
    print(out); exit(0)

case "proxy":
    var port = 8765
    if let idx = argv.firstIndex(of: "--port"), idx + 1 < argv.count, let p = Int(argv[idx + 1]) {
        port = p
    }
    await Proxy(port: UInt16(port)).run()   // never returns
    exit(0)

default:
    print("""
    cloak — local PII-scrubbing proxy for cloud LLMs, on Apple Foundation Models

    usage:
      cloak doctor             check on-device model availability
      cloak scrub [--json]     scrub stdin text (--json for eval output)
      cloak rehydrate          reverse a scrub given its mapping
      cloak proxy [--port N]   run the Anthropic-compatible scrubbing proxy

    proxy setup:
      export ANTHROPIC_API_KEY=sk-ant-...     # held by the proxy, never sent raw to the model
      cloak proxy --port 8765 &
      ANTHROPIC_BASE_URL=http://localhost:8765 claude
    """)
    exit(cmd.isEmpty ? 0 : 1)
}
