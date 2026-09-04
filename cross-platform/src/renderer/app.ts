/**
 * The shell, bound to the ported core.
 *
 * Everything drawn here arrives from `shell:model`, which reads the library
 * through `src/core`. Nothing about a level — its beat, whether that beat is
 * verified, what is published against what was found — is decided in this
 * file. That is the same rule the Swift shell keeps, and it is why the two
 * cannot drift: they are reading the same arithmetic.
 */

// This file is loaded as a module and has no imports of its own, so it needs
// an explicit one to be treated as such — `declare global` below is only
// legal inside a module, and without it the bridge type lands in the global
// scope of every other file instead.
export {};

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
}

type ModelReply = { ok: true; model: ShellModel } | { ok: false; error: string };

declare global {
  interface Window { gateway: { shellModel(): Promise<ModelReply> } }
}

const $ = <T extends HTMLElement>(id: string): T => {
  const el = document.getElementById(id);
  if (!el) throw new Error(`the page is missing #${id}`);
  return el as T;
};

const panes = ["paneHome", "paneLevel", "paneStudio", "paneError"] as const;
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

  show("paneLevel");
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

function wireDestinations(model: ShellModel): void {
  for (const el of document.querySelectorAll<HTMLButtonElement>(".dest")) {
    el.addEventListener("click", () => {
      for (const other of document.querySelectorAll(".dest, .level")) {
        other.classList.remove("is-selected");
      }
      el.classList.add("is-selected");
      const dest = el.dataset.dest;
      if (dest === "studio") {
        $("inspectorTitle").textContent = "Journal";
        $("inspectorBody").textContent = "Select a segment, a session plan, or a tape.";
        show("paneStudio");
      } else {
        $("inspectorTitle").textContent = "The default path";
        $("inspectorBody").textContent = "The order the tapes teach it in.";
        show("paneHome");
      }
    });
  }
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
  renderCounts(model);
  renderLevels(model);
  wireDestinations(model);
  show("paneHome");
}

void start();
