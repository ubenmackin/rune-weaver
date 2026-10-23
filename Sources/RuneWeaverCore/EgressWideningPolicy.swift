// Rune Weaver Core — Shared egress widening suffixes.

import Foundation

/// Single owner of the multi-part public-suffix table both Swift widening
/// guards and the dashboard mirror pin against.
public enum EgressWideningPolicy: Sendable {
    /// Suffixes that never base a wildcard widening on their own.
    public static let multiPartPublicSuffixes: Set<String> = [
        "co.uk", "org.uk", "gov.uk", "ac.uk", "me.uk", "net.uk",
        "ltd.uk", "plc.uk", "sch.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au",
        "asn.au", "id.au",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
        "ed.jp", "gr.jp", "lg.jp",
        "co.nz", "net.nz", "org.nz",
        "ac.nz",
        "com.br", "net.br", "org.br",
        "gov.br", "edu.br",
        "co.in", "net.in", "org.in",
        "firm.in", "gen.in", "ind.in",
        "com.sg", "com.hk", "co.kr", "co.za",
        "net.sg", "org.sg", "edu.sg",
        "net.hk", "org.hk", "edu.hk",
        "net.za", "org.za",
        "com.mx", "com.ar", "com.tr", "com.tw",
        "com.cn", "net.cn", "org.cn",
        "gov.cn", "edu.cn",
        "net.mx", "org.mx", "edu.mx",
        "net.ar", "org.ar", "edu.ar", "gov.ar",
        "net.tr", "org.tr", "edu.tr", "gov.tr",
        "com.co", "com.do", "com.ec", "com.eg", "com.gt", "com.ly", "com.my", "com.ng",
        "com.pe", "com.ph", "com.pk", "com.py", "com.sv", "com.ua", "com.uy", "com.ve",
        "net.ly", "org.ly", "net.my", "org.my",
        "co.at", "co.id", "co.il", "co.ke", "co.th", "co.tz", "co.ug", "co.ve",
        "github.io", "gitlab.io", "vercel.app", "netlify.app",
        "github.dev", "githubusercontent.com", "googleusercontent.com",
        "herokuapp.com", "appspot.com", "blogspot.com",
        "wordpress.com", "tumblr.com", "myshopify.com",
        "azurewebsites.net", "cloudfront.net", "amazonaws.com",
        "s3.amazonaws.com", "elasticbeanstalk.com", "firebaseapp.com",
        "pages.dev", "web.app", "workers.dev", "deno.dev",
        "onrender.com", "fly.dev",
        "glitch.me", "replit.app", "repl.co", "repl.run", "supabase.co",
        "duckdns.org", "ngrok.io", "trycloudflare.com"
    ]

    /// Whether a canonical base can carry subdomain widening.
    public static func isWidenableScopeBase(_ base: String) -> Bool {
        guard base.contains(".") else {
            return false
        }
        if base == "localhost" || base.hasSuffix(".localhost") {
            return false
        }
        let labels = base.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, !labels.contains(where: \.isEmpty) else {
            return false
        }
        let lastTwo = "\(labels[labels.count - 2]).\(labels[labels.count - 1])"
        if multiPartPublicSuffixes.contains(lastTwo) {
            return labels.count >= 3
        }
        if SensitiveAddressParsing.canonicalIPv4Octets(base) != nil || base.contains(":") {
            return false
        }
        return !(labels.allSatisfy { $0.allSatisfy(\.isNumber) })
    }

    /// Whether a canonical host cannot carry `subdomains: true`.
    public static func isNonWidenableDomainBase(_ canonicalHost: String) -> Bool {
        !isWidenableScopeBase(canonicalHost)
    }
}
