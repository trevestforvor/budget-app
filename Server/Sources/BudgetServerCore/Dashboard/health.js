// [lane S] Sync health on the Accounts page: per-account freshness (store.overview.accountHealth) and a link's recent
// syncs (its import records). Each returns null when there's nothing to add.
import { h, tag, store, dateShort, dateTime, accountHealth } from "./core.js";

/// "Stale since Oct 14", "Waiting for sign-in", "Statement overdue"; null when the account is current.
export function healthTag(health) {
  if (!health) return null;
  if (health.state === "stale") return tag(health.staleSince ? `Stale since ${dateShort(health.staleSince)}` : "Stale", "watch");
  if (health.state === "waitingForSignIn") return tag("Waiting for sign-in", "act");
  if (health.state === "statementsOverdue") return tag("Statement overdue", "watch");
  return null;
}

/** Extra content for one account row, or null: "balance as of" (the bank's date for this account; for one that's
 * behind without a date of its own, its own last good sync; none for a statement account, whose import date isn't the
 * statement's) and its tag. */
export function accountRowExtras(a) {
  const health = accountHealth(a.id);
  const behind = health && (health.state === "stale" || health.state === "waitingForSignIn");
  const own = a.source === "fileImport" ? null : (health && health.balanceAsOf) || a.balanceAsOf;
  const asOf = own || (behind ? health.lastGoodSync : null);
  const t = healthTag(health);
  if (!t && !asOf) return null;
  return h("div", { class: "sub" }, asOf ? `balance as of ${dateShort(asOf)}` : null, t && asOf ? " " : null, t);
}

const REASON = {
  needsSignIn: "bank needs sign-in", revoked: "access was withdrawn", providerSetup: "the server's provider setup needs fixing",
  rateLimited: "rate limited; tries again later", transient: "couldn't reach the bank",
};

/// One sync in words: "Oct 16, 3:40 PM · +12", "… · nothing new", "… · couldn't reach the bank".
function syncLine(r) {
  const failed = r.outcome === "failed";
  const added = (r.report && r.report.rowsAdded) || 0;
  const what = failed ? REASON[r.errorKind] || "didn't finish" : added ? `+${added}` : "nothing new";
  return h("div", { class: failed ? "watch-text" : null }, `${dateTime(r.createdAt)} · ${what}`);
}

/// A link's recent syncs as the server keeps them per link (`InstitutionLink.recentSyncs` in /v1/status, newest first),
/// in the import records' shape; null from a server that doesn't send them.
function linkSyncs(link) {
  const rows = (store.status && store.status.institutions) || [];
  const row = rows.find((r) => (r.syncLinkID || r.id) === link.id && r.recentSyncs && r.recentSyncs.length);
  if (!row) return null;
  return row.recentSyncs.map((s) => ({ createdAt: s.at, outcome: s.ok ? "ok" : "failed", errorKind: s.kind, report: { rowsAdded: s.rowsAdded } }));
}

/** Extra content for a link's details panel, or null: its last five syncs, failed ones included. Without the server's
 * per-link list, from /dash/summary's imports, which are the newest 50 across all links, so a link that syncs less
 * often than the others may show fewer. */
export function linkDetailsExtras(link) {
  const imports = (store.summary && store.summary.imports) || [];
  const recent = (linkSyncs(link) || imports.filter((r) => r.kind === "sync" && r.linkID === link.id))
    .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt)).slice(0, 5);
  if (!recent.length) return null;
  return [h("dt", {}, "Recent syncs"), h("dd", {}, recent.map(syncLine))];
}
