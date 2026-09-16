"""Gateway Forge's page, as content.

The chrome — head, rail, header, jump navigation, ecosystem grid, footer —
is build.py's, shared byte-identically with every other project here. What is
in this file is what belongs to this page alone.

Each section names an HTML partial under `sections/`, so its markup stays
markup in a file an editor understands. build.py also takes structured blocks,
which siphon's page uses, for content regular enough to be worth it.
"""

PAGE = {
    "meta": {
        "slug": "gateway-forge",
        "name": "Gateway&nbsp;Forge",
        "title": "Gateway Forge",
        "badge": "macOS, Windows and Linux · source-available",
        "fonts": "fonts.css",
        "description": "A guided-meditation assembly system and journal for the Monroe Institute's Gateway framework — the tape's own maps kept beside what was actually found, never merged.",
        "og_description": None,
        "contact_note": 'No analytics, no crash reporter, no way for a failure to reach me on its own. If you build it and something breaks, the version and platform are worth including.',
        "subhead": "A guided-meditation assembly system and journal built around the Monroe Institute's Gateway framework — the Institute's own map kept beside what was actually found, never merged into one answer.",
        "stats": [
            "<b>49</b> Focus levels, F1 through F49",
            "<b>3,672</b> checks passing",
            "<b>Local-first.</b> No cloud, ever",
            "Bed generated live, never sampled",
        ],
        "scripts": ["site.js"],
    },
    "sections": [
    {
        "eyebrow": "Why it exists",
        "heading": "The interesting part isn't the meditation. It's what happens when two maps disagree.",
        "body": "01.html",
    },
    {
        "eyebrow": "Measured",
        "heading": "A cut-off breath, measured back to a clean one",
        "body": "02.html",
    },
    {
        "id": "screenshots",
        "jump": "Screenshots",
        "eyebrow": "The app",
        "heading": "Every level is reachable, and the floor is F1",
        "body": "screenshots.html",
    },
    {
        "eyebrow": "Measured, from the source material",
        "heading": "What the tapes actually play",
        "body": "04.html",
    },
    {
        "eyebrow": "Three decisions worth naming",
        "heading": "What this app won't do",
        "body": "05.html",
    },
    {
        "id": "downloads",
        "jump": "Downloads",
        "eyebrow": "Downloads",
        "heading": "Get it",
        "body": "downloads.html",
    },
    {
        "eyebrow": "How it's built",
        "heading": "One executable, no cloud, checked by name",
        "body": "07.html",
    },
    {
        "id": "changelog",
        "jump": "Changelog",
        "eyebrow": "Changelog",
        "heading": "What changed",
        "body": "changelog.html",
    },
    {"grid": True},
    ],
    "footer": [
        "Gateway Forge · a guided-meditation assembly system for the Gateway framework ·\n  built with Swift, SwiftUI, Piper/VITS and a local Ollama model.",
    ],
}
