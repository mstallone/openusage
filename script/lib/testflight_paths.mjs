// Everything the shipped iOS build and its pipeline are made from. Keep the workflow isolated so
// unrelated macOS release edits cannot trip this filter. The wire-contract rule keeps the source
// boundary sound: a Mac-side change that matters to the phone must update ios/Shared/SyncWire.swift
// (docs/ios-app.md), so it always lands under ios/.
const TESTFLIGHT_FILES = new Set([
  ".github/workflows/release-ios.yml",
  "script/release_ios.sh",
  "script/testflight_distribute.mjs",
  "script/testflight_gate.mjs",
  "script/lib/appstore_connect.mjs",
  "script/lib/testflight_paths.mjs",
]);

export const isTestFlightRelevantPath = (path) =>
  path.startsWith("ios/") || TESTFLIGHT_FILES.has(path);

export const testFlightRelevantPaths = (paths) =>
  paths.filter(isTestFlightRelevantPath);
