/**
 * The running order, the join to templates, and the guidance ladder.
 *
 * `sessionDestination` is *supplied* by the fixture rather than computed here:
 * it walks a resolved template, which is not ported. What is compared is the
 * joining — the aliases, the tracks with no template, and the order — which is
 * what `lessonsFrom` actually is.
 */
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "fs";
import { basename, dirname, join } from "path";
import { tmpdir } from "os";
import * as D from "../core/defaultPath.js";
import { emptyLedger, type ActivityLedger } from "../core/activity.js";
import type { ScriptDoc } from "../core/scriptDoc.js";
import { emptyDoc } from "../core/scriptDoc.js";

interface TrackOut { wave: number; waveTitle: string; disc: number; track: number; slug: string }
interface LessonOut extends TrackOut { template: string; title: string; level: string }
interface Fixture {
  manifestPath: string;
  aliases: Record<string, string>;
  tracks: TrackOut[];
  lessons: LessonOut[];
  templates: { stem: string; path: string; title: string; destination: string }[];
  listingCases: { name: string; json: string; tracks: TrackOut[] }[];
  remainingCases: { completed: string[]; remaining: number; isComplete: boolean }[];
  guidanceCases: { n: number; verbosity: number; rationale: string }[];
  joinCases: {
    name: string; tracks: TrackOut[]; templates: string[];
    titles: string[]; destinations: string[]; lessons: LessonOut[];
  }[];
}

const root = join(process.cwd(), "..");
const fx = JSON.parse(readFileSync(join(root, "library", "reference", "path-fixture.json"), "utf8")) as Fixture;

let pass = 0, fail = 0;
/** Swift writes fixtures with `.sortedKeys`, so anything compared against one
 *  has to be key-sorted too, or identical values differ on field order. */
const canon = (v: unknown): string =>
  JSON.stringify(v, (_k, val) =>
    val && typeof val === "object" && !Array.isArray(val)
      ? Object.fromEntries(Object.keys(val as object).sort().map(k => [k, (val as Record<string, unknown>)[k]]))
      : val);
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };

check(D.manifestPath === fx.manifestPath, "the manifest lives where Swift looks for it");
check(JSON.stringify(D.aliases, Object.keys(D.aliases).sort())
      === JSON.stringify(fx.aliases, Object.keys(fx.aliases).sort()),
  "the aliases are the same set");

// --- the running order, off the real manifest
const tracks = D.trackListing(root);
check(tracks.length === fx.tracks.length, `${tracks.length} tracks vs ${fx.tracks.length}`);
check(canon(tracks) === canon(fx.tracks), "in the same order, wave then disc then track");

// --- the join, using the destinations the fixture supplies
const byStem = new Map(fx.templates.map(t => [t.stem, t]));
const docFor = (path: string): ScriptDoc | undefined => {
  const stem = basename(path).replace(/\.[^.]*$/, "");
  const t = byStem.get(stem);
  return t === undefined ? undefined : { ...emptyDoc(), title: t.title, level: t.destination };
};
const lessons = D.lessonsFrom({
  tracks,
  templates: fx.templates.map(t => t.path),
  load: docFor,
  destination: doc => doc.level,
});
check(lessons.length === fx.lessons.length, `${lessons.length} lessons vs ${fx.lessons.length}`);
lessons.forEach((l, i) => {
  const t = fx.lessons[i];
  if (!t) return;
  check(canon(l) === canon(t), `lesson ${i} ${l.template}: ${canon(l)} vs ${canon(t)}`);
});

// --- the listing, on manifests the real one is not
//
// `gfscaffold` writes the manifest already sorted, so removing the sort from
// `trackListing` changes nothing measured against it. These are deliberately
// out of order, and include the malformed shapes besides.
for (const c of fx.listingCases) {
  const scratch = join(tmpdir(), `gf-listing-ts-${process.pid}-${c.name}-${Date.now()}`);
  const u = join(scratch, D.manifestPath);
  mkdirSync(dirname(u), { recursive: true });
  writeFileSync(u, c.json, "utf8");
  const got = D.trackListing(scratch);
  rmSync(scratch, { recursive: true, force: true });
  check(canon(got) === canon(c.tracks),
    `listing ${c.name}: ${JSON.stringify(got.map(t => t.slug))} vs ${JSON.stringify(c.tracks.map(t => t.slug))}`);
}
check(fx.listingCases.some(c => c.name === "reversed" && c.tracks.map(t => t.slug).join("") === "cab"),
  "an out-of-order manifest is sorted on the way in — wave, then disc, then track");
check(fx.listingCases.some(c => c.name === "not-json" && c.tracks.length === 0),
  "and an unreadable one is simply no listing, not an error");

// --- remaining and complete
for (const c of fx.remainingCases) {
  const completed = new Set(c.completed);
  check(D.remaining(lessons, completed).length === c.remaining,
    `remaining after ${c.completed.length} completed: ${D.remaining(lessons, completed).length} vs ${c.remaining}`);
  check(D.isComplete(lessons, completed) === c.isComplete,
    `isComplete after ${c.completed.length} completed`);
}

// --- the guidance ladder
for (const c of fx.guidanceCases) {
  check(D.suggestedVerbosity(c.n) === c.verbosity,
    `verbosity at ${c.n} completions: ${D.suggestedVerbosity(c.n)} vs ${c.verbosity}`);
  check(D.guidanceRationale(c.n) === c.rationale,
    `rationale at ${c.n}: ${JSON.stringify(D.guidanceRationale(c.n))} vs ${JSON.stringify(c.rationale)}`);
}

// --- the constructed joins: what the real listing does not exercise
for (const c of fx.joinCases) {
  const titles = new Map(c.templates.map((stem, i) => [stem, { title: c.titles[i]!, dest: c.destinations[i]! }]));
  const got = D.lessonsFrom({
    tracks: c.tracks,
    templates: c.templates.map(stem => `library/templates/${stem}.gws`),
    load: path => {
      const stem = basename(path).replace(/\.gws$/, "");
      const t = titles.get(stem);
      return t === undefined ? undefined : { ...emptyDoc(), title: t.title, level: t.dest };
    },
    destination: doc => doc.level,
  });
  check(canon(got) === canon(c.lessons), `join ${c.name}: ${canon(got)} vs ${canon(c.lessons)}`);
}

// --- completions at a level
{
  const ledger: ActivityLedger = {
    ...emptyLedger(),
    completions: [
      { track: "a", level: "F10", seconds: 1, finished: 0 },
      { track: "b", level: "f10", seconds: 1, finished: 0 },
      { track: "c", level: "F12", seconds: 1, finished: 0 },
      { track: "d", seconds: 1, finished: 0 },
    ],
  };
  check(D.completionsAtLevel("F10", ledger) === 2,
    "completions at a level are counted case-insensitively");
  check(D.completionsAtLevel("f12", ledger) === 1, "and the query is too");
  check(D.completionsAtLevel("F99", ledger) === 0, "a level never reached counts zero");
}

// --- the properties these exist for
check(fx.lessons.length >= 45,
  `the path covers the box set rather than an introduction (${fx.lessons.length} lessons)`);
check(fx.lessons[0]?.template === "f3-visit", "it opens where the tapes open, on Orientation");
check(new Set(fx.lessons.map(l => l.wave)).size === 8, "all eight waves are present");
check(new Set(fx.lessons.map(l => l.template)).size === fx.lessons.length, "no lesson appears twice");
{
  const keys = fx.lessons.map(l => [l.wave, l.disc, l.track]);
  const sorted = keys.every((k, i) => {
    if (i === 0) return true;
    const p = keys[i - 1]!;
    return p[0]! < k[0]! || (p[0] === k[0] && (p[1]! < k[1]! || (p[1] === k[1] && p[2]! <= k[2]!)));
  });
  check(sorted, "lessons come in the tapes' own order");
}
check(fx.joinCases.some(c => c.name === "no-template" && c.lessons.length === 0),
  "a track nothing plays is skipped rather than faked");
check(fx.joinCases.some(c => c.name === "alias" && c.lessons[0]?.template === "f3-visit"),
  "and an alias joins the slug to the template that performs it");
check(fx.joinCases.some(c => c.name === "accented-title" && c.lessons[0]?.title.includes("é")),
  "an accented title survives the join intact");
// The join preserves the order it is given — `trackListing` is what sorts, and
// a caller handing tracks straight to the join gets them back in that order.
check(fx.joinCases.some(c => c.name === "out-of-order" && c.lessons[0]?.wave === 2),
  "the join preserves its input order rather than sorting again");
// Swift matches `case 0...1` and `case 2...4`; a negative count matches
// neither and falls to `default`, the least detailed setting. Surprising, and
// pinned here precisely because it is: the port read it as new ground instead,
// which is the opposite answer, and only a negative case could see it.
check(fx.guidanceCases.every(c => c.n < 0 ? c.verbosity === 1 : true),
  "a negative completion count falls through to the least detailed setting");
check(fx.guidanceCases.some(c => c.n < 0),
  "and a negative count is actually among the cases, or the rule above is untested");

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
