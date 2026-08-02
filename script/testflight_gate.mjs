#!/usr/bin/env node
// Decides whether a release tag needs the iOS TestFlight jobs at all. Every tag carries a new
// marketing version, so every upload puts the app through a fresh Beta App Review and pushes an
// update at every tester — pure overhead when the iOS app is byte-identical to the last release.
// Mac-only releases therefore skip the upload. Ships when ANY of:
//   - FORCE_IOS=1 (the workflow_dispatch override),
//   - there is no previous stable release tag (first release),
//   - iOS-relevant paths changed since the previous stable tag,
//   - the newest TestFlight upload is older than TESTFLIGHT_MAX_BUILD_AGE_DAYS (default 60).
//     TestFlight builds expire 90 days after upload, so an unchanged app must still re-ship
//     periodically or testers' installs go dark; 60 leaves a 30-day margin.
// Writes `ship=true|false` to $GITHUB_OUTPUT and always logs the reason. Any git or App Store
// Connect failure fails the job loudly — rerun it, or force with the workflow_dispatch input.
//
// Required env:
//   RELEASE_TAG          the tag being released, e.g. v0.8.6
//   APPLE_NOTARY_KEY_PATH / APPLE_NOTARY_KEY_ID / APPLE_NOTARY_ISSUER_ID
//                        App Store Connect API key, used only to read the newest upload's date
//                        (and only when the change check alone would skip)
// Optional env:
//   FORCE_IOS=1                     ship regardless of the delta
//   RUNWAY_IOS_BUNDLE_ID            defaults to com.mattstallone.runway.mobile
//   TESTFLIGHT_MAX_BUILD_AGE_DAYS   staleness backstop threshold (default 60)

import { appendFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { createClient } from "./lib/appstore_connect.mjs";

const env = (name) => {
  const v = process.env[name];
  if (!v) {
    console.error(`Missing required env: ${name}`);
    process.exit(1);
  }
  return v;
};

const fail = (message, response) => {
  console.error(message);
  if (response) console.error(JSON.stringify(response.json ?? response, null, 2));
  process.exit(1);
};

const decide = (ship, reason) => {
  console.log(`${ship ? "SHIP" : "SKIP"}: ${reason}`);
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `ship=${ship}\n`);
  process.exit(0);
};

// Everything the shipped iOS build and its pipeline are made from. The wire-contract rule keeps
// this filter sound: a Mac-side change that matters to the phone must update
// ios/Shared/SyncWire.swift (docs/ios-app.md), so it always lands inside ios/.
const IOS_PATHS = [
  "ios",
  "script/release_ios.sh",
  "script/testflight_distribute.mjs",
  "script/testflight_gate.mjs",
  "script/lib/appstore_connect.mjs",
  ".github/workflows/release.yml",
];

const STABLE_TAG = /^v\d+\.\d+\.\d+$/;
const TAG = env("RELEASE_TAG");
if (!STABLE_TAG.test(TAG)) fail(`Release tags must use the stable form v1.2.3 (got: ${TAG}).`);
const BUNDLE_ID = process.env.RUNWAY_IOS_BUNDLE_ID || "com.mattstallone.runway.mobile";
const MAX_AGE_DAYS = Number(process.env.TESTFLIGHT_MAX_BUILD_AGE_DAYS || 60);

// stderr passes through so a git failure explains itself before the non-zero exit.
const git = (...args) =>
  execFileSync("git", args, { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] }).trim();

if (process.env.FORCE_IOS === "1") decide(true, "FORCE_IOS is set.");

// Previous stable release = highest stable tag whose version is below this one — the same range
// rule the release changelog uses. Deliberately NOT ancestry-based: a tag created before its
// changelog squash-merge sits off main forever (it has happened), yet its tree is still what
// testers last received, and `git diff` compares trees regardless of ancestry. Version order also
// keeps a rerun of an old tag from diffing against a newer release. Inherited beta tags
// (v0.7.7-beta.1, …) never match STABLE_TAG.
const version = (t) => t.slice(1).split(".").map(Number);
const lessThan = (a, b) => {
  for (let i = 0; i < 3; i += 1) if (a[i] !== b[i]) return a[i] < b[i];
  return false;
};
const tagVersion = version(TAG);
const previous = git("tag", "--list", "--sort=-v:refname")
  .split("\n")
  .filter((t) => STABLE_TAG.test(t) && lessThan(version(t), tagVersion))[0];
if (!previous) decide(true, "no previous stable release tag — first release.");

const changed = git("diff", "--name-only", previous, TAG, "--", ...IOS_PATHS)
  .split("\n")
  .filter(Boolean);
if (changed.length) {
  decide(true, `iOS-relevant changes since ${previous}:\n  ${changed.join("\n  ")}`);
}

// Nothing changed — ship anyway if the newest upload is nearing TestFlight's 90-day expiry.
const api = createClient({
  keyPath: env("APPLE_NOTARY_KEY_PATH"),
  keyId: env("APPLE_NOTARY_KEY_ID"),
  issuerId: env("APPLE_NOTARY_ISSUER_ID"),
});

const apps = await api("GET", `/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);
if (apps.status !== 200) fail("Could not query App Store Connect apps.", apps);
const app = apps.json.data?.[0];
if (!app) {
  fail(`No App Store Connect app record for ${BUNDLE_ID} — create it first (docs/releasing.md "Release setup").`);
}

const builds = await api("GET", `/v1/builds?filter[app]=${app.id}&sort=-uploadedDate&limit=1`);
if (builds.status !== 200) fail("Could not query builds.", builds);
const newest = builds.json.data?.[0];
if (!newest) decide(true, "no TestFlight build has ever been uploaded.");

const ageDays = (Date.now() - Date.parse(newest.attributes.uploadedDate)) / 86_400_000;
if (!Number.isFinite(ageDays)) fail("Could not read the newest build's uploadedDate.", builds);
const age = `build ${newest.attributes.version} uploaded ${Math.floor(ageDays)} days ago`;
if (ageDays > MAX_AGE_DAYS) {
  decide(true, `newest TestFlight upload is stale (${age}; limit ${MAX_AGE_DAYS}, expiry 90).`);
}
decide(false, `no iOS-relevant changes since ${previous} and the newest upload is fresh (${age}).`);
