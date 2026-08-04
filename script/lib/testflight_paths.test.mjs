import assert from "node:assert/strict";
import test from "node:test";

import {
  isTestFlightRelevantPath,
  testFlightRelevantPaths,
} from "./testflight_paths.mjs";

test("iOS source and dedicated TestFlight pipeline changes are relevant", () => {
  const relevant = [
    "ios/RunwayMobile/App/RunwayMobileApp.swift",
    "ios/Shared/SyncWire.swift",
    ".github/workflows/release-ios.yml",
    "script/decode_provisioning_profile.sh",
    "script/release_ios.sh",
    "script/testflight_distribute.mjs",
    "script/testflight_gate.mjs",
    "script/lib/appstore_connect.mjs",
    "script/lib/testflight_paths.mjs",
  ];

  for (const path of relevant) {
    assert.equal(isTestFlightRelevantPath(path), true, path);
  }
});

test("unrelated macOS release and application changes are not relevant", () => {
  const unrelated = [
    ".github/workflows/release.yml",
    ".github/workflows/landing-page.yml",
    "script/release.sh",
    "Sources/Runway/App/AppContainer.swift",
    "website/index.html",
  ];

  for (const path of unrelated) {
    assert.equal(isTestFlightRelevantPath(path), false, path);
  }
});

test("filter preserves only relevant paths and their order", () => {
  assert.deepEqual(
    testFlightRelevantPaths([
      ".github/workflows/release.yml",
      "ios/Shared/SyncWire.swift",
      "script/release.sh",
      ".github/workflows/release-ios.yml",
    ]),
    ["ios/Shared/SyncWire.swift", ".github/workflows/release-ios.yml"],
  );
});
