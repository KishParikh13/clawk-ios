# Clawk iOS — Redesign Spec

A minimal, data-integrated redesign for the Clawk iOS app. The core principle: **every screen shows how data relates across the system** — sessions, cron jobs, memory files, and approvals are never siloed.

---

## Design System

### Typography
| Role | Font | Weight | Size |
|------|------|--------|------|
| Display / titles | Space Grotesk | Bold | 28–32px |
| Section headers | Space Grotesk | SemiBold | 13px, uppercase, tracked |
| Body | Inter | Regular | 15–16px |
| Secondary / labels | Inter | Regular | 13px |
| Data / monospace | JetBrains Mono | Regular | 13px |

### Color Palette
| Token | Hex | Usage |
|-------|-----|-------|
| Background | `#F7F6F3` | All screen backgrounds |
| Text | `#1C1917` | Primary text |
| Stone | `#A8A29E` | Secondary text, disabled states |
| Terracotta | `#DC5B2B` | Accent, actions needed, CTAs |
| Green | `#22C55E` | OK status, enabled toggles |
| Red | `#EF4444` | Error status, destructive actions |
| Blue | `#3B82F6` | Memory items, links |
| Pink | `#EC4899` | Heartbeat items |

### Edge Bar Color Language
A 3px vertical bar on the left edge of every list item provides instant visual categorization:

| Color | Meaning |
|-------|---------|
| Terracotta (`#DC5B2B`) | Needs action (approvals) |
| Near-black (`#1C1917`) | Session / chat |
| Stone (`#A8A29E`) | Cron job |
| Blue (`#3B82F6`) | Memory file |
| Pink (`#EC4899`) | Heartbeat |
| Green (`#22C55E`) | Enabled / OK |
| Red (`#EF4444`) | Error |

### Spacing Rhythm
- Screen padding: 24px horizontal
- Section gap: 32px
- Group gap: 16px
- Element gap: 8px
- List item vertical padding: 14px

---

## Navigation Structure

**4 tabs** (down from the current 4, but restructured):

| Tab | Icon | Purpose |
|-----|------|---------|
| Home | `exclamationmark.circle` | Nerve center — live stats + unified activity stream |
| Chat | `bubble.left` | Session list + thread detail |
| Memory | `doc.on.doc` | Memory files grouped by project |
| Settings | `gearshape` | Connection config, display prefs, quick links |

**Key change:** Cron is accessed from Home activity stream or Settings > Cron Jobs. It no longer has its own tab. This reduces tab count while keeping cron fully accessible.

---

## Screen Specifications

### 1. Home — Nerve Center

**Purpose:** Single glance at everything happening across all agents.

**Layout:**
- **Status bar:** Green dot + "LIVE" label (left), "DASHBOARD" link with blue dot (right)
- **Title:** "clawk" in bold display type, "{n} agents connected" subtitle
- **Stats row:** Cost this week (large display type, e.g. "$47.20") | sessions count | cron count | pending count (terracotta if > 0)
- **Divider**
- **Activity stream:** "ACTIVITY" section header with "Today" right-aligned. Chronological list mixing:
  - **Approval items** — terracotta edge bar, "ACTION" badge, tool/file details
  - **Session items** — black edge bar, model name, message count, cost
  - **Cron items** — stone/green edge bar, "OK" badge, duration, next run
  - **Heartbeat items** — pink edge bar, "OK" badge, duration, next check

**Interactions:**
- Tap approval → approval detail (inline expand or push)
- Tap session → Session Detail screen
- Tap cron item → Cron Detail screen
- Tap "DASHBOARD" → open dashboard URL in browser
- Pull to refresh entire feed

**Data sources:** `DashboardAPIClient.fetchSessions()`, `fetchCronJobs()`, `gateway.pendingApprovals`

---

### 2. Session Detail

**Purpose:** Full context for a single agent session, including how it connects to other system events.

**Layout:**
- **Nav bar:** Back arrow + "Back" text
- **Title:** Session name in bold display type (e.g. "Refactor auth middleware")
- **Breadcrumb:** Model / agent / project in monospace (e.g. "Opus / claude-code / clawk-ios")
- **Stats row:** Cost | messages | time ago — all in display type with labels below
- **Token bar:** Horizontal segmented bar showing input/output/cached token distribution with monospace label (e.g. "128k in 24k out 89k cached")
- **Divider**
- **Conversation section:** "CONVERSATION" header with "Open in chat" link (terracotta). Shows alternating You/Claude messages with:
  - Sender label ("You" or "Claude" in terracotta)
  - Message text in body font
  - Tool use chips (rounded pills with icon + file path in monospace)
- **Divider**
- **Related section:** "RELATED" header showing cross-references:
  - Cron jobs triggered after this session (stone edge bar)
  - Sibling sessions in same project (black edge bar)
  - Memory files updated (blue edge bar)

**Interactions:**
- "Open in chat" → navigate to Thread view for this session
- Tap related item → navigate to that item's detail
- Scroll for full conversation

**Data sources:** `DashboardAPIClient.fetchSessionDetail()`, related items derived from project/timing correlation

---

### 3. Chat List

**Purpose:** Browse and manage all chat sessions.

**Layout:**
- **Title:** "Chat" (bold display), "+ New" button (dark pill, top-right)
- **Session list:** Each row shows:
  - Edge bar (terracotta if latest message is from "You", black otherwise)
  - Session name (bold)
  - Latest message preview with sender prefix ("You:" in terracotta or "Claude:" in default)
  - Model tag, message count, cost in monospace
  - Relative timestamp right-aligned
- **Date separators:** "Yesterday" divider between day groups

**Interactions:**
- Tap session → Thread view
- "+ New" → create new session (opens Thread with empty state)
- Pull to refresh
- Swipe to delete (future)

**Data sources:** `DashboardAPIClient.fetchSessions()` or `gateway` WebSocket session list

---

### 4. Thread — Active Chat

**Purpose:** Full conversation view with message composer.

**Layout:**
- **Nav bar:** Back arrow, session name (bold) with model/project/cost subtitle in monospace
- **Divider**
- **Message list:** Alternating messages:
  - **You:** "You" label + timestamp, message body
  - **Claude:** "Claude" label (terracotta) + timestamp, message body, tool use chips
- **Typing indicator:** "Claude" label + animated dots when agent is responding
- **Composer:** Fixed at bottom — text field ("Message this thread...") + send button (dark circle with arrow icon)

**Interactions:**
- Type message + tap send → sends via gateway WebSocket
- Auto-scroll to newest message
- Tap tool chip → expand to see tool details (future)
- Back → return to Chat List

**Data sources:** `gateway` WebSocket for real-time messages, `MessageStore` for persistence

---

### 5. Memory

**Purpose:** Browse and edit agent memory files, grouped by project.

**Layout:**
- **Title:** "Memory" (bold display), file count + total size right-aligned in monospace
- **Grouped list:** Files grouped by project scope:
  - **GLOBAL** — shared memory files (MEMORY.md, debugging.md, patterns.md)
  - **CLAWK-IOS** — project-specific files (CLAUDE.md)
  - **GATEWAY-API** — project-specific files (CLAUDE.md)
- Each row:
  - Blue edge bar
  - Filename in monospace bold
  - "Updated {time} ago · {summary keywords}" subtitle
  - File size right-aligned in monospace

**Interactions:**
- Tap file → Memory File Detail (sheet with read/edit mode)
- Pull to refresh file list

**Data sources:** `DashboardAPIClient.fetchMemoryFiles()`, `readMemoryFile()`, `updateMemoryFile()`

---

### 6. Cron List

**Purpose:** Manage all scheduled jobs and heartbeats.

**Layout:**
- **Nav bar:** Back arrow + "Cron" title, "Next wake {time}" right-aligned in monospace
- **Stats row:** enabled count (green) | disabled count | heartbeats count
- **Divider**
- **JOBS section:** Each job row:
  - Edge bar (green if enabled+OK, stone if disabled, red if error)
  - Job name (bold)
  - Schedule + agent in monospace
  - Last run time + duration, "Next: in {time}" bold
  - OK/ERR badge + toggle switch
- **HEARTBEATS section:** Same layout but with pink edge bars and average duration shown

**Interactions:**
- Toggle switch → enable/disable job inline
- Tap job → Cron Detail screen
- Back → return to previous screen

**Data sources:** `DashboardAPIClient.fetchCronJobs()`, `toggleCronJob()`, `runCronJob()`

---

### 7. Cron Detail

**Purpose:** Full detail for a single cron job with run history.

**Layout:**
- **Nav bar:** Back arrow + job name (bold), toggle switch right
- **Stats row:** Last duration | time ago | next run — display type with labels
- **Config table:** Key-value rows:
  - Schedule → cron expression in monospace
  - Agent → agent name
  - Wake mode → new-session / resume
  - Type → Cron Job / Heartbeat
- **Run Now button:** Full-width dark button with play icon
- **Divider**
- **RUN HISTORY section:** Reverse-chronological list:
  - Green/red edge bar per run
  - OK/ERR badge
  - Date + time
  - Duration in monospace
- **Delete Job button:** Full-width outlined button in red, bottom of screen

**Interactions:**
- "Run Now" → trigger immediate execution via API
- Toggle → enable/disable
- "Delete Job" → confirmation alert, then delete
- Tap history entry → expand for error details (future)

**Data sources:** `DashboardAPIClient.fetchCronJobDetail()`, `runCronJob()`, `deleteCronJob()`

---

### 8. Settings

**Purpose:** Connection configuration, display preferences, and quick navigation to secondary views.

**Layout:**
- **Title:** "Settings" (bold display)
- **CONNECTION section:** Key-value rows with monospace values:
  - Gateway Host
  - Gateway Port
  - Dashboard URL
  - Auth Token (masked)
- **DISPLAY section:**
  - Cost Display Mode → "API Equivalent" (terracotta, tappable)
  - Anthropic Subscription → toggle
  - OpenAI Subscription → toggle
- **QUICK LINKS section:** Navigation rows with counts:
  - Agents → count + chevron
  - Cron Jobs → count + chevron (→ Cron List)
  - Costs → total + chevron (→ Cost breakdown)
  - Debug Log → chevron
  - Approvals → count badge (terracotta circle) + chevron

**Interactions:**
- Tap connection fields → edit inline
- Tap Cost Display Mode → cycle between modes
- Toggle subscriptions → update cost calculation
- Tap quick link → push to relevant screen

**Data sources:** `UserDefaults` for saved config, `DashboardAPIClient` for counts

---

## Component Patterns

### Activity Row (reusable)
Used on Home and in Related sections. Consistent structure:
```
[3px edge bar] [Title + badge]          [timestamp]
               [subtitle in monospace]
```

### Stat Triplet
Used on Home, Session Detail, Cron Detail. Three values side by side:
```
[large value]  [large value]  [large value]
[small label]  [small label]  [small label]
```

### Status Badge
Small rounded pill: green background + "OK" text, or red background + "ERR", or terracotta background + "ACTION".

### Toggle Row
Cron list pattern: content left, badge + toggle right.

### Token Bar
Horizontal segmented bar showing proportional token usage. Three segments: input (dark), output (medium), cached (light).

---

## Data Integration Philosophy

The key differentiator of this redesign is **cross-referencing data across domains:**

1. **Home activity stream** mixes sessions, cron runs, and approvals in one timeline
2. **Session Detail → Related** shows cron jobs triggered after the session, sibling sessions, and memory updates
3. **Memory → grouped by project** makes it clear which files belong to which codebase
4. **Edge bar colors** create a universal visual language that works everywhere — you learn it once on Home, then recognize it on every screen
5. **Costs are ambient** — shown on Home stats, in session rows, in chat list rows — never hidden behind a dedicated "costs" screen

This means a user can:
- See an approval on Home → tap → handle it → see the session that generated it → see related memory updates
- Notice a cron failure on Home → tap → see run history → see the session that last modified the cron config
- Browse memory → see when each file was last touched and by which agent context
