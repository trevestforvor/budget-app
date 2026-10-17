// [lane P] How a link's failure reads on the dashboard, and which links stand in the way of a new one. It reads the
// server's error kind (LinkSummary.errorKind, 0.6.0), never the provider's wording. No imports: core.js re-exports it.

const AT = new Intl.DateTimeFormat("en-US", { weekday: "short", hour: "numeric", minute: "2-digit" });
/// " It tries again Tue 3:40 PM." when the server has a time for the next attempt, else " It'll try again on its own."
function retry(link) {
  const next = link.nextAttemptAt ? new Date(link.nextAttemptAt) : null;
  return next && next > Date.now() ? ` It tries again ${AT.format(next)}.` : " It'll try again on its own.";
}

/// What each kind of failure means for the person, in plain words. A link stored before 0.6.0 has no kind until it
/// syncs again: it reads as waiting for a sign-in when it's parked, else as a sync that didn't finish.
export function syncProblem(link) {
  const kind = link.errorKind || (link.status === "needsReauth" ? "needsSignIn" : link.lastError ? "transient" : null);
  const plaid = link.provider === "plaid";
  switch (kind) {
    case "needsSignIn":
      return "The bank ended this connection and needs you to sign in again.";
    case "revoked":
      if (plaid && link.errorCode === "ITEM_NOT_FOUND") return "Plaid no longer has this connection. Link the bank again to carry on; its history stays.";
      return "Access to this bank was withdrawn. Link it again to carry on; its history stays.";
    case "providerSetup":
      if (/token-key|token-unsealable/.test(link.errorCode || "")) return "The server can't open its saved bank sign-ins.";
      return "This provider's setup on the server was refused. Check its keys under Settings → Bank providers.";
    case "rateLimited":
      return "The provider asked us to slow down." + retry(link);
    case "transient":
      if (/^INSTITUTION_(DOWN|NOT_RESPONDING)$/.test(link.errorCode || "")) return "The bank's service is down." + retry(link);
      return "The last sync didn't finish." + retry(link);
    default:
      return "The last sync didn't finish." + retry(link);
  }
}

/// Whether a repair is a new link rather than a sign-in: the Item is gone or access was withdrawn (update mode can't
/// bring it back, and the server refuses it).
export const needsNewLink = (link) => link.provider === "plaid" && link.errorKind === "revoked";

/// Days until a Plaid link's consent runs out, rounded up (0 on the day, negative once past); null when unknown.
export function consentDaysLeft(link, now = Date.now()) {
  if (!link.consentExpiresAt) return null;
  return Math.ceil((new Date(link.consentExpiresAt) - now) / 86400000);
}

const norm = (s) => (s || "").trim().toLowerCase();
/// The link that already holds a working Plaid Item at the bank Plaid Link just picked, so a second Item (one of the
/// Trial plan's ten, and every account twice) isn't made. The same rule as the server's exchange check: Plaid's
/// institution id when both sides have it, else the bank's name. A link whose Item is gone or whose access was
/// withdrawn doesn't count; linking again is how those come back.
export function duplicatePlaidLink(links, institutionID, name) {
  return (links || []).find((l) => {
    if (l.provider !== "plaid" || l.errorKind === "revoked") return false;
    if (l.institutionID && institutionID) return l.institutionID === institutionID;
    return !!norm(name) && norm(name) !== "plaid" && norm(l.institution) === norm(name);
  }) || null;
}
