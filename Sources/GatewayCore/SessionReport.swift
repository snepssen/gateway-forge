import Foundation

/// One session, written down in the shape of GF Form 1 — the session report
/// the website offers at `docs/session-report.html`.
///
/// **The PDF this produces is the web form's PDF, byte for byte.** The owner's
/// requirement for the in-app journal's export: "match the web template 1:1".
/// So this is not a second design drawn to look alike. It is a line-for-line
/// port of the form's report core (the block between the `session-report
/// core` markers in that page's script), with the same constants, the same
/// arithmetic in the same order and the same number formatting. A parity check
/// runs the page's own JavaScript in Node and compares its bytes against
/// `library/reference/session-report-fixture.json`, which `gfcorpus` writes
/// from this file. Change one and the other must follow.
///
/// Every field is optional in the way the form's are: an empty string prints
/// "- NOT RECORDED -" rather than inventing a value.
public struct SessionReport: Sendable, Equatable, Codable {
    /// The body-feeling boxes, in the order the form draws them.
    public static let feelingOptions = ["Nothing", "Fell asleep", "Relaxed", "Energised", "Buzzing"]

    /// `YYYY-MM-DD`, local.
    public var date: String
    /// `HH:MM`, local.
    public var start: String
    public var end: String
    /// `F10`, or `other` for a level the list does not have.
    public var levelKey: String
    /// What the Focus-level cell prints: `F10 — Mind Awake, Body Asleep`.
    public var level: String
    public var title: String
    public var feelings: [String]
    public var otherOn: Bool
    public var otherText: String
    public var narrative: String

    public init(date: String = "", start: String = "", end: String = "",
                levelKey: String = "", level: String = "", title: String = "",
                feelings: [String] = [], otherOn: Bool = false,
                otherText: String = "", narrative: String = "") {
        self.date = date; self.start = start; self.end = end
        self.levelKey = levelKey; self.level = level; self.title = title
        self.feelings = feelings; self.otherOn = otherOn
        self.otherText = otherText; self.narrative = narrative
    }
}

extension SessionReport {
    /// A journal entry, as a report.
    ///
    /// The session's own times win: the date and start are when listening
    /// began, the end when it stopped. An entry written away from a tape has
    /// neither, so it is dated by when it was written and its times are left
    /// unrecorded rather than guessed.
    ///
    /// - Parameter levelName: the level's name from `levels.json`, if it has
    ///   one, so the cell reads `F10 — Mind Awake, Body Asleep`.
    public init(entry: JournalEntry, levelName: String?, timeZone: TimeZone = .current) {
        let day = entry.started ?? entry.written
        let level = entry.level.uppercased()
        let named = levelName.map { $0.isEmpty ? level : "\(level) — \($0)" } ?? level
        self.init(
            date: SessionReportPDF.dateField(day, timeZone: timeZone),
            start: entry.started.map { SessionReportPDF.timeField($0, timeZone: timeZone) } ?? "",
            end: entry.ended.map { SessionReportPDF.timeField($0, timeZone: timeZone) } ?? "",
            levelKey: level,
            level: named,
            title: entry.title ?? "",
            feelings: entry.feelings.filter { SessionReport.feelingOptions.contains($0) },
            otherOn: !(entry.feelingOther ?? "").isEmpty,
            otherText: entry.feelingOther ?? "",
            narrative: entry.body)
    }
}

public enum SessionReportPDF {

    // MARK: - Documents

    /// One report as a finished PDF — what the web form's "Generate report"
    /// writes for the same fields at the same moment.
    public static func document(_ report: SessionReport, now: Date = Date(),
                                timeZone: TimeZone = .current) -> Data {
        let clock = Clock(now, timeZone)
        let pages = reportPages(report, clock)
        let title = [report.title.isEmpty ? "Session report" : report.title, report.date]
            .filter { !$0.isEmpty }.joined(separator: " — ")
        return Data(pdfDocument(pages, title: title, created: creationDate(clock)))
    }

    /// Several reports in one file, each exactly as it would print alone —
    /// its own masthead, continuation sheets and "PAGE n OF m" — one after
    /// another. "Export all" is a bundle of reports, not a new layout.
    public static func document(_ reports: [SessionReport], now: Date = Date(),
                                timeZone: TimeZone = .current) -> Data {
        let clock = Clock(now, timeZone)
        let pages = reports.flatMap { reportPages($0, clock) }
        let title = reports.count == 1
            ? [reports[0].title.isEmpty ? "Session report" : reports[0].title, reports[0].date]
                .filter { !$0.isEmpty }.joined(separator: " — ")
            : "Session reports (\(reports.count))"
        return Data(pdfDocument(pages, title: title, created: creationDate(clock)))
    }

    /// The form's suggested file name for one report.
    public static func fileName(_ d: SessionReport, now: Date = Date(),
                                timeZone: TimeZone = .current) -> String {
        let clock = Clock(now, timeZone)
        let levelTag = !d.levelKey.isEmpty && d.levelKey != "other" ? d.levelKey : slug(d.level)
        return ["Session-Report", d.date.isEmpty ? dayFields(clock).date : d.date,
                d.start.replacingOccurrences(of: ":", with: ""), levelTag, slug(d.title)]
            .filter { !$0.isEmpty }.joined(separator: "_") + ".pdf"
    }

    /// How many pages one report takes. For the export sheet's summary.
    public static func pageCount(_ report: SessionReport, now: Date = Date(),
                                 timeZone: TimeZone = .current) -> Int {
        reportPages(report, Clock(now, timeZone)).count
    }

    // MARK: - Field shapes

    public static func dateField(_ date: Date, timeZone: TimeZone = .current) -> String {
        dayFields(Clock(date, timeZone)).date
    }

    public static func timeField(_ date: Date, timeZone: TimeZone = .current) -> String {
        dayFields(Clock(date, timeZone)).time
    }

    // MARK: - The core (mirrors the web form, function for function)

    /// `now`, broken into the local fields the form reads from a `Date`.
    struct Clock {
        var year, month, day, hour, minute, second: Int
        init(_ date: Date, _ zone: TimeZone) {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = zone
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            year = c.year ?? 1970; month = c.month ?? 1; day = c.day ?? 1
            hour = c.hour ?? 0; minute = c.minute ?? 0; second = c.second ?? 0
        }
    }

    static let months = ["JAN","FEB","MAR","APR","MAY","JUN","JUL","AUG","SEP","OCT","NOV","DEC"]
    static let days = ["SUN","MON","TUE","WED","THU","FRI","SAT"]

    static func pad(_ n: Int) -> String { n < 10 && n >= 0 ? "0\(n)" : "\(n)" }

    static func dayFields(_ c: Clock) -> (date: String, time: String) {
        ("\(c.year)-\(pad(c.month))-\(pad(c.day))", "\(pad(c.hour)):\(pad(c.minute))")
    }

    static func reportNumber(_ d: SessionReport, _ now: Clock) -> String {
        let f = dayFields(now)
        let date = (d.date.isEmpty ? f.date : d.date).replacingOccurrences(of: "-", with: "")
        let time = (d.start.isEmpty ? (d.date.isEmpty ? f.time : "0000") : d.start)
        return "GF-\(date)-\(replacingFirst(":", in: time))"
    }

    private static func replacingFirst(_ target: Character, in s: String) -> String {
        guard let i = s.firstIndex(of: target) else { return s }
        var out = s; out.remove(at: i); return out
    }

    static func longDate(_ iso: String) -> String {
        guard !iso.isEmpty else { return "" }
        let parts = iso.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        let y = parts.count > 0 ? parts[0] : 0
        let m = parts.count > 1 ? parts[1] : 1
        let d = parts.count > 2 ? parts[2] : 1
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: y, month: m, day: d)) ?? Date(timeIntervalSince1970: 0)
        let dow = cal.component(.weekday, from: date) - 1
        let month = (1...12).contains(m) ? months[m - 1] : "???"
        return "\(days[dow]) \(pad(d)) \(month) \(y)"
    }

    static func creationDate(_ c: Clock) -> String {
        "D:\(c.year)\(pad(c.month))\(pad(c.day))\(pad(c.hour))\(pad(c.minute))\(pad(c.second))"
    }

    static func slug(_ s: String) -> String {
        let stripped = String(String.UnicodeScalarView(
            s.decomposedStringWithCompatibilityMapping.unicodeScalars
                .filter { !(0x0300...0x036F).contains($0.value) }))
        var out = ""
        var dash = false
        for u in stripped.unicodeScalars {
            let ascii = u.isASCII && (CharacterSet.alphanumerics.contains(u))
            if ascii { out.unicodeScalars.append(u); dash = false }
            else if !dash { out.append("-"); dash = true }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(48))
    }

    // MARK: Text

    /// WinAnsiEncoding: Latin-1 plus the 0x80–0x9F punctuation block, one
    /// byte per character. Anything the standard fonts cannot draw becomes
    /// "?" rather than vanishing.
    static let win: [UInt32: UInt8] = [
        0x20AC: 0x80, 0x201A: 0x82, 0x0192: 0x83, 0x201E: 0x84, 0x2026: 0x85,
        0x2020: 0x86, 0x2021: 0x87, 0x02C6: 0x88, 0x2030: 0x89, 0x0160: 0x8A,
        0x2039: 0x8B, 0x0152: 0x8C, 0x017D: 0x8E, 0x2018: 0x91, 0x2019: 0x92,
        0x201C: 0x93, 0x201D: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97,
        0x02DC: 0x98, 0x2122: 0x99, 0x0161: 0x9A, 0x203A: 0x9B, 0x0153: 0x9C,
        0x017E: 0x9E, 0x0178: 0x9F,
    ]

    static func winAnsi(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        for u in s.precomposedStringWithCanonicalMapping.unicodeScalars {
            let c = u.value
            if c == 0x0A { out.append(0x0A) }
            else if c == 0x09 { out.append(contentsOf: [0x20, 0x20, 0x20, 0x20]) }
            else if c < 0x20 || c == 0x7F { out.append(0x20) }
            else if c < 0x7F || (c >= 0x80 && c <= 0xFF) { out.append(UInt8(c)) }
            else if let w = win[c] { out.append(w) }
            else if c == 0x2010 || c == 0x2011 || c == 0x2212 { out.append(0x2D) }
            else if c == 0x200B || c == 0x200D || c == 0xFE0F { /* invisible */ }
            else { out.append(0x3F) }
        }
        return out
    }

    /// Bytes already encoded pass through unchanged, exactly as the form's
    /// `winAnsi` passes its own output through a second time.
    static func winAnsi(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        for b in bytes {
            if b == 0x0A { out.append(0x0A) }
            else if b == 0x09 { out.append(contentsOf: [0x20, 0x20, 0x20, 0x20]) }
            else if b < 0x20 || b == 0x7F { out.append(0x20) }
            else { out.append(b) }
        }
        return out
    }

    /// JavaScript's `String.prototype.trim` over these bytes: after encoding,
    /// the only whitespace left is the space and the no-break space.
    private static func isBlank(_ line: ArraySlice<UInt8>) -> Bool {
        line.allSatisfy { $0 == 0x20 || $0 == 0xA0 || ($0 >= 0x09 && $0 <= 0x0D) }
    }

    /// Greedy word wrap for a monospaced face; keeps blank lines, splits
    /// over-long words.
    static func wrap(_ text: [UInt8], _ max: Int) -> [[UInt8]] {
        // \r\n and \r become \n, as the form's regex does.
        var normalised: [UInt8] = []
        var i = 0
        while i < text.count {
            if text[i] == 0x0D {
                normalised.append(0x0A)
                if i + 1 < text.count, text[i + 1] == 0x0A { i += 1 }
            } else { normalised.append(text[i]) }
            i += 1
        }
        var lines: [[UInt8]] = []
        for para in normalised.split(separator: 0x0A, omittingEmptySubsequences: false) {
            if isBlank(para) { lines.append([]); continue }
            var line: [UInt8] = []
            for w in para.split(separator: 0x20, omittingEmptySubsequences: true) {
                var word = Array(w)
                while word.count > max {
                    if !line.isEmpty { lines.append(line); line = [] }
                    lines.append(Array(word[0..<max])); word = Array(word[max...])
                }
                if line.isEmpty { line = word }
                else if line.count + 1 + word.count <= max { line += [0x20] + word }
                else { lines.append(line); line = word }
            }
            lines.append(line)
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines
    }

    // MARK: Geometry

    static let PW = 595.28, PH = 841.89
    static let ML = 42.0
    static let CW = PW - 2 * ML
    static let LIMIT = PH - 64
    static let HEAVY = 2.2, MED = 1.1
    static let COURIER = 0.6

    /// Helvetica-Bold advances for the one sans string that is measured.
    static let helveticaBold: [Character: Double] = [
        " ": 278, "A": 722, "E": 667, "F": 611, "G": 778, "O": 778, "P": 667,
        "0": 556, "1": 556, "2": 556, "3": 556, "4": 556,
        "5": 556, "6": 556, "7": 556, "8": 556, "9": 556,
    ]

    static func sansWidth(_ s: String, _ size: Double, _ tc: Double = 0) -> Double {
        var w = 0.0
        for ch in s { w += helveticaBold[ch] ?? 600 }
        return w / 1000 * size + tc * Double(s.count)
    }

    static func monoWidth(_ s: String, _ size: Double, _ tc: Double = 0) -> Double {
        Double(s.count) * (COURIER * size + tc)
    }

    /// `Number.prototype.toString` for the values this layout produces.
    static func js(_ v: Double) -> String {
        if v == v.rounded(.towardZero), abs(v) < 1e15 { return String(Int64(v)) }
        return "\(v)"
    }

    /// `(Math.round(v * 100) / 100).toString()`.
    ///
    /// `Math.round` rounds half up, and decides it exactly: adding 0.5 and
    /// flooring can carry 0.49999999999999994 over to 1.
    static func n2(_ v: Double) -> String {
        let r = v * 100
        let f = r.rounded(.down)
        return js((r - f >= 0.5 ? f + 1 : f) / 100)
    }

    static func pdfStr(_ s: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x28]
        for b in s {
            if b == 0x5C || b == 0x28 || b == 0x29 { out.append(0x5C) }
            out.append(b)
        }
        out.append(0x29)
        return out
    }

    final class Page {
        var ops: [[UInt8]] = [Array("0 J 0 j 0 G 0 g".utf8)]

        func push(_ s: String) { ops.append(Array(s.utf8)) }

        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ lw: Double) {
            push("\(js(lw)) w \(n2(x)) \(n2(PH - y - h)) \(n2(w)) \(n2(h)) re S")
        }
        func fill(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
            push("\(n2(x)) \(n2(PH - y - h)) \(n2(w)) \(n2(h)) re f")
        }
        func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double,
                  _ lw: Double, _ gray: Double = 0) {
            push("\(js(gray)) G \(js(lw)) w \(n2(x1)) \(n2(PH - y1)) m \(n2(x2)) \(n2(PH - y2)) l S 0 G")
        }
        func text(_ x: Double, _ y: Double, _ s: String, _ font: String, _ size: Double,
                  tc: Double = 0, white: Bool = false) {
            text(x, y, winAnsi(s), font, size, tc: tc, white: white)
        }
        func text(_ x: Double, _ y: Double, _ s: [UInt8], _ font: String, _ size: Double,
                  tc: Double = 0, white: Bool = false) {
            var op = Array("BT \(white ? "1" : "0") g /\(font) \(js(size)) Tf \(js(tc)) Tc \(n2(x)) \(n2(PH - y)) Td ".utf8)
            op += pdfStr(winAnsi(s))
            op += Array(" Tj 0 g ET".utf8)
            ops.append(op)
        }
        func box(_ x: Double, _ y: Double, _ size: Double, _ checked: Bool) {
            rect(x, y, size, size, 1.4)
            if checked {
                let i = 1.8
                line(x + i, y + i, x + size - i, y + size - i, 1.5)
                line(x + size - i, y + i, x + i, y + size - i, 1.5)
            }
        }
        var content: [UInt8] {
            var out: [UInt8] = []
            for (i, op) in ops.enumerated() {
                if i > 0 { out.append(0x0A) }
                out += op
            }
            return out
        }
    }

    static func pdfDocument(_ pages: [Page], title: String, created: String) -> [UInt8] {
        var objs: [[UInt8]] = []
        func add(_ s: [UInt8]) -> Int { objs.append(s); return objs.count }
        func add(_ s: String) -> Int { add(Array(s.utf8)) }
        let catalog = add(""), tree = add("")
        let faces = [("F1", "Courier"), ("F2", "Courier-Bold"), ("F3", "Helvetica-Bold"), ("F4", "Helvetica")]
        let fontRes = faces.map { k, base in
            "/\(k) \(add("<< /Type /Font /Subtype /Type1 /BaseFont /\(base) /Encoding /WinAnsiEncoding >>")) 0 R"
        }.joined(separator: " ")
        let kids = pages.map { p -> Int in
            let body = p.content
            let c = add(Array("<< /Length \(body.count) >>\nstream\n".utf8) + body + Array("\nendstream".utf8))
            return add("<< /Type /Page /Parent \(tree) 0 R /MediaBox [0 0 \(js(PW)) \(js(PH))] "
                       + "/Resources << /Font << \(fontRes) >> >> /Contents \(c) 0 R >>")
        }
        objs[catalog - 1] = Array("<< /Type /Catalog /Pages \(tree) 0 R >>".utf8)
        objs[tree - 1] = Array("<< /Type /Pages /Kids [\(kids.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(kids.count) >>".utf8)
        let infoRef = add(Array("<< /Title ".utf8) + pdfStr(winAnsi(title))
                          + Array(" /Subject (Gateway session report) /Creator (Gateway Forge session report form) /CreationDate (\(created)) >>".utf8))

        var out: [UInt8] = Array("%PDF-1.4\n%".utf8) + [0xE2, 0xE3, 0xCF, 0xD3, 0x0A]
        var offsets: [Int] = []
        for (i, o) in objs.enumerated() {
            offsets.append(out.count)
            out += Array("\(i + 1) 0 obj\n".utf8) + o + Array("\nendobj\n".utf8)
        }
        let xref = out.count
        out += Array("xref\n0 \(objs.count + 1)\n0000000000 65535 f \n".utf8)
        for o in offsets {
            let digits = String(o)
            out += Array((String(repeating: "0", count: max(0, 10 - digits.count)) + digits + " 00000 n \n").utf8)
        }
        out += Array("trailer\n<< /Size \(objs.count + 1) /Root \(catalog) 0 R /Info \(infoRef) 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        return out
    }

    // MARK: The report

    static let notRecorded = "- NOT RECORDED -"
    static let banner = "PERSONAL // GATEWAY JOURNAL // SELF-REPORT"

    static func sectionBar(_ p: Page, _ y: Double, _ title: String) -> Double {
        p.fill(ML, y, CW, 15)
        p.text(ML + 7, y + 10.6, title, "F3", 8, tc: 1.1, white: true)
        return y + 15
    }

    struct Cell { var label: String; var value: String; var w: Double }

    static func fieldRow(_ p: Page, _ y: Double, _ cells: [Cell]) -> Double {
        let size = 12.0, lead = 15.0
        let laid = cells.map { c -> (Cell, [[UInt8]]) in
            let max = Int(((c.w - 14) / (COURIER * size)).rounded(.down))
            let val = winAnsi(c.value)
            return (c, val.isEmpty ? [] : wrap(val, max))
        }
        let tallest = Swift.max(1, laid.map { $0.1.count }.max() ?? 0)
        let h = Swift.max(42, 30 + Double(tallest - 1) * lead + 12)
        var x = ML
        for (c, lines) in laid {
            p.rect(x, y, c.w, h, MED)
            p.text(x + 6, y + 10.5, c.label, "F3", 6.8, tc: 0.9)
            if !lines.isEmpty {
                for (i, l) in lines.enumerated() { p.text(x + 7, y + 29 + Double(i) * lead, l, "F1", size) }
            } else {
                p.text(x + 7, y + 29, notRecorded, "F1", 9)
            }
            x += c.w
        }
        p.rect(ML, y, CW, h, HEAVY)
        return y + h
    }

    static func chrome(_ p: Page, _ i: Int, _ n: Int, _ reportNo: String) {
        let bw = monoWidth(banner, 9, 1.4)
        p.text((PW - bw) / 2, 28, banner, "F2", 9, tc: 1.4)
        p.line(ML, PH - 52, ML + CW, PH - 52, HEAVY)
        p.text(ML, PH - 42, "GF FORM 1 · SESSION REPORT", "F3", 6.8, tc: 0.9)
        let no = monoWidth(reportNo, 8)
        p.text((PW - no) / 2, PH - 42, reportNo, "F1", 8)
        let pg = "PAGE \(i) OF \(n)"
        p.text(ML + CW - sansWidth(pg, 6.8, 0.9), PH - 42, pg, "F3", 6.8, tc: 0.9)
        p.text((PW - bw) / 2, PH - 22, banner, "F2", 9, tc: 1.4)
    }

    static func reportPages(_ d: SessionReport, _ now: Clock) -> [Page] {
        let filedDay = longDate(dayFields(now).date)
        let filed = "\(String(filedDay.dropFirst(4))) \(pad(now.hour)):\(pad(now.minute))"
        let reportNo = reportNumber(d, now)
        var pages: [Page] = []
        var p = Page(); pages.append(p)

        // masthead
        var y = 42.0
        let mh = 70.0, rw = 176.0, rx = ML + CW - rw
        p.rect(ML, y, CW, mh, HEAVY)
        p.line(rx, y, rx, y + mh, MED)
        p.line(rx, y + mh / 2, ML + CW, y + mh / 2, MED)
        p.text(ML + 11, y + 17, "GATEWAY FORGE", "F3", 8, tc: 1.6)
        p.text(ML + 10, y + 46, "SESSION REPORT", "F3", 25)
        p.text(ML + 11, y + 61, "FOCUS LEVEL SESSION — PERSONAL EXPERIENCE RECORD", "F3", 6.6, tc: 1)
        p.text(rx + 7, y + 11, "REPORT NO.", "F3", 6.6, tc: 0.9)
        p.text(rx + 7, y + 27, reportNo, "F1", 11)
        p.text(rx + 7, y + mh / 2 + 11, "FILED", "F3", 6.6, tc: 0.9)
        p.text(rx + 7, y + mh / 2 + 27, filed, "F1", 10)
        y += mh + 12

        // I
        y = sectionBar(p, y, "SECTION I — IDENTIFICATION")
        y = fieldRow(p, y, [
            Cell(label: "1. DATE", value: longDate(d.date), w: 128),
            Cell(label: "2. START", value: d.start, w: 70),
            Cell(label: "3. END", value: d.end, w: 70),
            Cell(label: "4. FOCUS LEVEL", value: d.level, w: CW - 268),
        ])
        y = fieldRow(p, y, [Cell(label: "5. SESSION TITLE", value: d.title, w: CW)])
        y += 12

        // II
        y = sectionBar(p, y, "SECTION II — PHYSICAL STATE")
        let other = d.otherOn || !d.otherText.isEmpty
        let otherMax = Int(((CW - 92) / (COURIER * 11)).rounded(.down))
        let otherLines = d.otherText.isEmpty ? [[]] : wrap(winAnsi(d.otherText), otherMax)
        let bh = 50 + Double(otherLines.count) * 15 + 4
        p.text(ML + 6, y + 10.5, "6. BODY FEELING — MARK ALL THAT APPLY", "F3", 6.8, tc: 0.9)
        let colW = (CW - 12) / Double(SessionReport.feelingOptions.count)
        for (i, o) in SessionReport.feelingOptions.enumerated() {
            let x = ML + 8 + Double(i) * colW
            p.box(x, y + 19, 10, d.feelings.contains(o))
            p.text(x + 16, y + 27.5, o.uppercased(), "F3", 8, tc: 0.7)
        }
        let oy = y + 42
        p.box(ML + 8, oy, 10, other)
        p.text(ML + 24, oy + 8.5, "OTHER:", "F3", 8, tc: 0.7)
        for (i, l) in otherLines.enumerated() {
            let by = oy + 8.5 + Double(i) * 15
            p.text(ML + 84, by, l, "F1", 11)
            p.line(ML + 82, by + 3, ML + CW - 8, by + 3, 0.5, 0.35)
        }
        p.rect(ML, y, CW, bh, HEAVY)
        y += bh + 12

        // III — flows across as many pages as the account needs
        let size = 10.5, lead = 15.0
        let max = Int(((CW - 18) / (COURIER * size)).rounded(.down))
        var lines = wrap(winAnsi(d.narrative), max)
        if lines.isEmpty { lines = [winAnsi(notRecorded)] }
        let endRoom = 26.0
        var first = true

        while true {
            y = sectionBar(p, y, first ? "SECTION III — COMMENTS / EXPERIENCE"
                                       : "SECTION III — COMMENTS / EXPERIENCE (CONTINUED)")
            let top = y, base0 = top + 27
            p.text(ML + 6, top + 10.5, first ? "7. ACCOUNT OF THE EXPERIENCE — IN THE REPORTER'S OWN WORDS"
                                             : "7. ACCOUNT OF THE EXPERIENCE (CONTINUED)", "F3", 6.8, tc: 0.9)
            let fitFull = Int(((LIMIT - 8 - base0) / lead).rounded(.down)) + 1
            let fitLast = Int(((LIMIT - 8 - endRoom - base0) / lead).rounded(.down)) + 1
            let last = lines.count <= fitLast
            let take = last ? lines.count : Swift.min(fitFull, lines.count - 1)
            let slots = last ? fitLast : fitFull
            let bottom = base0 + Double(slots - 1) * lead + 8

            for i in 0..<slots {
                p.line(ML + 8, base0 + Double(i) * lead + 3.2, ML + CW - 8, base0 + Double(i) * lead + 3.2, 0.4, 0.72)
            }
            for (i, l) in lines.prefix(take).enumerated() { p.text(ML + 9, base0 + Double(i) * lead, l, "F1", size) }
            p.rect(ML, top, CW, bottom - top, HEAVY)
            lines = Array(lines.dropFirst(take))

            if last {
                let end = "*** END OF REPORT ***"
                p.text((PW - monoWidth(end, 9, 1.4)) / 2, bottom + 18, end, "F2", 9, tc: 1.4)
                break
            }

            // continuation sheet
            p = Page(); pages.append(p); first = false
            y = 42
            p.rect(ML, y, CW, 34, HEAVY)
            p.line(rx, y, rx, y + 34, MED)
            p.text(ML + 10, y + 22, "SESSION REPORT — CONTINUATION SHEET", "F3", 13)
            p.text(rx + 7, y + 11, "REPORT NO.", "F3", 6.6, tc: 0.9)
            p.text(rx + 7, y + 26, reportNo, "F1", 11)
            y += 34 + 12
        }

        for (i, pg) in pages.enumerated() { chrome(pg, i + 1, pages.count, reportNo) }
        return pages
    }
}
