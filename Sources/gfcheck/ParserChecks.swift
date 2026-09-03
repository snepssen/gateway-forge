import Foundation
import GatewayCore

/// Checks that need nothing on disk: the parser, the variant resolver, the
/// liturgy guards, note frontmatter, and the RNG. Split out of main.swift, which
/// had grown to 2075 lines -- these are the suites that depend on no scanned
/// state at all, so they are also the ones that stay readable in isolation.
func runParserChecks(_ c: Check) {
// ---------------------------------------------------------------- parser
c.suite("parser")
do {
    let doc = try ScriptParser.parse("""
        @title    Test Session
        @level    F15
        @voice    snepssen
        @ending   stay
        @pan      right
        @seed     42

        say Settle back.
        pause 6
        level F21
        hold 300
        """)
    c.equal(doc.title, "Test Session", "title")
    c.equal(doc.level, "F15", "level")
    c.equal(doc.ending, "stay", "ending")
    c.expect(abs(doc.pan - 0.9) < 1e-9, "pan right maps to 0.9")
    c.equal(doc.steps.count, 4, "step count")
    c.equal(doc.steps[1].seconds, 6, "pause seconds")
    c.equal(doc.steps[2].text, "F21", "level step")
    c.equal(doc.steps[3].seconds, 300, "hold seconds")
} catch { c.expect(false, "header parse threw: \(error)") }

c.throwsError("directive after body is rejected") {
    try ScriptParser.parse("say hello\n@level F10") }
c.throwsError("unknown verb is rejected") { try ScriptParser.parse("wobble 3") }
c.throwsError("bad ending is rejected") { try ScriptParser.parse("@ending sideways") }
c.throwsError("unknown directive is rejected") { try ScriptParser.parse("@nonsense 1") }

// ---------------------------------------------------------------- variants
c.suite("variants")
do {
    let src = "@seed 1471\nsay {Settle back.|Ease all the way back.} {Nothing|Not a thing} to reach for."
    let a = try ScriptParser.parse(src), b = try ScriptParser.parse(src)
    c.equal(a.steps[0].text, b.steps[0].text, "same seed gives same wording")
    c.expect(!a.steps[0].text.contains("{"), "no braces survive")
    c.expect(!a.steps[0].text.contains("|"), "no pipes survive")

    var seen = Set<String>()
    for s in UInt64(0)..<40 {
        seen.insert(try ScriptParser.parse("@seed \(s)\nsay {a|b|c|d|e|f} one").steps[0].text)
    }
    c.expect(seen.count > 1, "different seeds can differ (got \(seen.count) distinct)")

    let nested = try ScriptParser.parse("@seed 7\nsay {a {b|c}|d} end")
    c.expect(!nested.steps[0].text.contains("{"), "nested groups fully resolve")
    c.expect(nested.steps[0].text.hasSuffix("end"), "text after the group survives")
} catch { c.expect(false, "variant parse threw: \(error)") }

// ---------------------------------------------------------------- fixed + protected
c.suite("fixed and protected")
c.throwsError("@fixed rejects variant groups") {
    try ScriptParser.parse("@fixed\nsay {a|b} affirmation") }
do {
    let doc = try ScriptParser.parse("@fixed\nsay I am more than my physical body.")
    c.equal(doc.steps[0].text, "I am more than my physical body.", "@fixed passes clean text")

    let p = try ScriptParser.parse("""
        @protected Energy Conversion Box, Resonant Tuning
        say Bring to mind your Energy Conversion Box.
        """)
    c.equal(ScriptParser.missingProtectedTerms(p), ["Resonant Tuning"], "missing term detected")
} catch { c.expect(false, "fixed/protected threw: \(error)") }

// ---------------------------------------------------------------- notes
c.suite("notes")
do {
    let n = Note(frontmatter: ["kind": "track", "focus": "F27"], body: "Drifted at the balloon.")
    let back = Note.parse(n.serialised())
    c.equal(back.frontmatter["kind"], "track", "frontmatter round-trips")
    c.equal(back.frontmatter["focus"], "F27", "second key round-trips")
    c.equal(back.body, "Drifted at the balloon.", "body round-trips")
    let bare = Note.parse("just a body")
    c.expect(bare.frontmatter.isEmpty, "no frontmatter is fine")
    c.equal(bare.body, "just a body", "bare body preserved")
}

// ---------------------------------------------------------------- rng
c.suite("rng")
var r1 = SplitMix64(seed: 99), r2 = SplitMix64(seed: 99)
c.equal((0..<5).map { _ in r1.next() }, (0..<5).map { _ in r2.next() }, "rng is deterministic")

}
