import net from "net";

/**
 * Nothing leaves the house — which is a different rule from Voice Forge's,
 * and the difference is deliberate.
 *
 * Voice Forge refuses every outbound connection that is not loopback, because
 * it genuinely needs none. Gateway Forge needs two, and they are the whole
 * local-first argument rather than exceptions to it:
 *
 *   - the composer talks to Ollama on loopback, and
 *   - the companion serves a phone over the LAN.
 *
 * The companion is a *listener*, so it is untouched here: this patches
 * `connect`, and nothing that accepts a socket goes through it. What is left
 * to decide is outbound, and the answer is loopback and private address space
 * only. Anything routable refuses, loudly, naming what tried — a silent block
 * would be its own kind of lie, and this project has been bitten before by a
 * confident claim outliving the thing it described.
 *
 * The switches in `refuseToPhoneHome` cover Chromium's network stack, where
 * Chromium's own background chatter lives. They do **not** cover Node's, and
 * the main process is Node — so a `fetch` here, or in any dependency, or in
 * any future edit, would go out unseen. Voice Forge proved that the hard way:
 * a planted `fetch("https://example.com/…")` in its main process passed a
 * network check built only on `--host-resolver-rules` without registering.
 */

/** Loopback, in the forms a host string actually arrives in. */
const loopback = /^(127\.|::1$|localhost$|0:0:0:0:0:0:0:1$)/i;

/** RFC1918 and link-local — the LAN the companion is allowed to reach.
 *  Deliberately not "any address that failed to look like the internet":
 *  the list is written out so what counts as the house can be read. */
const privateSpace = [
  /^10\./,                                    // 10.0.0.0/8
  /^192\.168\./,                              // 192.168.0.0/16
  /^172\.(1[6-9]|2[0-9]|3[01])\./,            // 172.16.0.0/12
  /^169\.254\./,                              // link-local
  /^f[cd][0-9a-f]{2}:/i,                      // fc00::/7, unique local
  /^fe80:/i,                                  // link-local v6
];

/** `.local` is how Bonjour names a machine on the same network. */
const bonjour = /\.local\.?$/i;

export function isLocalHost(host: string): boolean {
  if (host === "") return true;               // a pipe or unix socket
  if (loopback.test(host)) return true;
  if (bonjour.test(host)) return true;
  return privateSpace.some(r => r.test(host));
}

export function guardOutboundSockets(onAttempt?: (host: string) => void): void {
  const realConnect = net.Socket.prototype.connect;

  net.Socket.prototype.connect = function (this: net.Socket, ...args: unknown[]) {
    const first = args[0];
    let host = "";
    if (typeof first === "object" && first !== null && "host" in first) {
      host = String((first as { host?: unknown }).host ?? "");
    } else if (typeof args[1] === "string") {
      host = args[1];
    }
    if (!isLocalHost(host)) {
      onAttempt?.(host);
      console.error(`[netguard] refused an outbound connection to ${host}`);
      throw new Error(
        `Gateway Forge does not reach past the local network (blocked: ${host})`);
    }
    return realConnect.apply(this, args as Parameters<typeof realConnect>);
  } as typeof realConnect;
}
