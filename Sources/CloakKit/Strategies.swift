import Foundation
import FoundationModels

// MARK: - Detection-harness strategies (the tournament)
//
// The regex fast-pass owns hard IDs; these strategies compete on the fuzzy
// contextual layer (names, orgs, codenames). Selected via CLOAK_STRATEGY
// (default "baseline"); scored by evals/harness.py --strategies a,b,c.
//
// Design constraint that shapes everything here: decoding is GREEDY, so
// re-running an identical prompt returns the identical output. Ensemble
// diversity must come from prompt/instruction VARIATION or input variation,
// never reruns — and determinism is a feature (stable evals, prompt-cache-
// stable output). Full specs: evals/tournament-specs.json.

extension FoundationModelSpanFinder {

    /// The shipping default. "dual-lens" won the harness tournament (2026-07-01):
    /// on the dev split, recall 0.828 -> 0.901 and leaks 13 -> 8 vs baseline;
    /// confirmed on the holdout split (0.744 -> 0.756, 10 -> 9 leaks). It unions
    /// the generalist pass with a narrow name-hunter pass, so it is a strict
    /// superset of baseline and can never regress it. Override via CLOAK_STRATEGY.
    /// See evals/TOURNAMENT.md.
    static let defaultStrategy = "dual-lens"

    static func activeStrategy() -> String {
        ProcessInfo.processInfo.environment["CLOAK_STRATEGY"] ?? defaultStrategy
    }

    /// Strategy dispatch. Unknown names fall back to baseline so an eval typo
    /// can never silently change behavior mid-tournament.
    static func run(strategy: String, on text: String, maxTokens: Int) async throws -> [PIISpan] {
        switch strategy {
        case "fewshot":            return try await runFewshot(text, maxTokens: maxTokens)
        case "dual-lens":          return try await runDualLens(text, maxTokens: maxTokens)
        case "enumerate-classify": return try await runEnumerateClassify(text, maxTokens: maxTokens)
        case "candidate-inject":   return try await runCandidateInject(text, maxTokens: maxTokens)
        case "residual-audit":     return try await runResidualAudit(text, maxTokens: maxTokens)
        default:                   return try await runBaseline(text, maxTokens: maxTokens)
        }
    }

    // MARK: shared plumbing

    /// One model pass: fresh session with `instructions`, greedy.
    static func rawPass(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: maxTokens)
        return try await session.respond(to: prompt, options: options).content
    }

    /// One model pass parsed into spans (all the defensive guards, verbatim
    /// check against `source` — always the ORIGINAL chunk).
    static func spanPass(instructions: String, prompt: String, source: String, maxTokens: Int) async throws -> [PIISpan] {
        let raw = try await rawPass(instructions: instructions, prompt: prompt, maxTokens: maxTokens)
        return parse(raw, source: source)
    }

    /// Union span lists, dedup by lowercased trimmed text; earlier lists win
    /// (kind + essential verdicts of the first occurrence are kept).
    static func union(_ lists: [[PIISpan]]) -> [PIISpan] {
        var seen = Set<String>()
        var out: [PIISpan] = []
        for list in lists {
            for s in list where seen.insert(s.text.lowercased().trimmingCharacters(in: .whitespaces)).inserted {
                out.append(s)
            }
        }
        return out
    }

    /// Well-known public products/companies/tech terms — a deterministic noise
    /// firewall for recall-focused passes (candidates only; the generalist pass
    /// can still flag these when the text ties them to the user).
    static let publicTechDenylist: Set<String> = [
        "slack", "zoom", "excel", "github", "gitlab", "google", "microsoft", "apple",
        "python", "java", "swift", "kubernetes", "docker", "aws", "azure", "gcp",
        "iphone", "ipad", "mac", "macos", "windows", "linux", "ubuntu", "chrome",
        "safari", "firefox", "jira", "confluence", "react", "node", "redis",
        "postgres", "postgresql", "mysql", "mongodb", "typescript", "javascript",
        "rust", "terraform", "datadog", "splunk", "figma", "notion", "dropbox",
        "gmail", "outlook", "teams", "word", "powerpoint", "keynote", "xcode",
        "api", "json", "oauth", "jwt", "http", "https", "sql", "html", "css",
    ]

    static let acronymStoplist: Set<String> = [
        "API", "HTTP", "HTTPS", "JSON", "XML", "SQL", "HTML", "CSS", "URL", "URI",
        "PDF", "CPU", "GPU", "RAM", "SSD", "SDK", "IDE", "CLI", "GUI", "FAQ",
        "ETA", "FYI", "ASAP", "PTO", "CEO", "CTO", "CFO", "COO", "VP", "HR", "IT",
        "QA", "OKR", "KPI", "MDM", "PII", "LLM", "AI", "UI", "UX", "SLA", "SSO",
        "CET", "PST", "EST", "UTC", "EMEA", "APAC", "TODO", "SIEM", "DNS", "CSV",
        "VAT", "HIPAA", "IBAN", "SSN", "GDPR",
    ]

    /// Common capitalized sentence-starters / calendar words that Tier-B
    /// candidate extraction must ignore.
    static let sentenceCommonStoplist: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "it", "we", "i", "you",
        "he", "she", "they", "my", "our", "his", "her", "their", "if", "in", "on",
        "for", "but", "and", "or", "so", "as", "at", "by", "to", "from", "with",
        "when", "while", "after", "before", "also", "please", "thanks", "thank",
        "hi", "hello", "hey", "draft", "write", "send", "email", "ping", "note",
        "status", "update", "meeting", "customer", "team", "sprint", "quick",
        "separately", "outline", "compare", "keep", "tone", "rewrite", "can",
        "do", "does", "is", "are", "was", "were", "will", "would", "should",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december", "ok", "god", "not",
    ]

    /// All group-1 captures of `pattern` in `text` (case-insensitive optional).
    static func captures(_ pattern: String, in text: String, caseInsensitive: Bool = false) -> [String] {
        let opts: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let rx = try? NSRegularExpression(pattern: pattern, options: opts) else { return [] }
        let ns = text as NSString
        return rx.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            for i in 1..<m.numberOfRanges where m.range(at: i).location != NSNotFound {
                return ns.substring(with: m.range(at: i))
            }
            return nil
        }
    }

    // MARK: baseline — the shipping single pass

    static func runBaseline(_ text: String, maxTokens: Int) async throws -> [PIISpan] {
        try await spanPass(instructions: instructions,
                           prompt: "Find all PII in the following text.\n\n--- TEXT ---\n\(text)",
                           source: text, maxTokens: maxTokens)
    }

    // MARK: fewshot — worked example targeting bare names + codenames (1 pass)

    static let fewshotInstructions = """
    You are a privacy scrubber. You are given a chunk of text that a user is about to send to a cloud AI service. Find every piece of personally identifying or sensitive information (PII) so it can be replaced with a realistic fake before it leaves the machine. The fake is later swapped back in the reply, so replacing a name does NOT harm the answer.

    Think in two steps: first ENUMERATE every candidate (real people's names, organizations/employers/clients, specific locations, job titles tied to a person, relationships like "my wife" or "my manager Dana", and named internal projects/products); then for each decide its kind and whether it is essential.

    Output format — ONE span per line, nothing else, no commentary, no numbering:
    <verbatim text> | <kind> | <essential>

    where <kind> is one of: person_name, organization, location, job_title, relationship, project_or_product, other_sensitive
    and <essential> is yes or no.

    ESSENTIAL is RARE. Default to no. Answer yes ONLY when the request is a factual/lookup question whose CORRECT answer depends on this exact real value — e.g. "what are the knife laws in Miami" (the city changes the legal answer), or "what does company X's public API return" (the real org changes the facts). For drafting, writing, summarizing, brainstorming, coding, or any task where a realistic stand-in would work just as well, essential is ALWAYS no. When unsure, answer no (scrub it).

    Worked example. Input:
    "My teammate Priya says the Larkspur rollout slipped, so our internal tool codenamed Copperfin is on hold. Also, what are the knife laws in Austin?"
    Correct output:
    Priya | person_name | no
    Larkspur | project_or_product | no
    Copperfin | project_or_product | no
    Austin | location | yes
    Note: Priya counts even as a bare first name with no last name. Larkspur and Copperfin are made-up internal codenames — flag any unfamiliar capitalized word used as the name of a project or tool ("the X rollout", "codenamed X", "our tool X"). Kubernetes or Python would NOT be flagged.

    Other rules:
    - Copy the span text VERBATIM from the input — same casing, no quotes, no paraphrase.
    - Bare first names are person_name even without a last name.
    - Prefer to over-detect real names, employers, and locations. When unsure whether something names a specific real entity, include it (with essential=no).
    - Do NOT flag generic words, common nouns, programming/technical terms, or well-known public product names that carry no personal information.
    - If there is no PII, output the single line: NONE
    """

    static func runFewshot(_ text: String, maxTokens: Int) async throws -> [PIISpan] {
        try await spanPass(instructions: fewshotInstructions,
                           prompt: "Find all PII in the following text.\n\n--- TEXT ---\n\(text)",
                           source: text, maxTokens: maxTokens)
    }

    // MARK: dual-lens — generalist pass A ∪ narrow name-hunter pass B (2 passes)

    static let nameHunterInstructions = """
    You are a name-hunter, the second pass of a privacy scrubber. A general pass has already run on this text; your ONLY job is to catch the specific things it tends to miss: bare first names, nicknames, and invented codenames for internal projects, products, tools, teams, or systems. The text is about to be sent to a cloud AI service; anything you flag is replaced with a realistic fake that is swapped back later, so flagging a name NEVER harms the answer.

    Work like this: scan the text and ENUMERATE every capitalized word or short capitalized phrase that is not just the ordinary start-of-sentence use of a common word. Then for EACH one decide: could this name a specific person, or be an invented codename for an internal project, product, tool, team, or system?

    Clues that it IS one (flag it):
    - It is a human first name standing alone, especially near words like "my colleague", "my manager", "asked", "said", "told me" — e.g. "Priya mentioned", "my coworker Tobin".
    - It follows a codename cue: "codenamed", "internal", "our tool", "the ... project/rollout/launch/migration/initiative".
    - It is an ordinary English noun used oddly as a proper name — e.g. "the Anvil rollout", "our Nimbus dashboard", "codenamed Redwood". Invented codenames look exactly like this.

    Clues that it is NOT one (leave it out):
    - It is a well-known public company, product, framework, language, or standard — e.g. Slack, Excel, GitHub, Python, Swift, Kubernetes, AWS, iPhone, Chrome, Jira.
    - It is a programming or technical term, a file/function/class name from code, a day, a month, or a generic role word.
    - It is only the capitalized first word of a sentence carrying its normal dictionary meaning.

    Output format — ONE span per line, nothing else, no commentary, no numbering:
    <verbatim text> | <kind> | no

    where <kind> is one of: person_name, organization, location, job_title, relationship, project_or_product, other_sensitive
    The third field is ALWAYS the word no.

    Other rules:
    - Copy the span text VERBATIM from the input — same casing, no quotes, no paraphrase. Flag the bare name itself ("Tobin", "Anvil"), not the sentence around it. Spans are short: one to three words.
    - When genuinely torn between "invented internal codename" and "public product", include it. When it is clearly public or purely technical, leave it out.
    - If nothing qualifies, output the single line: NONE
    """

    static func runDualLens(_ text: String, maxTokens: Int) async throws -> [PIISpan] {
        let passA = try await spanPass(instructions: instructions,
                                       prompt: "Find all PII in the following text.\n\n--- TEXT ---\n\(text)",
                                       source: text, maxTokens: maxTokens)
        let rawB = try await spanPass(instructions: nameHunterInstructions,
                                      prompt: "Hunt for person names, nicknames, and internal codenames that a general scrubber might have missed in the following text.\n\n--- TEXT ---\n\(text)",
                                      source: text, maxTokens: 512)
        // Pass-B-only guards: must start uppercase; essential forced no; public
        // tech denylist; drop if contained in (or containing) an A span.
        let aTexts = passA.map { $0.text.lowercased() }
        let passB: [PIISpan] = rawB.compactMap { s in
            guard let first = s.text.first, first.isUppercase else { return nil }
            let low = s.text.lowercased()
            if publicTechDenylist.contains(low) { return nil }
            if aTexts.contains(where: { $0.contains(low) || low.contains($0) }) { return nil }
            return PIISpan(text: s.text, kind: s.kind, essential: false)
        }
        return union([passA, passB])
    }

    // MARK: enumerate-classify — recall enumerator -> precision filter (2 passes)

    static let enumerateInstructions = """
    You are the candidate finder for a privacy scrubber. You are given a chunk of text that a user is about to send to a cloud AI service. Your ONLY job is to enumerate every word or short phrase that could possibly name a specific entity. You do NOT decide whether anything is PII — a second stage filters your list. Over-listing is correct and expected; missing a candidate is the only failure.

    List a candidate for:
    - Every capitalized word or capitalized multi-word phrase, including at the start of a sentence when it could be a name — but not sentence-starting common English words, days, months, or language names.
    - Every bare first name or nickname, especially one following words like colleague, manager, boss, friend, wife, husband, teammate, coworker, client ("my colleague Devon" — list Devon).
    - Every codename-like or invented-sounding word used as a name, even if it is also an ordinary English word ("codenamed Bluejay" — list Bluejay; "the Foundry rollout" — list Foundry).
    - Company, team, product, tool, project, and place names; quoted or backticked names; job titles tied to a person; and relationship phrases like "my wife" or "our CFO".

    Output format — ONE candidate per line, copied VERBATIM from the input (same casing, no quotes), nothing else: no commentary, no numbering, no classification, no duplicates. Each line must be a short span (at most 6 words), never a whole sentence or clause.

    Do NOT list plain verbs, numbers, generic common nouns, or generic technical terms (function, database, API, laptop) that could not name a specific entity.

    If nothing qualifies, output the single line: NONE
    """

    static let classifyInstructions = """
    You are a privacy scrubber. You are given a chunk of text that a user is about to send to a cloud AI service, plus a list of CANDIDATE spans that an earlier pass pulled from that text. For each candidate, decide whether it is personally identifying or sensitive information (PII) that should be replaced with a realistic fake before the text leaves the machine. The fake is later swapped back in the reply, so replacing a name does NOT harm the answer.

    KEEP a candidate when it names a specific real or internal entity: a real person's name — including a bare first name the text ties to a person ("my colleague Devon" — Devon is PII); an organization, employer, or client; a specific location; a job title tied to a person; a relationship like "my wife" or "my manager Dana"; or a named internal project, product, tool, or codename — an invented-sounding word used as a name ("codenamed Bluejay", "the Foundry rollout") is ALWAYS PII even when it is also an ordinary English word.

    DROP a candidate when it is a generic word, common noun, programming/technical term, or a well-known public product or company name used generically with no tie to the user ("GitHub" as the platform, "Python" the language). When unsure whether a candidate names a specific real or internal entity, KEEP it (with essential=no).

    Output format — ONE line per KEPT candidate, nothing else, no commentary, no numbering:
    <verbatim text> | <kind> | <essential>

    where <kind> is one of: person_name, organization, location, job_title, relationship, project_or_product, other_sensitive
    and <essential> is yes or no.

    ESSENTIAL is RARE. Default to no. Answer yes ONLY when the request is a factual/lookup question whose CORRECT answer depends on this exact real value — e.g. "what are the knife laws in Miami" (the city changes the legal answer), or "what does company X's public API return" (the real org changes the facts). For drafting, writing, summarizing, brainstorming, coding, or any task where a realistic stand-in would work just as well, essential is ALWAYS no. When unsure, answer no (scrub it).

    Other rules:
    - Copy the span text VERBATIM from the input — same casing, no quotes, no paraphrase.
    - Dropped candidates get no output line at all.
    - If you notice PII in the text that is missing from the candidate list, add it as an extra line in the same format.
    - If no candidate is PII and you find no missed PII, output the single line: NONE
    """

    /// Deterministic cue candidates (regex, no model). Returns (text, kind).
    static func cueCandidates(in text: String) -> [(String, PIIKind)] {
        var out: [(String, PIIKind)] = []
        var seen = Set<String>()
        func add(_ s: String, _ k: PIIKind) {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { return }
            if sentenceCommonStoplist.contains(t.lowercased()) { return }
            out.append((t, k))
        }
        for c in captures(#"\b(?:my|our)\s+(?:colleague|coworker|teammate|manager|boss|friend|wife|husband|partner|client|assistant|neighbor|report|intern)\s+([A-Z][a-z]+)\b"#, in: text, caseInsensitive: false) {
            add(c, .personName)
        }
        for c in captures(#"\bcode-?named?\s+([A-Z][A-Za-z0-9]+)\b"#, in: text, caseInsensitive: true) {
            add(c, .projectOrProduct)
        }
        for c in captures(#"\b(?:project|initiative)\s+([A-Z][A-Za-z0-9]+)\b"#, in: text) {
            add(c, .projectOrProduct)
        }
        for c in captures(#"\bthe\s+([A-Z][a-z]+)\s+(?:rollout|launch|migration|initiative|release|program|deadline)\b"#, in: text) {
            add(c, .projectOrProduct)
        }
        return out
    }

    static func runEnumerateClassify(_ text: String, maxTokens: Int) async throws -> [PIISpan] {
        // Pass 1: enumerate candidates (one per line, no classification).
        let raw = try await rawPass(instructions: enumerateInstructions,
                                    prompt: "List every candidate entity name in the following text.\n\n--- TEXT ---\n\(text)",
                                    maxTokens: 512)
        var candidates: [String] = []
        var seen = Set<String>()
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.uppercased() == "NONE" { continue }
            guard text.contains(t), t.count <= 64,
                  t.split(separator: " ").count <= 6,
                  !t.contains("?"), !t.contains("!") else { continue }
            if seen.insert(t.lowercased()).inserted { candidates.append(t) }
        }
        // Cue augmentation (regex, deterministic) — cues go first, force-kept later.
        let cues = cueCandidates(in: text)
        var merged: [String] = []
        var mseen = Set<String>()
        for (c, _) in cues where mseen.insert(c.lowercased()).inserted { merged.append(c) }
        for c in candidates where mseen.insert(c.lowercased()).inserted { merged.append(c) }
        // Cap: 40 entries / 600 chars.
        var capped: [String] = []
        var chars = 0
        for c in merged {
            if capped.count >= 40 || chars + c.count > 600 { break }
            capped.append(c); chars += c.count + 1
        }

        // Pass 2: classify.
        let candidateBlock = capped.isEmpty ? "(none found)" : capped.joined(separator: "\n")
        let classified = try await spanPass(
            instructions: classifyInstructions,
            prompt: "Decide which of these candidates are PII in the following text.\n\n--- CANDIDATES ---\n\(candidateBlock)\n\n--- TEXT ---\n\(text)",
            source: text, maxTokens: maxTokens)

        // Fallback: a garbage/empty classify pass with real candidates present
        // must not silently drop everything — fall back to the baseline pass.
        if classified.isEmpty && !capped.isEmpty && cues.isEmpty {
            return try await runBaseline(text, maxTokens: maxTokens)
        }
        // Force-keep cue candidates (regex-anchored, tiny set) the model dropped.
        let cueSpans = cues.map { PIISpan(text: $0.0, kind: $0.1, essential: false) }
        return union([classified, cueSpans])
    }

    // MARK: candidate-inject — deterministic scanner feeds one model pass (1 pass)

    static let candidateInjectInstructions = """
    You are a privacy scrubber. You are given a chunk of text that a user is about to send to a cloud AI service. Find every piece of personally identifying or sensitive information (PII) so it can be replaced with a realistic fake before it leaves the machine. The fake is later swapped back in the reply, so replacing a name does NOT harm the answer.

    After the text you will see a CANDIDATES section: a list of possible names found by a simple mechanical scanner. The scanner over-generates, so many candidates are innocent. For EVERY candidate, decide: does it name a real person, an organization/employer/client, a specific location, a job title tied to a person, a relationship, or an internal project/product/tool codename? If yes, it MUST appear in your output. If it is a generic word, a well-known public technical term, or a false alarm, skip it silently — never output rejected candidates and never write commentary about the candidate list. Bare first names (like "Devon") and invented codenames (like "Bluejay" or "Foundry") ARE PII: when a candidate is used in the text as a person's name or as the name of an internal project or tool, include it even if it looks like an ordinary English word. The candidate list is only a hint — also report any PII the scanner missed (real people's names, organizations/employers/clients, specific locations, job titles tied to a person, relationships like "my wife" or "my manager Dana", and named internal projects/products).

    Output format — ONE span per line, nothing else, no commentary, no numbering:
    <verbatim text> | <kind> | <essential>

    where <kind> is one of: person_name, organization, location, job_title, relationship, project_or_product, other_sensitive
    and <essential> is yes or no.

    ESSENTIAL is RARE. Default to no. Answer yes ONLY when the request is a factual/lookup question whose CORRECT answer depends on this exact real value — e.g. "what are the knife laws in Miami" (the city changes the legal answer), or "what does company X's public API return" (the real org changes the facts). For drafting, writing, summarizing, brainstorming, coding, or any task where a realistic stand-in would work just as well, essential is ALWAYS no. When unsure, answer no (scrub it).

    Other rules:
    - Copy the span text VERBATIM from the input — same casing, no quotes, no paraphrase. Output only the entity itself, never the sentence around it.
    - Prefer to over-detect real names, employers, and locations. When unsure whether something names a specific real entity, include it (with essential=no).
    - Do NOT flag generic words, common nouns, programming/technical terms, or well-known public product names that carry no personal information — even when they appear in the candidate list.
    - If there is no PII, output the single line: NONE
    """

    /// The mechanical scanner: Tier A trigger patterns (bypass stoplists) +
    /// Tier B capitalized spans (stoplists apply). Pure string rules, no model.
    static func mechanicalCandidates(in text: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        let hardStop: Set<String> = ["i", "the", "a", "an", "this", "that", "it", "we", "they", "he", "she", "you", "ok", "god"]
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’"))
            guard t.count >= 2, !hardStop.contains(t.lowercased()), seen.insert(t.lowercased()).inserted else { return }
            out.append(t)
        }
        // Tier A — trigger patterns.
        for c in captures(#"\b(?:code-?named?|codename|dubbed|nicknamed|known as|called|named)\s+["“”'']?([A-Za-z][A-Za-z0-9'-]{2,})"#, in: text, caseInsensitive: true) { add(c) }
        for c in captures(#"\b(?:my|our|his|her|their)\s+(?:colleague|co-?worker|manager|boss|teammate|direct report|report|friend|wife|husband|partner|fianc[ée]e?|girlfriend|boyfriend|brother|sister|mom|mother|dad|father|son|daughter|cousin|aunt|uncle|neighbor|roommate|client|customer|vendor|recruiter|mentor|mentee|intern|assistant|doctor|dentist|therapist|lawyer|accountant|landlord)\s+([A-Z][a-z’'-]+)"#, in: text) { add(c) }
        for c in captures(#"\b([A-Z][a-z’'-]+)\s+(?:said|says|asked|asks|told|mentioned|replied|wrote|emailed|messaged|pinged|slacked|suggested|reported|thinks|wants|joined|left|approved|confirmed|flagged|owns)\b"#, in: text) { add(c) }
        for c in captures(#"\b(?:the|our|this)\s+([A-Z][A-Za-z0-9'-]+)\s+(?:project|rollout|launch|initiative|migration|release|beta|pilot|program|effort|integration|deadline|demo|sprint|repo|service|tool|app|dashboard|cutover)\b"#, in: text) { add(c) }
        for c in captures(#"\b(?:project|initiative|operation|team|squad|repo)\s+([A-Z][A-Za-z0-9'-]+)"#, in: text) { add(c) }
        for c in captures(#"\b(?:Mr|Mrs|Ms|Mx|Dr|Prof)\.?\s+([A-Z][a-z’'-]+(?:\s+[A-Z][a-z’'-]+)?)"#, in: text) { add(c) }
        for c in captures(#"["“'']([A-Z][A-Za-z0-9'-]{2,})["”'']"#, in: text) { add(c) }

        // Tier B — general capitalized spans, stoplists + sentence-start rule.
        let ns = text as NSString
        guard let tokenRx = try? NSRegularExpression(pattern: #"[A-Za-z0-9'’-]+"#) else { return out }
        let tokens = tokenRx.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var i = 0
        while i < tokens.count {
            let word = ns.substring(with: tokens[i].range)
            if isTierBEligible(word) {
                // Sentence-start guard: preceded by ., !, ?, newline, or is first
                // token — skip if the lowercased word is a common English word.
                let start = tokens[i].range.location
                let before = start == 0 ? "." : ns.substring(with: NSRange(location: max(0, start - 2), length: min(2, start)))
                let atSentenceStart = start == 0 || before.contains(".") || before.contains("!") || before.contains("?") || before.contains("\n") || before.contains(":")
                if atSentenceStart && sentenceCommonStoplist.contains(word.lowercased()) { i += 1; continue }
                if publicTechDenylist.contains(word.lowercased()) { i += 1; continue }
                // Merge consecutive eligible tokens (max 3) into one span.
                var parts = [word]
                var j = i + 1
                while j < tokens.count, parts.count < 3 {
                    let next = ns.substring(with: tokens[j].range)
                    let gap = NSRange(location: tokens[j - 1].range.upperBound,
                                      length: tokens[j].range.location - tokens[j - 1].range.upperBound)
                    guard ns.substring(with: gap) == " ", isTierBEligible(next),
                          !publicTechDenylist.contains(next.lowercased()) else { break }
                    parts.append(next); j += 1
                }
                add(parts.joined(separator: " "))
                i = j
            } else {
                i += 1
            }
        }
        return out
    }

    private static func isTierBEligible(_ w: String) -> Bool {
        if w.range(of: #"^[A-Z][a-z’'-]{2,}$"#, options: .regularExpression) != nil { return true }
        if w.range(of: #"^[A-Z][a-z]+[A-Z][A-Za-z0-9]*$"#, options: .regularExpression) != nil { return true }
        if w.range(of: #"^[A-Z]{3,10}$"#, options: .regularExpression) != nil {
            return !acronymStoplist.contains(w)
        }
        return false
    }

    static func runCandidateInject(_ text: String, maxTokens: Int) async throws -> [PIISpan] {
        var candidates = mechanicalCandidates(in: text)
        // Same budget cap as enumerate-classify.
        var capped: [String] = []
        var chars = 0
        for c in candidates {
            if capped.count >= 40 || chars + c.count > 600 { break }
            capped.append(c); chars += c.count + 1
        }
        candidates = capped
        let block = candidates.isEmpty ? "(none)" : candidates.joined(separator: "\n")
        return try await spanPass(
            instructions: candidateInjectInstructions,
            prompt: "Find all PII in the following text. After the text is a CANDIDATES list from a mechanical scanner — make a decision on every candidate, and also find PII the scanner missed.\n\n--- TEXT ---\n\(text)\n\n--- CANDIDATES ---\n\(block)",
            source: text, maxTokens: maxTokens)
    }

    // MARK: residual-audit — detect, redact, then audit the residual (2 passes)

    static let residualPass1Instructions = """
    You are a privacy scrubber. You are given a chunk of text that a user is about to send to a cloud AI service. Find every piece of personally identifying or sensitive information (PII) so it can be replaced with a realistic fake before it leaves the machine. The fake is later swapped back in the reply, so replacing a name does NOT harm the answer.

    Think in two steps: first ENUMERATE every candidate (real people's names — including BARE FIRST NAMES, a person referred to by a single first name like a coworker mentioned in passing; organizations/employers/clients; specific locations; job titles tied to a person; relationships like "my wife" or "my manager Dana"; and named internal projects/products — including CODENAMES, invented names for internal tools, projects, features, teams, or releases, even when the name is also an ordinary English word like a bird, a metal, or a place); then for each decide its kind and whether it is essential.

    Output format — ONE span per line, nothing else, no commentary, no numbering:
    <verbatim text> | <kind> | <essential>

    where <kind> is one of: person_name, organization, location, job_title, relationship, project_or_product, other_sensitive
    and <essential> is yes or no.

    ESSENTIAL is RARE. Default to no. Answer yes ONLY when the request is a factual/lookup question whose CORRECT answer depends on this exact real value — e.g. "what are the knife laws in Miami" (the city changes the legal answer), or "what does company X's public API return" (the real org changes the facts). For drafting, writing, summarizing, brainstorming, coding, or any task where a realistic stand-in would work just as well, essential is ALWAYS no. When unsure, answer no (scrub it).

    Other rules:
    - Copy the span text VERBATIM from the input — same casing, no quotes, no paraphrase.
    - Prefer to over-detect real names, employers, and locations. When unsure whether something names a specific real entity, include it (with essential=no).
    - Do NOT flag generic words, common nouns, programming/technical terms, or well-known public product names that carry no personal information.
    - If there is no PII, output the single line: NONE
    """

    static let residualAuditInstructions = """
    You are a second-line privacy auditor. A first-pass scrubbing tool has already processed a chunk of text that a user is about to send to a cloud AI service. Everything the tool caught has been replaced with a marker like [[person_name]] or [[organization]]. Your ONLY job is to find identifying information the tool MISSED — the un-redacted remainder is exactly what will leave the machine, so a single miss is a privacy leak.

    The tool is reliable on obvious full names and well-known companies, but it is known to miss:
    - BARE FIRST NAMES: a person referred to by only a first name ("Devon asked", "ping Priya"), especially next to words like colleague, manager, teammate, boss, friend, wife, husband — or directly beside an existing [[...]] marker.
    - INTERNAL CODENAMES: invented names for internal projects, tools, features, teams, or releases ("codenamed X", "the X rollout", "the X migration", "Project X"), even when the name is also an ordinary English word like a bird, a metal, or a place.
    - Employers, clients, team names, specific locations, and job titles tied to a person that slipped through.

    Read the text and list ONLY the missed items. Never list a [[...]] marker itself.

    Output format — ONE span per line, nothing else, no commentary, no numbering:
    <verbatim text> | <kind> | <essential>

    where <kind> is one of: person_name, organization, location, job_title, relationship, project_or_product, other_sensitive
    and <essential> is yes or no.

    ESSENTIAL is RARE. Default to no. Answer yes ONLY when the request is a factual/lookup question whose CORRECT answer depends on this exact real value — e.g. "what are the knife laws in Miami" (the city changes the legal answer), or "what does company X's public API return" (the real org changes the facts). For drafting, writing, summarizing, brainstorming, coding, or any task where a realistic stand-in would work just as well, essential is ALWAYS no. When unsure, answer no (scrub it).

    Other rules:
    - Copy the span text VERBATIM from the input — same casing, no quotes, no paraphrase, and never include [[ or ]] inside a span.
    - A capitalized word is NOT automatically PII. Flag it only if the surrounding text treats it as a specific person, employer, place, team, or internal project.
    - Do NOT flag generic words, common nouns, programming/technical terms, month or day names, or well-known public product names (e.g. GitHub, Slack, iPhone) that carry no personal information.
    - If the tool missed nothing, output the single line: NONE
    """

    static func runResidualAudit(_ text: String, maxTokens: Int) async throws -> [PIISpan] {
        // Pass 1: hardened generalist.
        let pass1 = try await spanPass(instructions: residualPass1Instructions,
                                       prompt: "Find all PII in the following text.\n\n--- TEXT ---\n\(text)",
                                       source: text, maxTokens: maxTokens)
        // Build the redacted view: pass-1 spans + regex-layer hits -> [[kind]],
        // longest first, word-boundary replace. Pure function of pass-1 output.
        var redactions: [(String, String)] = pass1.map { ($0.text, "[[\($0.kind.rawValue)]]") }
        for hit in Detectors.scan(text) {
            redactions.append((hit.text, "[[\(hit.kind.rawValue)]]"))
        }
        var redacted = text
        for (target, marker) in redactions.sorted(by: { $0.0.count > $1.0.count }) {
            redacted = Substitution.boundaryReplace(in: redacted, target: target, with: marker)
        }

        // Pass 2: audit the residual. Verbatim guard runs against the ORIGINAL.
        let rawAudit = try await spanPass(
            instructions: residualAuditInstructions,
            prompt: "A privacy tool already redacted the text below. List every identifying item it MISSED.\n\n--- REDACTED TEXT ---\n\(redacted)",
            source: text, maxTokens: 512)

        // Gates on audit-only spans (noise firewall).
        let triggers = ["colleague", "manager", "teammate", "boss", "friend", "wife", "husband",
                        "partner", "coworker", "client", "codename", "codenamed", "named", "called",
                        "dubbed", "project", "rollout", "launch", "migration", "initiative", "team"]
        var audit: [PIISpan] = rawAudit.compactMap { s in
            if s.text.contains("[[") || s.text.contains("]]") { return nil }
            let low = s.text.lowercased()
            if publicTechDenylist.contains(low) { return nil }
            let hasUpper = s.text.contains(where: { $0.isUppercase })
            let relPrefix = ["my ", "our ", "his ", "her ", "their "].contains { low.hasPrefix($0) }
            guard hasUpper || relPrefix else { return nil }
            return s
        }
        // Runaway cap: if the audit floods, keep only trigger-proximate spans.
        let cap = max(8, 2 * pass1.count)
        if audit.count > cap {
            audit = audit.filter { s in
                guard let r = text.range(of: s.text) else { return false }
                let lo = text.index(r.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
                let hi = text.index(r.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
                let window = text[lo..<hi].lowercased()
                return triggers.contains { window.contains($0) } || window.contains("[[")
            }
        }
        // Union; pass 1 wins on duplicates/essential conflicts.
        return union([pass1, audit])
    }
}
