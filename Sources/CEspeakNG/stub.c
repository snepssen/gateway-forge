// SwiftPM requires at least one source file to treat this as a C target.
// The real implementation is the vendored libespeak-ng.a / libucd.a in
// lib/ (built once, in ../tools-python/piper1-gpl, from the same source
// this project's Python phonemization tooling already verified working) —
// this target exists only to expose their headers as a Swift-importable
// module and link them in.
