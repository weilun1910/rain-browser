import Foundation

/// Rules for Chrome history: what gets imported at all, and what is safe to fetch.
enum URLFilter {
    enum ImportDecision: Equatable {
        case importIt
        case skip(String)
    }

    enum FetchDecision: Equatable {
        case fetch
        case skip(String)
    }

    /// Words that suggest a URL does something when loaded (sign-in links, unsubscribe,
    /// OAuth callbacks). Long words match anywhere in the path or query.
    static let sensitiveSubstrings = [
        "token", "unsubscribe", "confirm", "verify", "magic", "login", "signin", "sign-in", "sign_in",
        "logout", "signout", "sign-out", "oauth", "callback", "reset", "invite", "password", "session", "auth",
    ]
    /// Short words would match inside ordinary words ("inside", "keyboard", "decode"),
    /// so they match whole URL tokens, including camelCase and snake_case parts.
    static let sensitiveTokens: Set<String> = ["code", "key", "sid", "otp", "jwt", "sig", "signature", "nonce", "ticket"]

    static let loggedInDomains = [
        "mail.google.com", "docs.google.com", "drive.google.com", "calendar.google.com", "meet.google.com",
        "keep.google.com", "photos.google.com", "contacts.google.com", "myaccount.google.com", "accounts.google.com",
        "notion.so", "notion.com", "linkedin.com", "facebook.com", "instagram.com", "messenger.com", "x.com",
        "twitter.com", "slack.com", "discord.com", "web.whatsapp.com", "web.telegram.org", "figma.com", "canva.com",
        "chatgpt.com", "chat.openai.com", "claude.ai", "gemini.google.com", "outlook.live.com", "outlook.office.com",
        "outlook.office365.com", "office.com", "teams.microsoft.com", "zoom.us", "apollo.io", "hubspot.com",
        "salesforce.com", "myworkdayjobs.com", "workday.com", "joinhandshake.com", "app.joinhandshake.com",
        "icloud.com", "appleid.apple.com", "developer.apple.com/account", "github.com/settings",
        "airtable.com", "asana.com", "trello.com", "monday.com", "clickup.com", "linear.app", "granola.ai",
        "dropbox.com", "box.com", "amazon.com/gp", "netflix.com", "spotify.com",
    ]
    static let loggedInHostPrefixes = [
        "app.", "dashboard.", "console.", "admin.", "portal.", "my.", "account.", "accounts.", "login.",
        "auth.", "sso.", "id.", "secure.", "signin.", "billing.",
    ]

    static func hostMatches(_ host: String, _ domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    static func isSearchPage(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        let q = url.query?.lowercased() ?? ""
        let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if bareHost.hasPrefix("google.") && (path.hasPrefix("/search") || path == "/url" || path.hasPrefix("/webhp")) { return true }
        if bareHost == "bing.com" && path.hasPrefix("/search") { return true }
        if bareHost == "duckduckgo.com" && q.contains("q=") { return true }
        if bareHost == "search.yahoo.com" || bareHost == "search.brave.com" { return true }
        if bareHost == "kagi.com" && path.hasPrefix("/search") { return true }
        if bareHost == "perplexity.ai" && path.hasPrefix("/search") { return true }
        if bareHost == "youtube.com" && path.hasPrefix("/results") { return true }
        if bareHost == "ecosia.org" && path.hasPrefix("/search") { return true }
        return false
    }

    static func isLocalOrIP(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") || h.hasSuffix(".test") || h.hasSuffix(".internal") { return true }
        if h.contains(":") { return true } // IPv6 literal
        let parts = h.split(separator: ".")
        if parts.count == 4 && parts.allSatisfy({ UInt8($0) != nil }) { return true }
        if !h.contains(".") { return true } // intranet single-label names
        return false
    }

    /// Decides whether a history row enters the index at all (title and URL only).
    static func importDecision(_ url: URL, settings: AppSettings) -> ImportDecision {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return .skip("not a web page") }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return .skip("not a web page") }
        if settings.isExcluded(host: host) { return .skip("on the exclude list") }
        if isSearchPage(url) { return .skip("search results page") }
        return .importIt
    }

    /// URL path and query split into lowercase tokens, including camelCase parts.
    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var prevLower = false
        for ch in s {
            if ch.isLetter || ch.isNumber {
                if ch.isUppercase && prevLower && !cur.isEmpty { out.append(cur.lowercased()); cur = "" }
                cur.append(ch)
                prevLower = ch.isLowercase || ch.isNumber
            } else {
                if !cur.isEmpty { out.append(cur.lowercased()); cur = "" }
                prevLower = false
            }
        }
        if !cur.isEmpty { out.append(cur.lowercased()) }
        return out
    }

    static func looksLikeToken(_ s: String) -> Bool {
        // Long runs of mixed letters and digits are usually one-time tokens or ids.
        var run = 0, digits = 0, letters = 0
        for ch in s {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" {
                run += 1
                if ch.isNumber { digits += 1 } else if ch.isLetter { letters += 1 }
                if run >= 32 && digits >= 4 && letters >= 4 { return true }
            } else {
                run = 0; digits = 0; letters = 0
            }
        }
        return false
    }

    /// Decides whether it's safe to GET the page without cookies to read its text.
    static func fetchDecision(_ url: URL, visitCount: Int) -> FetchDecision {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return .skip("not a web page") }
        guard let host = url.host?.lowercased() else { return .skip("not a web page") }
        if isLocalOrIP(host) { return .skip("local or IP address") }
        if visitCount < 2 { return .skip("visited only once") }
        let pathAndHost = host + url.path.lowercased()
        for d in loggedInDomains {
            if d.contains("/") {
                if pathAndHost.hasPrefix(d) || pathAndHost.hasPrefix("www." + d) { return .skip("logged-in app") }
            } else if hostMatches(host, d) {
                return .skip("logged-in app")
            }
        }
        for p in loggedInHostPrefixes where host.hasPrefix(p) { return .skip("logged-in app") }
        let pathQuery = (url.path + "?" + (url.query ?? "")).lowercased()
        let raw = url.path + "?" + (url.query ?? "")
        for w in sensitiveSubstrings where pathQuery.contains(w) { return .skip("sensitive word: \(w)") }
        for t in tokens(raw) {
            for w in sensitiveTokens where t == w || (t.count > w.count && t.hasSuffix(w) && w.count >= 3 && (w == "key" || w == "code")) {
                return .skip("sensitive word: \(w)")
            }
        }
        if looksLikeToken(raw) { return .skip("looks like a one-time token") }
        return .fetch
    }
}
