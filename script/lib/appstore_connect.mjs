// Minimal App Store Connect API client shared by the TestFlight scripts
// (testflight_gate.mjs, testflight_distribute.mjs). Node's crypto mints the ES256 JWT the API
// requires without any third-party dependency.

import { readFileSync } from "node:fs";
import { createPrivateKey, sign } from "node:crypto";

// keyPath is the App Store Connect API .p8 private key; keyId and issuerId identify it.
// Returns `api(method, path, body) -> { status, json }`.
export const createClient = ({ keyPath, keyId, issuerId }) => {
  const privateKey = createPrivateKey(readFileSync(keyPath, "utf8"));
  const b64url = (data) => Buffer.from(data).toString("base64url");

  // Callers can wait on Apple longer than a token's 10-minute lifetime, so mint one per request.
  const token = () => {
    const now = Math.floor(Date.now() / 1000);
    const header = b64url(JSON.stringify({ alg: "ES256", kid: keyId, typ: "JWT" }));
    const payload = b64url(
      JSON.stringify({ iss: issuerId, iat: now, exp: now + 600, aud: "appstoreconnect-v1" }),
    );
    const signature = sign("sha256", Buffer.from(`${header}.${payload}`), {
      key: privateKey,
      dsaEncoding: "ieee-p1363", // JOSE wants the raw r||s signature, not DER
    });
    return `${header}.${payload}.${b64url(signature)}`;
  };

  return async (method, path, body) => {
    const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
      method,
      headers: { Authorization: `Bearer ${token()}`, "Content-Type": "application/json" },
      body: body ? JSON.stringify(body) : undefined,
    });
    const text = await res.text();
    return { status: res.status, json: text ? JSON.parse(text) : null };
  };
};
