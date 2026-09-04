/**
 * The shell, bound to the ported core.
 *
 * Everything drawn here arrives from `shell:model`, which reads the library
 * through `src/core`. Nothing about a level — its beat, whether that beat is
 * verified, what is published against what was found — is decided in this
 * file. That is the same rule the Swift shell keeps, and it is why the two
 * cannot drift: they are reading the same arithmetic.
 */

import { BedPlayer, type BedState, timecode } from "./bed.js";
import { $ } from "./dom.js";
import { ListeningPane } from "./listening.js";
import type { BedPlan } from "../core/bedPlan.js";
import type { AudioProfile } from "../core/audioProfile.js";

interface StationRow {
  beat: number;
  carrier: number;
  differential: boolean;
  provenance: "measured" | "tuned" | "stated" | "estimated";
}

interface LevelRow {
  key: string;
  name: string;
  /** What the bed would play: a measured tape profile where there is one.
   *  The rail chip's number. */
  beat: number;
  carrier: number;
  /** The ladder's reading of this rung, and where it came from. The level
   *  page's number — deliberately not the same quantity as above. */
  station?: StationRow;
  unverified: boolean;
  published: string;
  notes: string;
}

interface ShellModel {
  root: string;
  levels: LevelRow[];
  counts: { segments: number; templates: number; voices: number; focus: number };
  engine: { name: string; voices: string[]; voice?: string };
}

type ModelReply = { ok: true; model: ShellModel } | { ok: false; error: string };
type BedReply =
  | { ok: true; plan: BedPlan; profile: AudioProfile }
  | { ok: false; error: string };

type SpeechReply =
  | { ok: true; samples: ArrayBuffer; sampleRate: number; voice: string; text: string }
  | { ok: false; error: string };

type ListeningReply =
  | { ok: true; profile: AudioProfile; bed: BedPlan;
      levels: { name: string; field: keyof AudioProfile; tint: string; why: string }[] }
  | { ok: false; error: string };

declare global {
  interface Window {
    gateway: {
      shellModel(): Promise<ModelReply>;
      bedLevel(key: string): Promise<BedReply>;
      listening(): Promise<ListeningReply>;
      saveListening(profile: AudioProfile): Promise<{ ok: boolean; error?: string }>;
      speakCalibration(): Promise<SpeechReply>;
      speechEngine(): Promise<{ ok: boolean; name?: string; voices?: string[]; voice?: string; error?: string }>;
    };
  }
}

const panes = ["paneHome", "paneLevel", "paneStudio", "paneListening", "paneError"] as const;
function show(which: (typeof panes)[number]): void {
  for (const p of panes) $(p).hidden = p !== which;
}

/** A differential of zero is the same frequency in both ears — no binaural
 *  signal at all, which is correct at waking consciousness and at a signpost
 *  passed through. It is described that way rather than printed as "0.0 Hz",
 *  which would read as a missing measurement. Same sentence the Mac prints. */
function signalSentence(st: StationRow): string {
  if (!st.differential) return "no differential — textures only";
  return `${st.beat.toFixed(2)} Hz differential at ${st.carrier.toFixed(0)} Hz carrier`;
}

/** Where the number came from, said rather than implied. */
function provenanceNote(p: StationRow["provenance"]): string {
  switch (p) {
    case "measured": return "Measured off the tape for this level.";
    case "tuned":    return "Tuned by hand for this level.";
    case "stated":   return "Stated in the level's own configuration, not yet verified.";
    case "estimated":return "Interpolated from the levels either side. An estimate, not a measurement.";
  }
}

function beatLabel(l: LevelRow): string {
  return l.beat <= 0 ? "—" : `${l.beat.toFixed(1)} Hz`;
}

function renderLevels(model: ShellModel): void {
  const list = $("levels");
  list.textContent = "";
  $("railEmpty").hidden = model.levels.length > 0;

  for (const level of model.levels) {
    const li = document.createElement("li");
    const button = document.createElement("button");
    button.className = "level";
    button.dataset.key = level.key;

    const dot = document.createElement("span");
    dot.className = `dot${level.unverified ? " is-unverified" : ""}`;
    if (level.unverified) dot.title = "beat not yet tuned for this level";

    const key = document.createElement("span");
    key.className = "key";
    key.textContent = level.key;

    const beat = document.createElement("span");
    beat.className = "beat";
    beat.textContent = beatLabel(level);

    button.append(dot, key, beat);
    button.addEventListener("click", () => selectLevel(model, level.key));
    li.append(button);
    list.append(li);
  }
}

function selectLevel(model: ShellModel, key: string): void {
  const level = model.levels.find(l => l.key === key);
  if (!level) return;

  for (const el of document.querySelectorAll(".level, .dest")) {
    el.classList.toggle("is-selected", el instanceof HTMLElement && el.dataset.key === key);
  }

  $("levelName").textContent = level.name;
  $("levelKey").textContent = level.key;
  $("levelUnverified").hidden = !level.unverified;
  // Below Focus 10 the count is an induction rather than a rung, so there is
  // no station to read — said plainly instead of shown as a blank reading.
  if (level.station) {
    $("levelSignal").textContent = signalSentence(level.station);
    $("levelSignalNote").textContent = provenanceNote(level.station.provenance);
  } else {
    $("levelSignal").textContent = "—";
    $("levelSignalNote").textContent =
      "This station is below Focus 10, where the count is an induction rather than a ladder.";
  }

  // Published and found are shown together and never merged. Where one is
  // empty it says so rather than borrowing the other's text.
  $("levelPublished").textContent = level.published || "Nothing published for this level.";
  $("levelNotes").textContent = level.notes || "Nothing written yet. What is here is yours to find.";

  $("inspectorTitle").textContent = `${level.key} — notes`;
  $("inspectorBody").textContent = level.notes || "Write what you perceived.";

  if (!$("paneListening").hidden) { bed.stop(); listening.close(); }
  $("listen").hidden = false;
  void armBed(level);

  show("paneLevel");
}

// ---------------------------------------------------------------------- bed
//
// The one thing on this page that cannot be verified by reading it. A carrier
// and a differential are two decimals until they are in the room.

const headphoneNote = "Headphones — the differential is between the ears.";

/** The plan and calibration behind the level currently on screen, fetched
 *  when it is selected so the control can describe what it will play before
 *  anyone presses it. */
let armed: { key: string; plan: BedPlan; profile: AudioProfile } | undefined;

const bed = new BedPlayer({
  state: state => {
    renderBedState(state);
    listening.bedState(state === "playing" || state === "starting");
  },
  position: seconds => { $("listenTime").textContent = timecode(seconds); },
  notStereo: channels => {
    const note = $("listenNote");
    note.classList.add("is-warning");
    note.textContent = channels === 1
      ? "This output is mono. A binaural differential is a difference between the ears, "
        + "so there is nothing here to hear — silence rather than something that would pass for it."
      : `This output has ${channels} channel(s). A binaural pair needs two.`;
  },
  failed: message => {
    const error = $("listenError");
    error.textContent = `The bed did not start: ${message}`;
    error.hidden = false;
  },
});

const listening = new ListeningPane(bed);

function renderBedState(state: BedState): void {
  const sounding = state === "playing" || state === "starting";
  $("listen").classList.toggle("is-sounding", sounding);
  $("listenGlyph").textContent = sounding ? "\u25a0" : "\u25b6";
  $("listenLabel").textContent =
    state === "starting" ? "Starting" :
    state === "playing" ? "Stop" :
    state === "stopping" ? "Stopping" : "Listen";
  const time = $("listenTime");
  time.hidden = !sounding;
  if (state === "stopped") time.textContent = "0:00";
  // Between the press and the ramp finishing there is nothing useful a second
  // press could do, and one would race the first.
  ($("listenButton") as HTMLButtonElement).disabled = state === "starting" || state === "stopping";
}

/**
 * What the bed is about to play, when that is not the number printed above it.
 *
 * The level page shows the *station* — the ladder's reading of this rung. A
 * tape plays `resolvedSignal`, which prefers a pair measured off a real
 * recording where one exists. At Focus 10 those genuinely differ: 4.00 Hz at
 * 110 Hz authored, 4.05 at 100 measured. A button that quietly sounded the
 * second while sitting under the first would be the same quiet lie the
 * published-and-found rule exists to prevent, one layer down — so it is said.
 */
function playedNote(plan: BedPlan, station: StationRow | undefined): string | undefined {
  const stage = plan.stages[0];
  if (!stage || !station) return undefined;
  const differs = Math.abs(station.beat - stage.beat) > 0.005
    || Math.abs(station.carrier - stage.carrier) > 0.5;
  if (!differs) return undefined;
  const measured = stage.signalSource;
  return `Plays ${stage.beat.toFixed(2)} Hz at ${stage.carrier.toFixed(0)} Hz — the pair measured off `
    + `${measured ?? "the tape"}, which is what a session drives this level at. The reading above is `
    + `the ladder's.`;
}

/** Fetch the bed behind a level, describe it, and follow it if the bed is
 *  already sounding. Following rather than stopping is deliberate: the rail
 *  is a climb, and hearing one rung against the next is most of what it is
 *  for. */
async function armBed(level: LevelRow): Promise<void> {
  armed = undefined;
  $("listenError").hidden = true;
  $("listenPlayed").hidden = true;
  const note = $("listenNote");
  if (!note.classList.contains("is-warning")) note.textContent = headphoneNote;

  const reply = await window.gateway.bedLevel(level.key);
  // A level selected while this was in flight wins; a late reply for the old
  // one must not arm the control against the level now on screen.
  if ($("levelKey").textContent !== level.key) return;
  if (!reply.ok) {
    const error = $("listenError");
    error.textContent = `No bed for this level: ${reply.error}`;
    error.hidden = false;
    return;
  }
  armed = { key: level.key, plan: reply.plan, profile: reply.profile };

  const played = playedNote(reply.plan, level.station);
  $("listenPlayed").textContent = played ?? "";
  $("listenPlayed").hidden = played === undefined;

  if (bed.isSounding) await bed.play(reply.plan, reply.profile);
}

function toggleBed(): void {
  if (bed.isSounding) { bed.stop(); return; }
  if (!armed) return;
  void bed.play(armed.plan, armed.profile);
}

function renderCounts(model: ShellModel): void {
  const counts = $("counts");
  counts.textContent = "";
  const rows: [string, number][] = [
    ["segments", model.counts.segments],
    ["templates", model.counts.templates],
    ["focus levels", model.counts.focus],
    ["voices", model.counts.voices],
  ];
  for (const [label, value] of rows) {
    const wrap = document.createElement("div");
    const dt = document.createElement("dt");
    dt.textContent = label;
    const dd = document.createElement("dd");
    dd.textContent = String(value);
    wrap.append(dt, dd);
    counts.append(wrap);
  }
}

/**
 * Studio's eight destinations, in the Mac's own order and with its own
 * subtitles. Seven of them do not exist on this build; they are listed
 * anyway, greyed, because a menu showing only what works misrepresents what
 * Studio is — and because the gap is the honest headline of this port.
 */
const studioDestinations: { key: string; title: string; subtitle: string; built: boolean }[] = [
  { key: "queues", title: "Production", subtitle: "Narration, assembly and opportunistic rendering.", built: false },
  { key: "sessions", title: "Session Plans", subtitle: "Templates, structure, bed automation and composition.", built: false },
  { key: "listening", title: "Listening", subtitle: "Calibrate the live bed.", built: true },
  { key: "voice", title: "Voice", subtitle: "The bundled voices, and which one the queue renders with.", built: false },
  { key: "library", title: "Library", subtitle: "Authored coverage, gaps and unassigned material.", built: false },
  { key: "deleted", title: "Recently Deleted", subtitle: "Restore anything deleted in the last 30 days, or remove it now.", built: false },
  { key: "system", title: "System", subtitle: "Installed components, the local composer, and measured readiness.", built: false },
];

/** Everything that has to happen on the way out of wherever we were: the bed
 *  silenced, and any unsaved drag flushed to the file. */
function leaveCurrentPane(): void {
  bed.stop();
  armed = undefined;
  $("listen").hidden = true;
  if (!$("paneListening").hidden) listening.close();
}

function openListening(): void {
  leaveCurrentPane();
  $("inspectorTitle").textContent = "Listening";
  $("inspectorBody").textContent =
    "Eight levels, saved once and applied to everything a session plays.";
  show("paneListening");
  void listening.open();
}

function renderStudio(): void {
  const list = $("studioList");
  list.textContent = "";
  for (const dest of studioDestinations) {
    const li = document.createElement("li");
    const button = document.createElement("button");
    button.className = "destrow";
    button.type = "button";
    button.disabled = !dest.built;

    const title = document.createElement("span");
    title.className = "t";
    title.textContent = dest.title;

    const subtitle = document.createElement("span");
    subtitle.className = "s";
    subtitle.textContent = dest.built
      ? dest.subtitle
      : `${dest.subtitle} Not built on this platform yet.`;

    button.append(title, subtitle);
    if (dest.built) button.addEventListener("click", openListening);
    li.append(button);
    list.append(li);
  }
}

function openStudio(): void {
  leaveCurrentPane();
  $("inspectorTitle").textContent = "Studio";
  $("inspectorBody").textContent = "Build, tune and maintain Gateway Forge.";
  show("paneStudio");
}

function openHome(): void {
  leaveCurrentPane();
  $("inspectorTitle").textContent = "The default path";
  $("inspectorBody").textContent = "The order the tapes teach it in.";
  show("paneHome");
}

function wireDestinations(): void {
  for (const el of document.querySelectorAll<HTMLButtonElement>(".dest")) {
    el.addEventListener("click", () => {
      for (const other of document.querySelectorAll(".dest, .level")) {
        other.classList.remove("is-selected");
      }
      el.classList.add("is-selected");
      if (el.dataset.dest === "studio") openStudio(); else openHome();
    });
  }

  $("mixListen").addEventListener("click", () => { void listening.toggle(); });
  $("mixTuning").addEventListener("click", () => listening.cue("tuning"));
  $("mixReturn").addEventListener("click", () => listening.cue("return"));
  $("mixSpeak").addEventListener("click", () => { void listening.speak(); });
}

async function start(): Promise<void> {
  const reply = await window.gateway.shellModel();
  if (!reply.ok) {
    $("errorText").textContent = reply.error;
    show("paneError");
    return;
  }
  const model = reply.model;
  $("root").textContent = model.root;
  // What it speaks in, said plainly — the library's voice count is about the
  // listener's own voices and is legitimately zero on a fresh install.
  $("engine").textContent = model.engine.voice === undefined
    ? `${model.engine.name} — no voice bundled, so nothing can speak`
    : `${model.engine.name} · ${model.engine.voice}`;
  renderCounts(model);
  renderLevels(model);
  renderStudio();
  wireDestinations();
  $("listenButton").addEventListener("click", toggleBed);
  renderBedState("stopped");
  // A bed still ramping when the window goes is a bed that outlives its
  // window by six tenths of a second, which on Linux is an audible ghost.
  window.addEventListener("pagehide", () => bed.stop());
  show("paneHome");
}

void start();
