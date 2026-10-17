// [lane S] Sync health on the Accounts page: per-account freshness and a link's recent syncs. Each returns null
// (nothing to add) until it's built.

/** Extra content for one account row, or null. */
export function accountRowExtras(a, g) { return null; }

/** Extra content for a link's details panel, or null. */
export function linkDetailsExtras(link) { return null; }
