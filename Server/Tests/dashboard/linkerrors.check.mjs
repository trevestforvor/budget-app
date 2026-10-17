// The dashboard's link-error rules (linkerrors.js), checked without a browser or any package:
//   node Server/Tests/dashboard/linkerrors.check.mjs
// Exits non-zero on the first broken rule. linkerrors.js has no imports, so it loads as it is, from its text: a
// package.json above the checkout saying "commonjs" would otherwise make Node read it as CommonJS.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync(new URL("../../Sources/BudgetServerCore/Dashboard/linkerrors.js", import.meta.url), "utf8");
const { syncProblem, needsNewLink, consentDaysLeft, duplicatePlaidLink, RELINK_OVERLAP } =
  await import("data:text/javascript," + encodeURIComponent(source));

const day = 86400000, now = Date.parse("2026-10-17T12:00:00Z");
const plaid = (fields = {}) => ({ provider: "plaid", institution: "Harbor Bank", ...fields });
let checks = 0;
const check = (name, fn) => { fn(); checks++; };

check("syncProblem reads the error kind, not the provider's words", () => {
  assert.match(syncProblem(plaid({ errorKind: "needsSignIn", lastError: "429 RATE_LIMIT" })), /sign in again/);
  assert.match(syncProblem(plaid({ errorKind: "revoked", errorCode: "ITEM_NOT_FOUND" })), /^Plaid no longer has this connection/);
  assert.match(syncProblem(plaid({ errorKind: "revoked", errorCode: "USER_PERMISSION_REVOKED" })), /^Access to this bank was withdrawn/);
  assert.match(syncProblem(plaid({ errorKind: "providerSetup", errorCode: "token-unsealable" })), /can't open its saved bank sign-ins/);
  assert.match(syncProblem(plaid({ errorKind: "providerSetup", errorCode: "INVALID_API_KEYS" })), /Bank providers/);
  assert.match(syncProblem(plaid({ errorKind: "rateLimited", nextAttemptAt: new Date(Date.now() + day).toISOString() })), /slow down\. It tries again /);
  assert.match(syncProblem(plaid({ errorKind: "transient", errorCode: "INSTITUTION_DOWN" })), /service is down\. It'll try again on its own\./);
  assert.match(syncProblem(plaid({ errorKind: "transient", nextAttemptAt: "2020-01-01T00:00:00Z" })), /didn't finish\. It'll try again on its own\./);
});

check("a link stored before 0.6.0 (no kind) reads from its status", () => {
  assert.match(syncProblem(plaid({ status: "needsReauth", lastError: "anything" })), /sign in again/);
  assert.match(syncProblem(plaid({ lastError: "ITEM_LOGIN_REQUIRED" })), /didn't finish/);
});

check("linking again says the accounts come back as new ones and the overlap counts twice", () => {
  for (const code of ["ITEM_NOT_FOUND", "USER_PERMISSION_REVOKED"]) {
    const text = syncProblem(plaid({ errorKind: "revoked", errorCode: code }));
    assert.ok(text.includes("as new ones") && text.endsWith(RELINK_OVERLAP), text);
    assert.ok(!/history stays/.test(text), text);
  }
});

check("needsNewLink: only a Plaid link whose Item is gone or access withdrawn", () => {
  assert.equal(needsNewLink(plaid({ errorKind: "revoked" })), true);
  assert.equal(needsNewLink(plaid({ errorKind: "needsSignIn" })), false);
  assert.equal(needsNewLink(plaid({})), false);
  assert.equal(needsNewLink({ provider: "simplefin", errorKind: "revoked" }), false);
});

check("consentDaysLeft rounds up, is 0 on the day and negative once past", () => {
  assert.equal(consentDaysLeft(plaid({}), now), null);
  assert.equal(consentDaysLeft(plaid({ consentExpiresAt: new Date(now + 5 * day).toISOString() }), now), 5);
  assert.equal(consentDaysLeft(plaid({ consentExpiresAt: new Date(now + 4.2 * day).toISOString() }), now), 5);
  assert.equal(consentDaysLeft(plaid({ consentExpiresAt: new Date(now + 3600000).toISOString() }), now), 1);
  assert.equal(consentDaysLeft(plaid({ consentExpiresAt: new Date(now).toISOString() }), now), 0);
  assert.equal(consentDaysLeft(plaid({ consentExpiresAt: new Date(now - 2 * day).toISOString() }), now), -2);
});

check("duplicatePlaidLink: the server's one-Item-per-bank rule", () => {
  const harbor = plaid({ id: "plaid-1", institutionID: "ins_1" });
  assert.equal(duplicatePlaidLink([harbor], "ins_1", "Something Else"), harbor, "ids decide when both are known");
  assert.equal(duplicatePlaidLink([harbor], "ins_2", "Harbor Bank"), null, "a different id with the same name links");
  const unknown = plaid({ id: "plaid-2" });
  assert.equal(duplicatePlaidLink([unknown], "ins_1", " harbor bank "), unknown, "the name decides before the id is known");
  assert.equal(duplicatePlaidLink([harbor], null, "HARBOR BANK"), harbor, "a Link that names no id goes by name");
  assert.equal(duplicatePlaidLink([plaid({ institution: "Plaid" })], null, "Plaid"), null, "\"Plaid\" names no bank");
  assert.equal(duplicatePlaidLink([plaid({ institutionID: "ins_1", errorKind: "revoked" })], "ins_1", "Harbor Bank"), null, "a gone Item doesn't block");
  assert.equal(duplicatePlaidLink([plaid({ institutionID: "ins_1", errorKind: "needsSignIn" })], "ins_1", "Harbor Bank")?.institutionID, "ins_1", "waiting for a sign-in still blocks");
  assert.equal(duplicatePlaidLink([{ provider: "simplefin", institution: "Harbor Bank" }], null, "Harbor Bank"), null, "other providers don't count");
  assert.equal(duplicatePlaidLink(undefined, "ins_1", "Harbor Bank"), null);
});

console.log(`linkerrors.js: ${checks} checks passed`);
