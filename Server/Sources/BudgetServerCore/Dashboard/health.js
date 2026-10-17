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

/** Extra content for one account row, or null: "balance as of" (the bank's date for this account; for a group that's
 * behind and an account not synced since 0.6.0, the group's last update) and its tag. */
export function accountRowExtras(a, g) {
  const health = accountHealth(a.id);
  const behind = g.state.tone === "act" || g.state.stale;
  const asOf = (health && health.balanceAsOf) || a.balanceAsOf || (behind ? g.state.lastSync : null);
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

/** Extra content for a link's details panel, or null: its last five syncs, failed ones included. */
export function linkDetailsExtras(link) {
  const imports = (store.summary && store.summary.imports) || [];
  const recent = imports.filter((r) => r.kind === "sync" && r.linkID === link.id)
    .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt)).slice(0, 5);
  if (!recent.length) return null;
  return [h("dt", {}, "Recent syncs"), h("dd", {}, recent.map(syncLine))];
}
