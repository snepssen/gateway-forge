/**
 * Where the voice sits, as two gains.
 *
 * Split out of `SessionExport` for one platform reason: the page's session
 * player needs this and must not reach the file system, and the exporter next
 * door to it does. The same split `audioProfile` and `audioProfileStore`
 * already make — the arithmetic on one side, the disk on the other — so that
 * a graph running in an audio thread can import the rule that decides what it
 * plays rather than a copy of it.
 *
 * The Mac keeps both in `SessionExport.swift`, where nothing forces them
 * apart. There is one law either way, and this is it.
 */

/**
 * Where a voice's two channel gains sit, **measured off `AVAudioPlayerNode`
 * rather than assumed** — `gfrender --measure-pan` on the macOS side prints
 * the table this came from:
 *
 *     pan 0.00   L 1.0000  R 1.0000   power 2.0
 *     pan 0.50   L 0.3827  R 0.9239   power 1.0
 *     pan 0.90   L 0.0785  R 0.9969   power 1.0
 *     pan 1.00   L 0.0000  R 1.0000   power 1.0
 *
 * Dead centre is unity in both ears, and *any* pan at all engages constant
 * power normalised to the sides — a 3 dB step at zero rather than a smooth
 * curve through it. That discontinuity is Apple's, and matching it is the
 * whole point: a mixdown made by a tidier law is balanced differently from the
 * session it came from.
 *
 * Keeping the step also keeps every existing recording intact. Nothing on disk
 * carries a pan, every piece therefore reads 0, and unity in both ears is
 * exactly how those sessions are mixed today.
 */
export function panGains(pan: number): { left: number; right: number } {
  const p = Math.min(1, Math.max(-1, pan));
  if (p === 0) return { left: 1, right: 1 };
  const angle = ((p + 1) * Math.PI) / 4;      // 0 at hard left, π/2 at hard right
  return { left: Math.cos(angle), right: Math.sin(angle) };
}
