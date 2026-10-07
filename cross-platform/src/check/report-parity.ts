/**
 * The session report PDF, three ways, one document.
 *
 * `docs/session-report.html` writes GF Form 1 in the browser. The desktop
 * journal exports the same report through `SessionReportPDF.swift`, and the
 * owner's requirement is that the two "match the web template 1:1". So this
 * runs the page's own report core -- the code between its `session-report
 * core` markers, untouched -- over the inputs in
 * `library/reference/session-report-fixture.json`, which `gfcorpus` wrote from
 * the Swift writer, and requires the same bytes.
 *
 * Bytes, not a resemblance: a PDF that merely looks alike can still place a
 * line a point lower or encode a quote differently, and the next person to
 * compare two printed reports would be the one to find out.
 */
import { readFileSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { createHash } from "crypto";
import { createContext, runInContext } from "vm";

interface Case {
  name: string;
  report: Record<string, unknown>;
  now: number;
  fileName: string;
  pages: number;
  bytes: number;
  sha256: string;
}
interface Fixture { timeZone: string; cases: Case[] }

const root = join(process.cwd(), "..");
const fx = JSON.parse(readFileSync(join(root, "library", "reference", "session-report-fixture.json"), "utf8")) as Fixture;
// The report reads local wall-clock fields from its Date, as the browser
// does; the fixture was written for one named zone.
process.env.TZ = fx.timeZone;

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };

console.log("session report: web form against the desktop writer");

const page = readFileSync(join(root, "docs", "session-report.html"), "utf8");
const begin = page.indexOf("// ==== session-report core: begin ====");
const end = page.indexOf("// ==== session-report core: end ====");
check(begin > 0 && end > begin, "the page marks its report core");

const core = page.slice(begin, end);
check(!/\b(document|window|localStorage|navigator)\b/.test(core.replace(/\/\/.*$/gm, "")),
      "the report core touches no page or browser API");

const ctx: Record<string, unknown> = {};
createContext(ctx);
runInContext(`${core};this.buildReport = buildReport; this.reportPages = reportPages;`, ctx);
const buildReport = ctx.buildReport as (d: unknown, now: Date) => { bytes: Uint8Array; name: string; pages: number };

check(fx.cases.length >= 5, "the fixture carries several reports");
check(fx.cases.some(c => c.pages > 2), "at least one report runs to three pages");
for (const c of fx.cases) {
  const r = buildReport(c.report, new Date(c.now));
  const digest = createHash("sha256").update(Buffer.from(r.bytes)).digest("hex");
  check(r.pages === c.pages, `${c.name}: ${r.pages} pages vs ${c.pages}`);
  check(r.name === c.fileName, `${c.name}: file name ${r.name} vs ${c.fileName}`);
  const same = digest === c.sha256 && r.bytes.length === c.bytes;
  if (!same) {
    // Leave the browser's version where it can be opened beside the app's.
    const out = join(tmpdir(), `gf-report-${c.name.replace(/\W+/g, "-")}.pdf`);
    writeFileSync(out, Buffer.from(r.bytes));
    console.log(`  the web form's version is at ${out}`);
  }
  check(same, `${c.name}: identical bytes (${r.bytes.length} vs ${c.bytes})`);
}

console.log(`  ${pass} passed, ${fail} failed`);
if (fail > 0) process.exit(1);
