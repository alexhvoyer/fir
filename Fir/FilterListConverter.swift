import Foundation

/// Turns Adblock Plus filter lists (EasyList, EasyPrivacy) into WebKit content-blocker rules.
/// Covers the common subset: host and path patterns with type, party and domain options, site
/// exceptions, and element hiding. Rules WebKit can't express are skipped, not approximated.
enum FilterListConverter {
    struct Output {
        var network: [[String: Any]] = []
        var hiding: [[String: Any]] = []
        var exceptions: [[String: Any]] = []

        /// Exceptions last: `ignore-previous-rules` only undoes rules listed before it.
        func rules(includeHiding: Bool) -> [[String: Any]] {
            network + (includeHiding ? hiding : []) + exceptions
        }
    }

    static func convert(_ lists: [String]) -> Output {
        var output = Output()
        var genericSelectors: [String] = []
        var siteSelectors: [String: [String]] = [:]
        for list in lists {
            for line in list.split(whereSeparator: \.isNewline) {
                let line = line.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }
                if let range = line.range(of: "##") {
                    // WebKit rejects a whole list over one domain that isn't lowercase.
                    let domains = String(line[..<range.lowerBound]).lowercased()
                    let selector = String(line[range.upperBound...])
                    guard isPlainSelector(selector), !domains.contains("#") else { continue }
                    if domains.isEmpty {
                        genericSelectors.append(selector)
                    } else {
                        let sites = domains.split(separator: ",").map(String.init)
                        // Exclusions (`~site`) can't narrow a list-wide rule here; skip those.
                        guard sites.allSatisfy({ !$0.hasPrefix("~") && isASCII($0) }) else { continue }
                        siteSelectors[sites.sorted().joined(separator: ","), default: []].append(selector)
                    }
                } else if line.contains("#@#") || line.contains("#?#") || line.contains("#$#") || line.contains("#%#") {
                    continue
                } else if let rule = networkRule(line) {
                    if rule.isException { output.exceptions.append(rule.json) } else { output.network.append(rule.json) }
                }
            }
        }
        // Large selector lists in one rule are fine for WebKit; chunks keep one bad selector's damage small.
        for chunk in stride(from: 0, to: genericSelectors.count, by: 250) {
            let selectors = genericSelectors[chunk..<min(chunk + 250, genericSelectors.count)]
            output.hiding.append(hide(selectors.joined(separator: ", "), domains: nil))
        }
        for (sites, selectors) in siteSelectors {
            output.hiding.append(hide(selectors.joined(separator: ", "), domains: sites.split(separator: ",").map { "*\($0)" }))
        }
        return output
    }

    private static func hide(_ selector: String, domains: [String]?) -> [String: Any] {
        var trigger: [String: Any] = ["url-filter": ".*"]
        if let domains { trigger["if-domain"] = domains }
        return ["trigger": trigger, "action": ["type": "css-display-none", "selector": selector]]
    }

    /// Extended syntax (procedural selectors) isn't CSS; one such selector fails the whole list.
    private static func isPlainSelector(_ selector: String) -> Bool {
        let extended = [":-abp-", ":has", ":contains", ":xpath", ":matches-", ":upward", ":remove", ":style",
                        ":nth-ancestor", ":min-text", ":watch-attr", "[-ext-", ":others", ":if"]
        return !selector.isEmpty && isASCII(selector) && !extended.contains { selector.contains($0) }
    }

    private static func isASCII(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy(\.isASCII)
    }

    private static let resourceTypes: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "style-sheet", "font": "font", "media": "media",
        "xmlhttprequest": "raw", "websocket": "raw", "ping": "ping", "other": "other", "popup": "popup",
    ]

    private static func networkRule(_ line: String) -> (json: [String: Any], isException: Bool)? {
        var text = Substring(line)
        let isException = text.hasPrefix("@@")
        if isException { text = text.dropFirst(2) }
        var options: [Substring] = []
        if let dollar = text.lastIndex(of: "$"), !text[text.index(after: dollar)...].contains("/") {
            options = text[text.index(after: dollar)...].split(separator: ",")
            text = text[..<dollar]
        }
        // Regex filters use syntax WebKit's url-filter doesn't support.
        if text.hasPrefix("/") && text.hasSuffix("/") && text.count > 2 { return nil }

        var trigger: [String: Any] = [:]
        var types: [String] = []
        var childFrame = false
        var siteException = false
        for option in options {
            let option = option.lowercased()
            switch option {
            case "third-party", "3p": trigger["load-type"] = ["third-party"]
            case "~third-party", "1p", "first-party": trigger["load-type"] = ["first-party"]
            case "subdocument": childFrame = true
            case "document", "elemhide", "ehide":
                // Blocking whole pages isn't wanted; as an exception it allowlists a site.
                guard isException else { return nil }
                siteException = true
            case "match-case", "important", "all": continue
            default:
                if option.hasPrefix("domain=") {
                    let domains = option.dropFirst("domain=".count).split(separator: "|")
                    let positive = domains.filter { !$0.hasPrefix("~") }.map { "*\($0)" }
                    let negative = domains.filter { $0.hasPrefix("~") }.map { "*\($0.dropFirst())" }
                    guard (positive + negative).allSatisfy(isASCII) else { return nil }
                    // WebKit takes one of the two lists per rule.
                    if !positive.isEmpty { trigger["if-domain"] = positive } else if !negative.isEmpty { trigger["unless-domain"] = negative }
                } else if let type = resourceTypes[option] {
                    types.append(type)
                } else {
                    // Negated types, redirects, CSP and other options WebKit can't express.
                    return nil
                }
            }
        }

        if siteException {
            // `@@||site^$document`: leave the whole site alone.
            guard text.hasPrefix("||"), let host = text.dropFirst(2).split(whereSeparator: { "^/*".contains($0) }).first,
                  isASCII(String(host)) else { return nil }
            return (["trigger": ["url-filter": ".*", "if-domain": ["*\(host.lowercased())"]], "action": ["type": "ignore-previous-rules"]], true)
        }
        guard let filter = urlFilter(String(text)) else { return nil }
        trigger["url-filter"] = filter
        if childFrame {
            if types.isEmpty { types = ["document"]; trigger["load-context"] = ["child-frame"] }
        }
        if !types.isEmpty { trigger["resource-type"] = Array(Set(types)).sorted() }
        return (["trigger": trigger, "action": ["type": isException ? "ignore-previous-rules" : "block"]], isException)
    }

    /// ABP pattern to WebKit's regex subset (no alternation): `||` anchors a host, `^` a separator.
    private static func urlFilter(_ pattern: String) -> String? {
        var pattern = Substring(pattern)
        var regex = ""
        if pattern.hasPrefix("||") {
            regex = "^[^:]+://+([^:/]+\\.)?"
            pattern = pattern.dropFirst(2)
        } else if pattern.hasPrefix("|") {
            regex = "^"
            pattern = pattern.dropFirst()
        }
        let isHost = regex.hasPrefix("^[^:]") && !pattern.contains("/")
        var anchoredEnd = false
        if pattern.hasSuffix("|") {
            anchoredEnd = true
            pattern = pattern.dropLast()
        }
        let body = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        guard body.count >= 3, isASCII(body) else { return nil }
        for (index, char) in pattern.enumerated() {
            switch char {
            case "*": regex += ".*"
            // A trailing separator also matches the end of the URL, which WebKit can't say without
            // alternation; after a bare host, a URL always continues with `/` or `:port`.
            case "^":
                if index < pattern.count - 1 { regex += "[/:?=&]" } else if isHost { regex += "[/:]" }
            case ".", "+", "?", "(", ")", "[", "]", "{", "}", "\\", "$", "|": regex += "\\\(char)"
            default: regex.append(char)
            }
        }
        if anchoredEnd { regex += "$" }
        return regex
    }

    static func json(_ rules: [[String: Any]]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: rules) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
