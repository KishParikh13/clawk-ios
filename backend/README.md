# Legacy Backend

This directory contains the old relay/dashboard backend. It is not the source of truth for the current native KishOS chat path.

The active iOS and macOS apps use `KishAgentClient` to talk directly to `kish-agent` at the configured agent URL. Keep this directory only until the remaining dashboard/gateway-dependent workflows are either deleted or replaced by native `kish-agent` endpoints.

Before deleting:

1. Confirm no active demo uses the old dashboard, relay, memory, cron, or gateway screens.
2. Remove old gateway/dashboard Swift files from the iOS target.
3. Run `scripts/verify-local.sh`.
