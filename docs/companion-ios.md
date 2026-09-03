# Gateway Companion for iPhone

The iPhone app is a local-network companion to the authoritative Gateway Forge
desktop. It carries an offline copy of the map and assembled sessions, plays
downloaded audio, sends new findings and completion records back, and can put
bounded visit or Continuous requests into the desktop render queue. The phone
does not author source or run the voice engine itself.

## Requirements

- an iPhone running iOS 17 or later;
- Xcode with an Apple account capable of development signing;
- the iPhone and Mac on the same local network;
- Gateway Forge running with **Studio → System → Companion access** enabled.

The repository does not contain a development-team id or signing certificate.
That is intentional: those identify the listener, not the project.

## First signed run

1. Connect the iPhone to the Mac, unlock it, accept **Trust This Computer** if
   asked, and enable Developer Mode if iOS requests it.
2. Open `GatewayCompanion.xcodeproj` in Xcode.
3. Select the **Gateway Companion** target, open **Signing & Capabilities**, and
   choose your Team. If Xcode says the identifier is unavailable, replace
   `local.gatewayforge.companion` with a unique reverse-DNS identifier.
4. Select the connected iPhone as the run destination and press Run.
5. On the phone, allow Camera and Local Network access. Both permissions are
   used only for QR pairing and discovery of the paired desktop.
6. In the desktop System page choose **Pair a device**. In the phone app choose
   **Scan pairing code** and scan the displayed QR before its five-minute
   expiry.

The pairing sheet has two explicit modes. **Scan** gives the camera the sheet;
**Paste link** removes the camera and shows **Paste from Clipboard** plus
**Pair with Desktop**. On the Mac, use **Copy pairing link** first. This works
particularly well through Universal Clipboard, but any private transfer to
your own phone is acceptable. Never paste the pairing link into a message,
website, shared note, or bug report: it contains the short-lived TLS secret.

The phone name should then appear in the desktop's paired-device list and the
phone should load its first snapshot.

## First acceptance pass

Perform this on deliberately non-sensitive test material first.

1. In **Explore**, confirm a Focus station labels published baseline, listener
   map, and standing note separately. Confirm visit count and signal provenance
   agree with the desktop.
2. In **Sessions**, tap **Sync now**, then download one short assembled session.
   A current session says **Complete mix · Hemi-Sync · retained cues**. The
   download is a package: narration plus any resonant-tuning and return-signal
   recordings. Interrupt Wi-Fi during the transfer, restore it, and tap
   Download again. Each ETag-specific `.partial` should resume rather than
   restart or combine bytes from another asset.
3. Play the downloaded session through headphones. Confirm narration and the
   stereo generated bed sound together, resonant tuning enters at its authored
   cue, and the retained return signal sounds at the end. Lock the phone
   briefly and confirm audio continues. Pause, resume, seek, and stop should
   move or stop the whole graph, not narration alone.
4. Download a Continuous journey. At narration end, confirm the destination
   bed continues and the mini-player says it is holding. Choose **Return to
   waking** and confirm the separately authored return narration plays before
   the retained wake-up signal; **Stop** must stop the whole graph immediately.
5. In **Sessions → Queue a session on the desktop**, queue both a visit and a
   Continuous journey. Confirm each says it was accepted and appears in the
   desktop's normal production queue exactly once.
6. Turn off Wi-Fi, save a finding, and mark a session complete. Both should be
   visible as waiting in the outbox.
7. Restore the LAN and choose **Send now** or **Sync now**. Confirm the finding
   appears once in the desktop journal and the completion appears once in
   practice activity—even if Send is tapped again after an interrupted reply.
8. Revoke the phone on the desktop and confirm subsequent sync is rejected.
   Pair again only by creating and scanning a new offer.
9. Choose **Forget this desktop** on the phone and confirm its credential,
   snapshot, pending operations, and downloaded audio are removed locally.

Both multiline editors keep Return available for intentional line breaks. Use
the keyboard toolbar's **Done** button—or drag the containing form downward—to
dismiss the keyboard. Saving a finding or beginning a pasted-link pairing also
dismisses it automatically.

Record failures with the phone iOS version, Xcode console message, desktop
listener status, and whether the failure occurred during discovery, TLS,
pairing, snapshot, download, playback, or push. Do not include pairing links,
bearer tokens, PSK material, or private journal text in a report.

## Command-line compile checks

These checks compile without a signing identity:

```sh
xcodebuild -project GatewayCompanion.xcodeproj \
  -target 'Gateway Companion' -configuration Debug \
  -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build

xcodebuild -project GatewayCompanion.xcodeproj \
  -target 'Gateway Companion' -configuration Debug \
  -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
```

They prove SDK and architecture compatibility, not camera permission, Bonjour
discovery, background playback, signing, installation, or a real LAN exchange.
Those remain physical-device acceptance checks.

An older cached snapshot intentionally cannot play as a dry narration-only
session. Sync again to receive its bed timeline and retained-asset references;
the existing narration download is reused when its ETag still matches.
