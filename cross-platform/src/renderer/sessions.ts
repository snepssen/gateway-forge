/**
 * Sessions, and Now Playing.
 *
 * The list is whatever the main process found on disk; the transport is
 * `SessionPlayer`. This file draws and wires, and decides nothing about a
 * tape — where the pieces are, where the voice sits and what the bed does are
 * all facts recorded at assembly and read back through the ported core.
 */
import { $ } from "./dom.js";
import { timecode } from "./bed.js";
import { SessionPlayer, type OpenedSession } from "./sessionPlayer.js";
import type { AudioProfile } from "../core/audioProfile.js";

export interface SessionRow {
  key: string;
  name: string;
  level: string;
  seconds: number;
  purpose: string;
  playable: boolean;
}

export class SessionsPane {
  private readonly player: SessionPlayer;
  private rows: SessionRow[] = [];
  private frame = 0;

  constructor() {
    this.player = new SessionPlayer({
      changed: () => this.schedule(),
      failed: message => { $("nowError").textContent = message; $("nowError").hidden = false; },
    });
  }

  /** Coalesced: the transport publishes every eighty milliseconds, and the
   *  page has no reason to lay out more often than it paints. */
  private schedule(): void {
    if (this.frame !== 0) return;
    this.frame = requestAnimationFrame(() => { this.frame = 0; this.draw(); });
  }

  // ---------------------------------------------------------------- list

  async openList(): Promise<void> {
    const reply = await window.gateway.sessions();
    const list = $("sessionList");
    list.textContent = "";
    if (!reply.ok) {
      $("sessionsEmpty").textContent = reply.error;
      $("sessionsEmpty").hidden = false;
      return;
    }
    this.rows = reply.sessions;
    $("sessionsEmpty").hidden = this.rows.length > 0;
    $("sessionsEmpty").textContent =
      "No assembled tapes yet. A session appears here once it has been compiled.";
    for (const row of this.rows) {
      const li = document.createElement("li");
      const button = document.createElement("button");
      button.className = "destrow";
      button.type = "button";
      button.disabled = !row.playable;

      const title = document.createElement("span");
      title.className = "t";
      title.textContent = row.name;

      const subtitle = document.createElement("span");
      subtitle.className = "s";
      subtitle.textContent = row.playable
        ? `${timecode(row.seconds)}${row.purpose === "continuousJourney" ? " · journey" : ""}`
        : "Assembled, but its audio is gone — compile it again to listen.";

      button.append(title, subtitle);
      if (row.playable) button.addEventListener("click", () => void this.open(row.key));
      li.append(button);
      list.append(li);
    }
  }

  // ------------------------------------------------------------ playing

  private async open(key: string): Promise<void> {
    const reply = await window.gateway.openSession(key);
    if (!reply.ok) {
      $("sessionsEmpty").textContent = reply.error;
      $("sessionsEmpty").hidden = false;
      return;
    }
    const opened: OpenedSession = {
      key: reply.key, manifest: reply.manifest, sampleRate: reply.sampleRate,
      narration: new Float32Array(reply.narration),
      ...(reply.plan === undefined ? {} : { plan: reply.plan }),
      ...(reply.settling === undefined ? {} : { settling: new Float32Array(reply.settling) }),
      ...(reply.exit === undefined ? {} : { exit: new Float32Array(reply.exit) }),
    };
    this.player.load(opened);
    // The saved calibration is the file, not a pane — a session must play at
    // the listener's own levels whether or not Listening has been opened.
    const listening = await window.gateway.listening();
    if (listening.ok) this.player.apply(listening.profile);
    $("nowError").hidden = true;
    $("paneSessions").hidden = true;
    $("paneNow").hidden = false;
    this.draw();
    await this.player.play();
  }

  /** Leaving stops the sound. A transport still running behind a pane nobody
   *  can see is exactly how the Mac ended up with a bed that outlived its
   *  screen and no visible way to stop it. */
  close(): void {
    this.player.stop();
    $("paneNow").hidden = true;
  }

  toggle(): void { this.player.toggle(); }
  skip(delta: number): void { void this.player.skip(delta); }
  seekFraction(f: number): void { void this.player.seek(f * this.player.duration); }
  setScrub(f: number | undefined): void {
    this.player.scrubbing = f === undefined ? undefined : f * this.player.duration;
    this.schedule();
  }
  toggleBed(): void { this.player.setBedEnabled(!this.player.bedEnabled); }
  stay(): void { this.player.stayHere(); }
  returnToWaking(): void { void this.player.returnToWaking(); }
  recalibrate(profile: AudioProfile): void { this.player.apply(profile); }

  back(): void {
    this.close();
    $("paneSessions").hidden = false;
  }

  // ---------------------------------------------------------------- draw

  private draw(): void {
    const p = this.player;
    const track = p.track;
    if (!track) return;
    $("nowTitle").textContent =
      this.rows.find(r => r.key === track.key)?.name ?? track.key;
    $("nowElapsed").textContent = timecode(p.displayTime);
    $("nowTotal").textContent = timecode(p.duration);
    ($("nowScrub") as HTMLInputElement).value = String(p.progress);
    $("nowPlay").textContent = p.playing ? "Pause" : "Play";

    const level = p.currentLevel;
    $("nowLevel").textContent = level ?? "";
    $("nowLevel").hidden = level === undefined;
    const segment = p.currentSegment;
    $("nowSegment").textContent = segment ?? "";
    $("nowSegment").hidden = segment === undefined;

    // What the listener is hearing besides the voice, said plainly.
    const role = p.currentMediaRole;
    $("nowMedia").hidden = role === undefined;
    $("nowMedia").textContent = role === "resonantTuning"
      ? "Resonant tuning is sounding" : "Return signal is sounding";

    $("nowBed").textContent = p.bedEnabled ? "Live bed on" : "Live bed off";
    $("nowBedNote").textContent = p.bedPlan === undefined
      ? "This session has no recorded bed timeline."
      : p.bedEnabled
        ? "Driven by the session timeline."
        : "Off — narration and retained cues continue without the generated bed.";
    ($("nowBed") as HTMLButtonElement).disabled = p.bedPlan === undefined;

    $("nowCeremony").hidden = !p.resumeCeremonyActive;

    // The arrival choice: offered once, and never made by the tape running out.
    const choosing = p.arrivalHolding && !p.stayChosen;
    $("nowArrival").hidden = !choosing;
    $("nowStaying").hidden = !(p.arrivalHolding && p.stayChosen);
    $("nowReturning").hidden = !p.returningToWaking;
    $("nowReturned").hidden = !p.returnCompleted;

    this.drawTimeline();
  }

  private drawTimeline(): void {
    const p = this.player;
    const entries = p.track?.manifest.segments ?? [];
    const list = $("nowTimeline");
    const here = p.currentEntryIndex;
    if (list.childElementCount !== entries.length) {
      list.textContent = "";
      for (const [i, e] of entries.entries()) {
        const li = document.createElement("li");
        const button = document.createElement("button");
        button.type = "button";
        button.className = "piece";
        button.textContent = e.segment;
        const at = document.createElement("span");
        at.className = "at";
        at.textContent = e.startSeconds === undefined ? "" : timecode(e.startSeconds);
        button.append(at);
        button.addEventListener("click", () => void p.seekToEntry(i));
        li.append(button);
        list.append(li);
      }
    }
    for (const [i, li] of [...list.children].entries()) {
      li.firstElementChild?.classList.toggle("is-here", i === here);
    }
  }
}
