import Foundation
import CloakKit

// MARK: - Anthropic Messages API body scrubbing
//
// The proxy receives a standard Anthropic /v1/messages request body. We must
// scrub every user-visible text field (system prompt + each message's text
// content, including tool_result text) while leaving the JSON STRUCTURE intact —
// dropping or renaming structural fields causes hard 400s. We walk the JSON,
// collect all scrubbable strings, scrub them with ONE shared SubstitutionMap
// (so a name maps to the same fake everywhere = coherent + cache-stable), and
// write the fakes back in place.

enum MessagesScrub {

    /// Scrub an Anthropic request body. Returns the rewritten body data and the
    /// SubstitutionMap to rehydrate the response with. On any parse failure we
    /// return the original bytes and an empty map (fail open on transport, never
    /// crash the user's session) — the regex backstop still ran on whatever we
    /// could parse.
    static func scrubRequestBody(_ data: Data, engine: ScrubEngine) async -> (Data, SubstitutionMap) {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (data, SubstitutionMap())
        }

        // 1) Gather every scrubbable string with a path back to its location.
        var collected = ""
        var pieces: [String] = []
        func note(_ s: String) {
            if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
            pieces.append(s)
            collected += s + "\n"
        }

        if let system = root["system"] as? String { note(system) }
        if let systemArr = root["system"] as? [[String: Any]] {
            for b in systemArr { if let t = b["text"] as? String { note(t) } }
        }
        if let messages = root["messages"] as? [[String: Any]] {
            for m in messages { collectText(from: m["content"], into: note) }
        }

        guard !pieces.isEmpty else { return (data, SubstitutionMap()) }

        // 2) Scrub the concatenation once, then reuse its map to rewrite each
        //    field. Scrubbing the concatenation gives the model full context and
        //    a single coherent fake namespace.
        let result: ScrubResult
        do {
            result = try await engine.scrub(collected)
        } catch {
            return (data, SubstitutionMap())
        }
        let map = result.map

        // 3) Rewrite each string in place using the shared map.
        if root["system"] is String, let s = root["system"] as? String {
            root["system"] = Substitution.apply(to: s, map: map)
        } else if var systemArr = root["system"] as? [[String: Any]] {
            for i in systemArr.indices {
                if let t = systemArr[i]["text"] as? String {
                    systemArr[i]["text"] = Substitution.apply(to: t, map: map)
                }
            }
            root["system"] = systemArr
        }
        if var messages = root["messages"] as? [[String: Any]] {
            for i in messages.indices {
                messages[i]["content"] = rewriteContent(messages[i]["content"], map: map)
            }
            root["messages"] = messages
        }

        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else {
            return (data, map)
        }
        return (out, map)
    }

    /// Recursively collect text from a message `content` (string, or array of
    /// blocks: text / tool_result whose content is text or nested blocks).
    private static func collectText(from content: Any?, into note: (String) -> Void) {
        if let s = content as? String { note(s); return }
        guard let blocks = content as? [[String: Any]] else { return }
        for b in blocks {
            let type = b["type"] as? String
            if type == "text", let t = b["text"] as? String { note(t) }
            else if type == "tool_result" { collectText(from: b["content"], into: note) }
            // tool_use input is structured JSON — left untouched in v0 (see README).
        }
    }

    private static func rewriteContent(_ content: Any?, map: SubstitutionMap) -> Any? {
        if let s = content as? String { return Substitution.apply(to: s, map: map) }
        guard var blocks = content as? [[String: Any]] else { return content }
        for i in blocks.indices {
            let type = blocks[i]["type"] as? String
            if type == "text", let t = blocks[i]["text"] as? String {
                blocks[i]["text"] = Substitution.apply(to: t, map: map)
            } else if type == "tool_result" {
                blocks[i]["content"] = rewriteContent(blocks[i]["content"], map: map)
            }
        }
        return blocks
    }
}
