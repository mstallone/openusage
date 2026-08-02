#!/usr/bin/env node
// Distributes an already-uploaded TestFlight build to external tester groups: waits for Apple to
// finish processing it, adds it to each named group, and submits it for Beta App Review (external
// testers receive the build when Apple approves; internal groups need none of this — they get
// every build automatically). Talks to the App Store Connect API directly.
//
// Node, not Swift or bash: GitHub's Linux runners (where this runs — no Xcode needed) preinstall
// Node but no Swift toolchain, and the shared client in lib/appstore_connect.mjs mints the ES256
// JWT the API requires without any third-party dependency.
//
// Required env:
//   RUNWAY_VERSION       marketing version of the uploaded build, e.g. 0.7.1
//   RUNWAY_BUILD         CFBundleVersion of the uploaded build (git commit count)
//   APPLE_NOTARY_KEY_PATH / APPLE_NOTARY_KEY_ID / APPLE_NOTARY_ISSUER_ID
//                        App Store Connect API key (App Manager role)
//   TESTFLIGHT_EXTERNAL_GROUPS  comma-separated external group names, e.g. "External"
// Optional env:
//   RUNWAY_IOS_BUNDLE_ID        defaults to com.mattstallone.runway.mobile
//   PROCESSING_TIMEOUT_MINUTES  how long to wait for Apple's build processing (default 60)

import { createClient } from "./lib/appstore_connect.mjs";

const env = (name) => {
  const v = process.env[name];
  if (!v) {
    console.error(`Missing required env: ${name}`);
    process.exit(1);
  }
  return v;
};

const VERSION = env("RUNWAY_VERSION");
const BUILD = env("RUNWAY_BUILD");
const GROUPS = env("TESTFLIGHT_EXTERNAL_GROUPS").split(",").map((s) => s.trim()).filter(Boolean);
const BUNDLE_ID = process.env.RUNWAY_IOS_BUNDLE_ID || "com.mattstallone.runway.mobile";
const TIMEOUT_MINUTES = Number(process.env.PROCESSING_TIMEOUT_MINUTES || 60);

const api = createClient({
  keyPath: env("APPLE_NOTARY_KEY_PATH"),
  keyId: env("APPLE_NOTARY_KEY_ID"),
  issuerId: env("APPLE_NOTARY_ISSUER_ID"),
});

const fail = (message, response) => {
  console.error(message);
  if (response) console.error(JSON.stringify(response.json ?? response, null, 2));
  process.exit(1);
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const apps = await api("GET", `/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);
if (apps.status !== 200) fail("Could not query App Store Connect apps.", apps);
const app = apps.json.data?.[0];
if (!app) fail(`No App Store Connect app record for ${BUNDLE_ID} — create it first (docs/releasing.md "Release setup").`);

// The upload job finishing only means Apple received the build; it appears in the API a few
// minutes later and stays PROCESSING for a while before it can be distributed.
const deadline = Date.now() + TIMEOUT_MINUTES * 60_000;
let build;
for (;;) {
  const res = await api(
    "GET",
    `/v1/builds?filter[app]=${app.id}&filter[preReleaseVersion.version]=${VERSION}` +
      `&filter[version]=${BUILD}&sort=-uploadedDate&limit=1`,
  );
  if (res.status !== 200) fail("Could not query builds.", res);
  build = res.json.data?.[0];
  const state = build?.attributes?.processingState;
  if (state === "VALID") break;
  if (state === "FAILED" || state === "INVALID") {
    fail(`Build ${VERSION} (${BUILD}) failed App Store processing (${state}) — see App Store Connect for why.`);
  }
  if (Date.now() > deadline) {
    fail(
      build
        ? `Timed out after ${TIMEOUT_MINUTES} minutes: build ${VERSION} (${BUILD}) is still ${state}.`
        : `Timed out after ${TIMEOUT_MINUTES} minutes: build ${VERSION} (${BUILD}) never appeared — did the upload job succeed?`,
    );
  }
  console.log(build ? `Build is ${state} — waiting…` : "Build not visible in App Store Connect yet — waiting…");
  await sleep(60_000);
}
console.log(`Build ${VERSION} (${BUILD}) finished processing.`);

for (const name of GROUPS) {
  const res = await api(
    "GET",
    `/v1/betaGroups?filter[app]=${app.id}&filter[name]=${encodeURIComponent(name)}`,
  );
  if (res.status !== 200) fail(`Could not query TestFlight groups.`, res);
  const group = res.json.data?.find((g) => g.attributes.name === name);
  if (!group) {
    fail(`No TestFlight group named "${name}" — create it under TestFlight → External Testing (docs/releasing.md "Release setup").`);
  }
  if (group.attributes.isInternalGroup) {
    fail(`TestFlight group "${name}" is internal — internal groups receive every build automatically; list only external groups in TESTFLIGHT_EXTERNAL_GROUPS.`);
  }
  const add = await api("POST", `/v1/betaGroups/${group.id}/relationships/builds`, {
    data: [{ type: "builds", id: build.id }],
  });
  if (add.status !== 204) fail(`Could not add the build to group "${name}".`, add);
  console.log(`Added to external group "${name}".`);
}

const submit = await api("POST", "/v1/betaAppReviewSubmissions", {
  data: {
    type: "betaAppReviewSubmissions",
    relationships: { build: { data: { type: "builds", id: build.id } } },
  },
});
if (submit.status === 201) {
  console.log("Submitted for Beta App Review — external testers get the build when Apple approves.");
} else if (submit.status === 409 && /already/i.test(JSON.stringify(submit.json ?? {}))) {
  // A rerun of this job after a submission succeeded lands here; the build is already in review.
  console.log("Build was already submitted for Beta App Review — nothing left to do.");
} else {
  fail("Beta App Review submission failed.", submit);
}
