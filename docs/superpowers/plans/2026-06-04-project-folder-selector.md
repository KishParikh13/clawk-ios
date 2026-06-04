# Project Folder Selector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a conversation start in a chosen folder on the mini (default `~`), fixed for its life, with a project + branch badge in the sidebar and a folder picker (recents + browse + pinned) on iOS and Mac.

**Architecture:** Two halves ship together. The kish-agent listener (Node, on the mini) accepts a `projectPath` per chat request, validates it under `~/Code`, binds it to the thread's session, and spawns Claude/Codex with that cwd; it also exposes `/projects` and stores project + branch on each conversation record. The app (KishOSCore + iOS + Mac, Swift) sends the chosen folder, renders the picker, and shows the badge. Project + branch round-trip back through the existing `/conversations` sync.

**Tech Stack:** Node 23 (built-in `node:test`), Swift / SwiftUI, XCTest, `code-sync` over Tailscale, launchd.

**Spec:** `docs/superpowers/specs/2026-06-04-project-folder-selector-design.md`

**Repos touched:**
- Agent (Node): `~/Code/kish-agent` on the laptop (synced to the mini). Files: `listener/projects.js` (new), `listener/projects.test.js` (new), `listener/index.js` (edit).
- App (Swift): this repo `Clawk/`. Files: `KishOSCore/Conversation.swift`, `KishOSCore/AgentClient.swift`, `KishOSCore/Project.swift` (new), `KishOSCore/ProjectStore.swift` (new), `KishOSCore/KishOSWorkspace.swift`, `Clawk/ProjectPickerSheet.swift` (new, iOS), `Clawk/KishOSIOSRootView.swift`, `KishOSMac/ProjectPickerPopover.swift` (new, Mac), `KishOSMac/KishOSMacApp.swift`, tests in `KishOSMacTests/`.

---

## Phase A — Agent: project resolution, cwd binding, `/projects`

The agent is the half that actually changes the working directory. Build and verify it first so the app has a real backend.

### Task A0: Bring the agent repo local and confirm the dev loop

**Files:** none (environment setup)

- [ ] **Step 1: Pull the latest agent from the mini**

Run: `~/Scripts/code-sync.sh kish-agent pull`
Expected: rsync output, repo updated under `~/Code/kish-agent` (carries `.git`).

- [ ] **Step 2: Confirm node and the listener entry point**

Run: `node --version && ls ~/Code/kish-agent/listener/index.js`
Expected: `v23.x` (or newer) and the path prints.

- [ ] **Step 3: Confirm the restart command works**

The agent runs on the mini as launchd label `com.kishparikh.kishos-bot`. The restart command (used in later tasks) is:
`ssh kishparikh@kishs-mac-mini-1 'launchctl kickstart -k gui/$(id -u)/com.kishparikh.kishos-bot'`
Run the health check first to confirm it is up:
`curl -s http://kishs-mac-mini-1:17891/health`
Expected: `{"ok":true}`.

### Task A1: `projects.js` — path validation (pure function, TDD)

**Files:**
- Create: `~/Code/kish-agent/listener/projects.js`
- Test: `~/Code/kish-agent/listener/projects.test.js`

- [ ] **Step 1: Write the failing test**

Create `~/Code/kish-agent/listener/projects.test.js`:

```js
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { validateProjectPath } = require('./projects');

function tmpRoot() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'code-root-'));
  return fs.realpathSync(root);
}

test('validateProjectPath: null/empty means home (returns null)', () => {
  assert.strictEqual(validateProjectPath(null), null);
  assert.strictEqual(validateProjectPath(''), null);
});

test('validateProjectPath: an existing directory resolves', () => {
  const dir = tmpRoot();
  const v = validateProjectPath(dir);
  assert.strictEqual(v.path, dir);
  assert.strictEqual(v.name, path.basename(dir));
});

test('validateProjectPath: a directory anywhere (not just ~/Code) is accepted', () => {
  const outside = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'anywhere-')));
  assert.strictEqual(validateProjectPath(outside).path, outside);
});

test('validateProjectPath: nonexistent path is rejected', () => {
  const root = tmpRoot();
  assert.strictEqual(validateProjectPath(path.join(root, 'nope')).error, 'not_found');
});

test('validateProjectPath: a file (not a dir) is rejected', () => {
  const root = tmpRoot();
  const file = path.join(root, 'readme.txt');
  fs.writeFileSync(file, 'hi');
  assert.strictEqual(validateProjectPath(file).error, 'not_directory');
});

test('validateProjectPath: expands a leading ~ and collapses it in relPath', () => {
  const v = validateProjectPath('~');
  assert.strictEqual(v.path, fs.realpathSync(os.homedir()));
  assert.strictEqual(v.relPath, '~');
  const sub = fs.mkdtempSync(path.join(os.homedir(), '.kishtest-'));
  try {
    assert.ok(validateProjectPath(sub).relPath.startsWith('~/'));
  } finally {
    fs.rmdirSync(sub);
  }
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ~/Code/kish-agent/listener && node --test projects.test.js`
Expected: FAIL with `Cannot find module './projects'`.

- [ ] **Step 3: Write the minimal implementation**

Create `~/Code/kish-agent/listener/projects.js`:

```js
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { execFileSync } = require('node:child_process');

const CODE_ROOT = path.join(os.homedir(), 'Code');

function realpathSafe(p) {
  try { return fs.realpathSync(p); } catch { return null; }
}

// Expand a leading ~ so the user can paste paths like "~/Code/foo" or "~/Desktop".
function expandHome(input) {
  const str = String(input);
  if (str === '~') return os.homedir();
  if (str.startsWith('~/')) return path.join(os.homedir(), str.slice(2));
  return str;
}

// Display form: collapse the home prefix back to ~ for readability.
function homeRelative(resolved) {
  const home = os.homedir();
  if (resolved === home) return '~';
  if (resolved.startsWith(home + path.sep)) return '~' + resolved.slice(home.length);
  return resolved;
}

// Any existing directory the user names is valid — the agent already runs from
// home with full access, so a chosen folder is never broader than the default.
// Returns: null (home/default), {error} (missing or not a dir), or {path, name, relPath}.
function validateProjectPath(input) {
  if (input == null || String(input).trim() === '') return null;
  const resolved = realpathSafe(path.resolve(expandHome(String(input).trim())));
  if (!resolved) return { error: 'not_found' };
  let stat;
  try { stat = fs.statSync(resolved); } catch { return { error: 'not_found' }; }
  if (!stat.isDirectory()) return { error: 'not_directory' };
  return { path: resolved, name: path.basename(resolved), relPath: homeRelative(resolved) };
}

module.exports = { CODE_ROOT, realpathSafe, validateProjectPath };
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ~/Code/kish-agent/listener && node --test projects.test.js`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
cd ~/Code/kish-agent
git add listener/projects.js listener/projects.test.js
git commit -m "feat(agent): add project path validation under ~/Code"
```

### Task A2: `projects.js` — `gitBranch` and `listProjects` (TDD)

**Files:**
- Modify: `~/Code/kish-agent/listener/projects.js`
- Test: `~/Code/kish-agent/listener/projects.test.js`

- [ ] **Step 1: Add failing tests**

Append to `~/Code/kish-agent/listener/projects.test.js`:

```js
const { listProjects, gitBranch } = require('./projects');
const cp = require('node:child_process');

test('listProjects: recents filters to dirs modified within recentDays', () => {
  const root = tmpRoot();
  const now = Date.now();
  fs.mkdirSync(path.join(root, 'fresh'));
  fs.mkdirSync(path.join(root, 'stale'));
  // Backdate "stale" to 30 days ago.
  const old = new Date(now - 30 * 864e5);
  fs.utimesSync(path.join(root, 'stale'), old, old);
  const recents = listProjects(root, { all: false, recentDays: 7, now });
  const names = recents.map((p) => p.name);
  assert.ok(names.includes('fresh'));
  assert.ok(!names.includes('stale'));
});

test('listProjects: all=true returns every dir sorted by name', () => {
  const root = tmpRoot();
  fs.mkdirSync(path.join(root, 'zebra'));
  fs.mkdirSync(path.join(root, 'apple'));
  fs.mkdirSync(path.join(root, '.hidden'));
  const all = listProjects(root, { all: true });
  assert.deepStrictEqual(all.map((p) => p.name), ['apple', 'zebra']);
});

test('listProjects: entries carry path, relPath, lastModified', () => {
  const root = tmpRoot();
  fs.mkdirSync(path.join(root, 'proj'));
  const [p] = listProjects(root, { all: true });
  assert.strictEqual(p.path, path.join(root, 'proj'));
  assert.strictEqual(p.relPath, 'proj');
  assert.ok(typeof p.lastModified === 'string' && p.lastModified.length > 0);
});

test('gitBranch: returns branch for a repo, null otherwise', () => {
  const root = tmpRoot();
  const repo = path.join(root, 'repo');
  fs.mkdirSync(repo);
  cp.execFileSync('git', ['-C', repo, 'init', '-b', 'main'], { stdio: 'ignore' });
  assert.strictEqual(gitBranch(repo), 'main');
  const plain = path.join(root, 'plain');
  fs.mkdirSync(plain);
  assert.strictEqual(gitBranch(plain), null);
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd ~/Code/kish-agent/listener && node --test projects.test.js`
Expected: FAIL with `listProjects is not a function`.

- [ ] **Step 3: Implement**

Edit `~/Code/kish-agent/listener/projects.js`. Add before `module.exports`:

```js
function gitBranch(dir) {
  try {
    const out = execFileSync('git', ['-C', dir, 'rev-parse', '--abbrev-ref', 'HEAD'], {
      encoding: 'utf8',
      timeout: 2000,
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
    return out || null;
  } catch {
    return null;
  }
}

function listProjects(codeRoot = CODE_ROOT, { all = false, recentDays = 7, now = Date.now() } = {}) {
  let entries;
  try { entries = fs.readdirSync(codeRoot, { withFileTypes: true }); } catch { return []; }
  const cutoff = now - recentDays * 864e5;
  const projects = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name.startsWith('.')) continue;
    const full = path.join(codeRoot, entry.name);
    let stat;
    try { stat = fs.statSync(full); } catch { continue; }
    if (!all && stat.mtimeMs < cutoff) continue;
    projects.push({
      name: entry.name,
      path: full,
      relPath: entry.name,
      branch: gitBranch(full),
      lastModified: new Date(stat.mtimeMs).toISOString(),
    });
  }
  projects.sort((a, b) =>
    all ? a.name.localeCompare(b.name) : Date.parse(b.lastModified) - Date.parse(a.lastModified));
  return projects;
}
```

Update the exports line to:

```js
module.exports = { CODE_ROOT, realpathSafe, validateProjectPath, gitBranch, listProjects };
```

- [ ] **Step 4: Run to verify pass**

Run: `cd ~/Code/kish-agent/listener && node --test projects.test.js`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
cd ~/Code/kish-agent
git add listener/projects.js listener/projects.test.js
git commit -m "feat(agent): list projects (recents + all) and resolve git branch"
```

### Task A3: Wire cwd binding into `runClaude` / `runCodex`

The two spawn helpers hardcode `cwd: AGENT_CWD`. Thread a `cwd` argument through so a caller can override it.

**Files:**
- Modify: `~/Code/kish-agent/listener/index.js` (`runClaude` ~line 603, `runCodex` ~line 666)

- [ ] **Step 1: Add `cwd` param to `runClaude`**

In `~/Code/kish-agent/listener/index.js`, change the signature:

```js
async function runClaude(prompt, resumeSessionId, onEvent, cwd = AGENT_CWD) {
```

and the spawn line inside it:

```js
    const child = spawn(CLAUDE_BIN, args, { cwd, stdio: ['ignore', 'pipe', 'pipe'] });
```

- [ ] **Step 2: Add `cwd` param to `runCodex`**

Change the `runCodex` signature (currently `runCodex(prompt, _resumeId, onEvent, imagePaths = [])`):

```js
async function runCodex(prompt, _resumeId, onEvent, imagePaths = [], cwd = AGENT_CWD) {
```

and its spawn line:

```js
    const child = spawn(CODEX_BIN, args, { cwd, stdio: ['ignore', 'pipe', 'pipe'] });
```

- [ ] **Step 3: Verify the file still parses**

Run: `node --check ~/Code/kish-agent/listener/index.js`
Expected: no output (exit 0).

- [ ] **Step 4: Commit**

```bash
cd ~/Code/kish-agent
git add listener/index.js
git commit -m "refactor(agent): allow per-run cwd override in runClaude/runCodex"
```

### Task A4: Bind the project folder per thread in `runHttpTurn`

The folder is chosen on the first turn, persisted on the thread state, and reused for the conversation's life. If a previously bound folder vanishes, fall back to `$HOME`.

**Files:**
- Modify: `~/Code/kish-agent/listener/index.js` (`runHttpTurn` ~line 1970; the run dispatch ~line 2020 with `runCodex`/`runClaude`)

- [ ] **Step 1: Require the projects module**

At the top of `index.js`, alongside the other `require(...)` lines, add:

```js
const { validateProjectPath, gitBranch } = require('./projects');
```

- [ ] **Step 2: Resolve the bound cwd before the run**

In `runHttpTurn`, immediately after `const startedAt = Date.now();` (just before `const uploadDir = await makeUploadDir();`), insert:

```js
  // Bind the project folder on the first turn; reuse it thereafter (fixed for the conversation).
  let runCwd = AGENT_CWD;
  let boundProject = null;
  if (state.projectPath) {
    if (fs.existsSync(state.projectPath)) {
      runCwd = state.projectPath;
      boundProject = { path: state.projectPath, name: state.projectName || path.basename(state.projectPath), branch: gitBranch(state.projectPath) };
    } else {
      emit({ type: 'activity', text: `project folder missing, running from home` });
    }
  } else if (input.projectPath) {
    const resolved = validateProjectPath(input.projectPath);
    if (resolved && resolved.error) {
      return earlyOutput({ ok: false, threadId, engine, error: `invalid project folder (${resolved.error})` });
    }
    if (resolved) {
      state.projectPath = resolved.path;
      state.projectName = resolved.name;
      setThreadState(threadKey, state);
      runCwd = resolved.path;
      boundProject = { path: resolved.path, name: resolved.name, branch: gitBranch(resolved.path) };
    }
  }
```

(`path` is already required at the top of `index.js`; `fs` likewise.)

- [ ] **Step 3: Pass `boundProject` into the conversation record**

Change the `beginSharedConversationTurn(input, threadId, engine, runText)` call (in `runHttpTurn`) to:

```js
  const conversationId = beginSharedConversationTurn(input, threadId, engine, runText, boundProject);
```

- [ ] **Step 4: Pass `runCwd` into the run dispatch**

Change the run dispatch (the `engine === 'codex' ? await runCodex(...) : await runClaude(...)` expression) to:

```js
    const result =
      engine === 'codex'
        ? await runCodex(buildCodexPrompt(promptText, uploadDir, null), resumeId, onEvent, attached.imagePaths, runCwd)
        : await runClaude(buildHttpPrompt(promptText, uploadDir), resumeId, onEvent, runCwd);
```

- [ ] **Step 5: Store project fields on the conversation record**

In `beginSharedConversationTurn`, change the signature to accept the project, and set the fields on both the new and existing record. Replace the function header and the `conversations.unshift({...})` block so the new-record literal includes the three fields, and add an update for the existing record. Concretely:

Signature:

```js
function beginSharedConversationTurn(input, threadId, engine, message, project) {
```

In the `if (index === -1)` new-record object literal, add after `approvals: [],`:

```js
      projectPath: project ? project.path : null,
      projectName: project ? project.name : null,
      branch: project ? project.branch : null,
```

After `const conversation = conversations[index];` (the existing-record branch further down in the same function), add:

```js
  if (project) {
    conversation.projectPath = project.path;
    conversation.projectName = project.name;
    conversation.branch = project.branch;
  }
```

- [ ] **Step 6: Verify the file parses**

Run: `node --check ~/Code/kish-agent/listener/index.js`
Expected: exit 0, no output.

- [ ] **Step 7: Commit**

```bash
cd ~/Code/kish-agent
git add listener/index.js
git commit -m "feat(agent): bind conversation to a project folder as cwd, persist on record"
```

### Task A5: Add the `GET /projects` route

**Files:**
- Modify: `~/Code/kish-agent/listener/index.js` (HTTP request handler — the block routing `url.pathname`, near the existing `/chat` and `/chat-stream` handlers ~line 1773)

- [ ] **Step 1: Locate the router**

Find the request handler where `url.pathname` is compared (it already handles `/chat-stream`, `/chat`, `/conversations`, `/tools`, `/health`, `/approve`, `/attachments`). Confirm with:
Run: `grep -n "url.pathname ===" ~/Code/kish-agent/listener/index.js`
Expected: a list of route comparisons.

- [ ] **Step 2: Add the route**

Add this branch alongside the other `GET` routes (e.g. just before the `/conversations` GET handler). Use the same response helper the neighboring routes use (they use `sendJson(res, obj)` or an inline `res.writeHead(...); res.end(JSON.stringify(...))` — match whichever the file already uses for `/tools`):

```js
      if (req.method === 'GET' && url.pathname === '/projects') {
        const all = url.searchParams.get('all') === '1';
        try {
          const projects = listProjects(undefined, { all });
          sendJson(res, { ok: true, projects });
        } catch (e) {
          sendJson(res, { ok: false, error: String(e && e.message || e), projects: [] });
        }
        return;
      }
```

Also add `listProjects` to the existing `require('./projects')` line from Task A4 Step 1:

```js
const { validateProjectPath, gitBranch, listProjects } = require('./projects');
```

> Note: if the file does not have a `sendJson` helper, match the exact pattern used by the `/tools` GET handler (find it with `grep -n "pathname === '/tools'" index.js` and copy its response style).

- [ ] **Step 3: Verify parse**

Run: `node --check ~/Code/kish-agent/listener/index.js`
Expected: exit 0.

- [ ] **Step 4: Commit**

```bash
cd ~/Code/kish-agent
git add listener/index.js
git commit -m "feat(agent): GET /projects returns recents and full list with branch"
```

### Task A6: Deploy to the mini and verify end to end with curl

**Files:** none (deploy + verification)

- [ ] **Step 1: Push the repo to the mini**

Run: `~/Scripts/code-sync.sh kish-agent push`
Expected: rsync output. (Confirm no git op is running on the mini first.)

- [ ] **Step 2: Restart the agent**

Run: `ssh kishparikh@kishs-mac-mini-1 'launchctl kickstart -k gui/$(id -u)/com.kishparikh.kishos-bot'`
Then: `sleep 2 && curl -s http://kishs-mac-mini-1:17891/health`
Expected: `{"ok":true}`.

- [ ] **Step 3: Verify `/projects` recents**

Run: `curl -s http://kishs-mac-mini-1:17891/projects | python3 -m json.tool | head -40`
Expected: `ok: true`, a `projects` array of folders modified in the last 7 days, each with `name`, `path`, `relPath`, `branch`, `lastModified`.

- [ ] **Step 4: Verify `/projects?all=1`**

Run: `curl -s 'http://kishs-mac-mini-1:17891/projects?all=1' | python3 -c "import sys,json;d=json.load(sys.stdin);print(len(d['projects']),'projects'); print([p['name'] for p in d['projects'][:5]])"`
Expected: a count near the number of dirs in `~/Code`, names sorted alphabetically.

- [ ] **Step 5: Verify cwd binding actually changes the working directory**

Run a one-shot chat bound to a known repo and ask Claude where it is:
```bash
curl -s -X POST http://kishs-mac-mini-1:17891/chat \
  -H 'Content-Type: application/json' \
  -d '{"threadId":"proj-test-1","conversationId":"00000000-0000-0000-0000-0000000000a1","message":"run pwd and reply with only the output","projectPath":"/Users/kishparikh/Code/clawk-ios"}' \
  | python3 -m json.tool
```
Expected: reply text contains `/Users/kishparikh/Code/clawk-ios`.

- [ ] **Step 6: Verify the binding is fixed (second turn ignores a different folder)**

```bash
curl -s -X POST http://kishs-mac-mini-1:17891/chat \
  -H 'Content-Type: application/json' \
  -d '{"threadId":"proj-test-1","conversationId":"00000000-0000-0000-0000-0000000000a1","message":"run pwd again","projectPath":"/Users/kishparikh/Code/kish-agent"}' \
  | python3 -m json.tool
```
Expected: still `/Users/kishparikh/Code/clawk-ios` (first binding wins).

- [ ] **Step 7: Verify a nonexistent folder is rejected**

```bash
curl -s -X POST http://kishs-mac-mini-1:17891/chat \
  -H 'Content-Type: application/json' \
  -d '{"threadId":"proj-test-bad","conversationId":"00000000-0000-0000-0000-0000000000b1","message":"hi","projectPath":"/Users/kishparikh/Code/does-not-exist-xyz"}' \
  | python3 -m json.tool
```
Expected: `ok: false`, error contains `invalid project folder (not_found)`. (A folder *outside* `~/Code` is now accepted by design — only missing paths and files are rejected.)

- [ ] **Step 8: Verify the conversation record carries project + branch**

Run: `curl -s http://kishs-mac-mini-1:17891/conversations | python3 -c "import sys,json;d=json.load(sys.stdin);c=[x for x in d['conversations'] if x['id']=='00000000-0000-0000-0000-0000000000a1'][0];print(c.get('projectPath'),c.get('projectName'),c.get('branch'))"`
Expected: `/Users/kishparikh/Code/clawk-ios clawk-ios <branch>`.

- [ ] **Step 9: Clean up the test conversations**

```bash
curl -s -X DELETE http://kishs-mac-mini-1:17891/conversations/00000000-0000-0000-0000-0000000000a1 >/dev/null
curl -s -X DELETE http://kishs-mac-mini-1:17891/conversations/00000000-0000-0000-0000-0000000000b1 >/dev/null
echo done
```

- [ ] **Step 10: Push the agent commits to its git remote (if one exists)**

Run: `cd ~/Code/kish-agent && git push 2>/dev/null || echo "no remote, local commits only"`
Expected: pushed, or the no-remote note.

---

## Phase B — KishOSCore: model, client, project store

All edits in this phase are in `Clawk/KishOSCore` (shared by iOS and Mac). Build/test with the `KishOSMac` scheme, which compiles KishOSCore and runs `KishOSMacTests`.

The test command used throughout (run from repo root `Clawk/`):
`xcodebuild test -project Clawk.xcodeproj -scheme KishOSMac -destination 'platform=macOS' -only-testing:KishOSMacTests/<Class>/<method> | xcpretty || true`
If `xcpretty` is absent, drop the pipe. To run a whole class, omit the `/<method>`.

### Task B1: Add `projectPath` / `projectName` / `branch` to `Conversation` (TDD)

**Files:**
- Modify: `Clawk/KishOSCore/Conversation.swift` (struct fields ~line 4, `CodingKeys` ~line 17, designated `init` ~line 32, `init(from:)` ~line 53)
- Test: `Clawk/KishOSMacTests/ConversationTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Clawk/KishOSMacTests/ConversationTests.swift`:

```swift
func testConversationDefaultsToHomeProject() {
    let convo = Conversation(firstMessage: "hello")
    XCTAssertNil(convo.projectPath)
    XCTAssertNil(convo.projectName)
    XCTAssertNil(convo.branch)
}

func testConversationStoresProjectFields() {
    let convo = Conversation(firstMessage: "hi", projectPath: "/Users/k/Code/clawk-ios", projectName: "clawk-ios")
    XCTAssertEqual(convo.projectPath, "/Users/k/Code/clawk-ios")
    XCTAssertEqual(convo.projectName, "clawk-ios")
}

func testConversationDecodesWithoutProjectFields() throws {
    // Older records have no project keys; decoding must not throw and must default to nil.
    let json = """
    {"id":"\(UUID().uuidString)","threadId":"mac-x","title":"t","idea":"i","messages":[],
     "events":[],"engine":"claude","isRunning":false,"updatedAt":"2026-06-04T00:00:00Z","approvals":[]}
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let convo = try decoder.decode(Conversation.self, from: json)
    XCTAssertNil(convo.projectPath)
}

func testConversationProjectFieldsRoundTrip() throws {
    var convo = Conversation(firstMessage: "hi", projectPath: "/Users/k/Code/p", projectName: "p")
    convo.branch = "main"
    let data = try JSONEncoder().encode(convo)
    let decoded = try JSONDecoder().decode(Conversation.self, from: data)
    XCTAssertEqual(decoded.projectPath, "/Users/k/Code/p")
    XCTAssertEqual(decoded.projectName, "p")
    XCTAssertEqual(decoded.branch, "main")
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -project Clawk.xcodeproj -scheme KishOSMac -destination 'platform=macOS' -only-testing:KishOSMacTests/ConversationTests`
Expected: COMPILE FAILURE — `extra argument 'projectPath'` / no member `projectPath`.

- [ ] **Step 3: Add the stored properties**

In `Clawk/KishOSCore/Conversation.swift`, after `var approvals: [ApprovalRequest]` (line 15) add:

```swift
    var projectPath: String?
    var projectName: String?
    var branch: String?
```

- [ ] **Step 4: Add the coding keys**

In the `CodingKeys` enum, after `case approvals` add:

```swift
        case projectPath
        case projectName
        case branch
```

- [ ] **Step 5: Set defaults in the designated init**

Change the designated initializer signature (currently `init(id:threadId:firstMessage:now:)`) to add two params before `now`:

```swift
    init(
        id: UUID = UUID(),
        threadId: String? = nil,
        firstMessage: String,
        projectPath: String? = nil,
        projectName: String? = nil,
        now: Date = Date()
    ) {
```

and inside, after `self.approvals = []`:

```swift
        self.projectPath = projectPath
        self.projectName = projectName
        self.branch = nil
```

- [ ] **Step 6: Decode with back-compat**

In `init(from decoder:)`, after the `approvals = ...` line add:

```swift
        projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath)
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
```

- [ ] **Step 7: Run to verify pass**

Run: `xcodebuild test -project Clawk.xcodeproj -scheme KishOSMac -destination 'platform=macOS' -only-testing:KishOSMacTests/ConversationTests`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Clawk/KishOSCore/Conversation.swift Clawk/KishOSMacTests/ConversationTests.swift
git commit -m "feat(core): add project + branch fields to Conversation"
```

### Task B2: `Project` value type and `ProjectListResponse` decoding (TDD)

**Files:**
- Create: `Clawk/KishOSCore/Project.swift`
- Test: `Clawk/KishOSMacTests/ProjectTests.swift` (new)
- Modify: `Clawk/Clawk.xcodeproj/project.pbxproj` (add both files to the KishOSCore + test targets — see Step 0)

- [ ] **Step 0: Add the new files to the Xcode project**

This project uses `project.yml` (XcodeGen — confirmed present at `Clawk/project.yml`). New files under `KishOSCore/` and `KishOSMacTests/` are picked up by regenerating. After creating the files in later steps, run:
Run: `cd Clawk && ls generate-project.sh xcodegen 2>/dev/null; which xcodegen`
If `xcodegen` is available: `cd Clawk && xcodegen generate` (or run the repo's `generate-project.sh`). If not, add the file references manually in Xcode. Verify the new files appear in the `KishOSCore` group and `ProjectTests.swift` in `KishOSMacTests`.

- [ ] **Step 1: Write the failing test**

Create `Clawk/KishOSMacTests/ProjectTests.swift`:

```swift
import XCTest
@testable import KishOSCore

final class ProjectTests: XCTestCase {
    func testDecodeProjectListResponse() throws {
        let json = """
        {"ok":true,"projects":[
          {"name":"clawk-ios","path":"/Users/k/Code/clawk-ios","relPath":"clawk-ios","branch":"main","lastModified":"2026-06-04T00:00:00Z"},
          {"name":"plain","path":"/Users/k/Code/plain","relPath":"plain","branch":null,"lastModified":"2026-06-01T00:00:00Z"}
        ]}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(ProjectListResponse.self, from: json)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.projects.count, 2)
        XCTAssertEqual(response.projects[0].name, "clawk-ios")
        XCTAssertEqual(response.projects[0].branch, "main")
        XCTAssertNil(response.projects[1].branch)
        XCTAssertEqual(response.projects[0].id, "/Users/k/Code/clawk-ios")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -project Clawk.xcodeproj -scheme KishOSMac -destination 'platform=macOS' -only-testing:KishOSMacTests/ProjectTests`
Expected: COMPILE FAILURE — no type `ProjectListResponse`.

- [ ] **Step 3: Implement**

Create `Clawk/KishOSCore/Project.swift`:

```swift
import Foundation

public struct Project: Identifiable, Codable, Equatable {
    public var name: String
    public var path: String
    public var relPath: String
    public var branch: String?
    public var lastModified: Date?

    public var id: String { path }

    public init(name: String, path: String, relPath: String, branch: String? = nil, lastModified: Date? = nil) {
        self.name = name
        self.path = path
        self.relPath = relPath
        self.branch = branch
        self.lastModified = lastModified
    }
}

public struct ProjectListResponse: Decodable {
    public let ok: Bool
    public let projects: [Project]
    public let error: String?
}
```

> Note on access control: check whether existing KishOSCore types (e.g. `Conversation`) are declared `public`. They are NOT (the module is compiled into the same targets). If the rest of KishOSCore uses no `public` keyword, drop `public` here to match. Confirm with `grep -n "^public\|^struct Conversation" Clawk/KishOSCore/Conversation.swift` and mirror the prevailing style.

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -project Clawk.xcodeproj -scheme KishOSMac -destination 'platform=macOS' -only-testing:KishOSMacTests/ProjectTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Clawk/KishOSCore/Project.swift Clawk/KishOSMacTests/ProjectTests.swift Clawk/project.yml Clawk/Clawk.xcodeproj/project.pbxproj
git commit -m "feat(core): add Project model and ProjectListResponse"
```

### Task B3: `fetchProjects` on `KishAgentClient`, and `projectPath` in `ChatRequest`

**Files:**
- Modify: `Clawk/KishOSCore/AgentClient.swift` (`sendStreaming` ~line 165, `send` ~line 117, `ChatRequest` ~line 560, add `fetchProjects` near `fetchToolInventory` ~line 319)
- Test: `Clawk/KishOSMacTests/AgentClientTests.swift`

- [ ] **Step 1: Write the failing test for `projectPath` encoding**

The existing `AgentClientTests.swift` already stubs URLSession and decodes the request body (see `TestChatRequestAttachment` ~line 466). Add a sibling test that asserts `projectPath` is encoded. Add to `AgentClientTests.swift`:

```swift
func testSendStreamingEncodesProjectPath() async throws {
    let (client, recorder) = makeStreamingClient(finalText: "ok")
    _ = try await client.sendStreaming(
        "hello",
        threadId: "mac-1",
        conversationId: UUID(),
        projectPath: "/Users/k/Code/clawk-ios"
    ) { _ in }
    let body = try recorder.decodedChatRequestBody()
    XCTAssertEqual(body.projectPath, "/Users/k/Code/clawk-ios")
}
```

In the test's request-body struct (the `private struct` that decodes the posted JSON, near `TestChatRequestAttachment` ~line 463), add:

```swift
    let projectPath: String?
```

> If the existing tests use a different helper than `makeStreamingClient`/`decodedChatRequestBody`, mirror the exact helper names already in `AgentClientTests.swift` (read the file's existing streaming test and copy its harness). The assertion (`body.projectPath == ...`) is the point.

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -project Clawk.xcodeproj -scheme KishOSMac -destination 'platform=macOS' -only-testing:KishOSMacTests/AgentClientTests`
Expected: COMPILE FAILURE — `sendStreaming` has no `projectPath:` parameter.

- [ ] **Step 3: Add `projectPath` to `ChatRequest`**

In `AgentClient.swift`, the `private struct ChatRequest` (line 560). Add the property and coding key, and encode it. After `let attachments: [ChatRequestAttachment]` add:

```swift
    let projectPath: String?
```

In its `CodingKeys`, after `case attachments` add:

```swift
        case projectPath
```

In its `encode(to:)`, encode the optional only when present (matches the file's existing conditional-encode style):

```swift
        try container.encodeIfPresent(projectPath, forKey: .projectPath)
```

- [ ] **Step 4: Thread `projectPath` through `sendStreaming` and `send`**

In `sendStreaming` (line 165), add a parameter after `attachments`:

```swift
        attachments: [ChatRequestAttachment] = [],
        projectPath: String? = nil,
        onEvent: @escaping (AgentStreamEvent) async -> Void
```

and update the `ChatRequest(...)` construction (line 182):

```swift
            request.httpBody = try JSONEncoder().encode(ChatRequest(threadId: threadId, message: message, conversationId: conversationId, attachments: attachments, projectPath: projectPath))
```

In `send` (line 117), add `projectPath: String? = nil` before the closing paren of its signature and pass it into its `ChatRequest(...)` (find that struct construction inside `send` and add `, projectPath: projectPath`). If `send`'s `ChatRequest` omits `conversationId`, keep that as-is and only add `projectPath`.

- [ ] **Step 5: Add `fetchProjects`**

In `AgentClient.swift`, near `fetchToolInventory` (line 319), add:

```swift
    func fetchProjects(all: Bool = false) async throws -> [Project] {
        var components = URLComponents(url: baseURL.appendingPathComponent("projects"), resolvingAgainstBaseURL: false)
        if all {
            components?.queryItems = [URLQueryItem(name: "all", value: "1")]
        }
        guard let url = components?.url else {
            throw AgentClientError.requestFailed("Bad projects URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = try Self.decoder.decode(ProjectListResponse.self, from: data)
        guard statusCode == 200 && decoded.ok else {
            throw AgentClientError.requestFailed(decoded.error ?? "Projects returned HTTP \(statusCode)")
        }
        return decoded.projects
    }
```

(`Self.decoder` already exists with `.iso8601` date decoding.)

- [ ] **Step 6: Run to verify pass**

Run: `xcodebuild test -project Clawk.xcodeproj -scheme KishOSMac -destination 'platform=macOS' -only-testing:KishOSMacTests/AgentClientTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Clawk/KishOSCore/AgentClient.swift Clawk/KishOSMacTests/AgentClientTests.swift
git commit -m "feat(core): send projectPath and fetch /projects from the agent client"
```

### Task B4: `ProjectStore` — pinned folders in UserDefaults (TDD)

**Files:**
- Create: `Clawk/KishOSCore/ProjectStore.swift`
- Test: `Clawk/KishOSMacTests/ProjectStoreTests.swift` (new; add to project per Task B2 Step 0)

- [ ] **Step 1: Write the failing test**

Create `Clawk/KishOSMacTests/ProjectStoreTests.swift`:

```swift
import XCTest
@testable import KishOSCore

final class ProjectStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "ProjectStoreTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    func testStartsEmpty() {
        let store = ProjectStore(userDefaults: makeDefaults())
        XCTAssertTrue(store.pinned.isEmpty)
    }

    func testPinAddsAndDedupes() {
        let store = ProjectStore(userDefaults: makeDefaults())
        store.pin(path: "/Users/k/Code/a", name: "a")
        store.pin(path: "/Users/k/Code/a", name: "a")
        store.pin(path: "/Users/k/Code/b", name: "b")
        XCTAssertEqual(store.pinned.map(\.path), ["/Users/k/Code/b", "/Users/k/Code/a"])
    }

    func testPinPersistsAcrossInstances() {
        let defaults = makeDefaults()
        ProjectStore(userDefaults: defaults).pin(path: "/Users/k/Code/a", name: "a")
        let reloaded = ProjectStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.pinned.map(\.name), ["a"])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -project Clawk.xcodeproj -scheme KishOSMac -destination 'platform=macOS' -only-testing:KishOSMacTests/ProjectStoreTests`
Expected: COMPILE FAILURE — no type `ProjectStore`.

- [ ] **Step 3: Implement**

Create `Clawk/KishOSCore/ProjectStore.swift`:

```swift
import Foundation

struct PinnedProject: Codable, Equatable, Identifiable {
    var path: String
    var name: String
    var id: String { path }
}

@MainActor
final class ProjectStore: ObservableObject {
    private static let key = "KishOSPinnedProjects"
    @Published private(set) var pinned: [PinnedProject]
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([PinnedProject].self, from: data) {
            self.pinned = decoded
        } else {
            self.pinned = []
        }
    }

    // Most-recently pinned first; pinning an existing path moves it to the front.
    func pin(path: String, name: String) {
        pinned.removeAll { $0.path == path }
        pinned.insert(PinnedProject(path: path, name: name), at: 0)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(pinned) {
            userDefaults.set(data, forKey: Self.key)
        }
    }
}
```

> Match the access-control convention found in Task B2 Step 3. If KishOSCore types are `public`, mark these `public` (and the init/methods/properties).

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -project Clawk.xcodeproj -scheme KishOSMac -destination 'platform=macOS' -only-testing:KishOSMacTests/ProjectStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Clawk/KishOSCore/ProjectStore.swift Clawk/KishOSMacTests/ProjectStoreTests.swift Clawk/project.yml Clawk/Clawk.xcodeproj/project.pbxproj
git commit -m "feat(core): pin chatted-with folders in a ProjectStore"
```

### Task B5: Pass project through `KishOSWorkspace.createConversation` (TDD)

**Files:**
- Modify: `Clawk/KishOSCore/KishOSWorkspace.swift` (`createConversation` ~line 41)
- Test: `Clawk/KishOSMacTests/ConversationStoreTests.swift` (or wherever workspace tests live)

- [ ] **Step 1: Write the failing test**

Add to the workspace/store test file (the one that already constructs a `KishOSWorkspace` with an in-memory store; confirm with `grep -rn "KishOSWorkspace(" Clawk/KishOSMacTests`):

```swift
func testCreateConversationCarriesProject() {
    let workspace = KishOSWorkspace(store: InMemoryConversationStore())
    let convo = workspace.createConversation(
        firstMessage: "hi",
        projectPath: "/Users/k/Code/clawk-ios",
        projectName: "clawk-ios"
    )
    XCTAssertEqual(convo.projectPath, "/Users/k/Code/clawk-ios")
    XCTAssertEqual(convo.projectName, "clawk-ios")
}
```

> Use whatever in-memory store double already exists in the test target (search for `ConversationStoring` conformances in `KishOSMacTests`). If none exists, reuse the store the other workspace tests inject.

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -project Clawk.xcodeproj -scheme KishOSMac -destination 'platform=macOS' -only-testing:KishOSMacTests/ConversationStoreTests`
Expected: COMPILE FAILURE — `createConversation` has no `projectPath:` parameter.

- [ ] **Step 3: Implement**

In `KishOSWorkspace.swift`, `createConversation` (line 41). Add two params after `attachments`:

```swift
    func createConversation(
        firstMessage: String,
        now: Date = Date(),
        deliveryState: MessageDeliveryState = .sending,
        attachments: [ChatAttachment] = [],
        projectPath: String? = nil,
        projectName: String? = nil
    ) -> Conversation {
        var conversation = Conversation(firstMessage: firstMessage, projectPath: projectPath, projectName: projectName, now: now)
```

(Leave the rest of the function body unchanged.)

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -project Clawk.xcodeproj -scheme KishOSMac -destination 'platform=macOS' -only-testing:KishOSMacTests/ConversationStoreTests`
Expected: PASS.

- [ ] **Step 5: Run the full core test suite**

Run: `xcodebuild test -project Clawk.xcodeproj -scheme KishOSMac -destination 'platform=macOS' -only-testing:KishOSMacTests`
Expected: ALL PASS.

- [ ] **Step 6: Commit**

```bash
git add Clawk/KishOSCore/KishOSWorkspace.swift Clawk/KishOSMacTests
git commit -m "feat(core): thread project selection through createConversation"
```

---

## Phase C — iOS UI: picker, chip, badge

### Task C1: `ProjectCatalog` observable (shared loading + filtering)

A small view model that loads recents/all from the client, merges pinned to the top, and filters by search. Lives in core so both platforms reuse it.

**Files:**
- Create: `Clawk/KishOSCore/ProjectCatalog.swift`
- Test: `Clawk/KishOSMacTests/ProjectCatalogTests.swift` (new; add to project per Task B2 Step 0)

- [ ] **Step 1: Write the failing test (pure filtering/merge logic)**

Create `Clawk/KishOSMacTests/ProjectCatalogTests.swift`:

```swift
import XCTest
@testable import KishOSCore

final class ProjectCatalogTests: XCTestCase {
    func testMergePinnedFloatsToTopWithoutDuplicates() {
        let recents = [
            Project(name: "fresh", path: "/c/fresh", relPath: "fresh"),
            Project(name: "shared", path: "/c/shared", relPath: "shared"),
        ]
        let pinned = [
            PinnedProject(path: "/c/shared", name: "shared"),
            PinnedProject(path: "/c/old", name: "old"),
        ]
        let merged = ProjectCatalog.merge(recents: recents, pinned: pinned)
        XCTAssertEqual(merged.map(\.path), ["/c/shared", "/c/old", "/c/fresh"])
    }

    func testFilterMatchesNameCaseInsensitive() {
        let all = [
            Project(name: "Clawk", path: "/c/Clawk", relPath: "Clawk"),
            Project(name: "portfolio", path: "/c/portfolio", relPath: "portfolio"),
        ]
        XCTAssertEqual(ProjectCatalog.filter(all, query: "claw").map(\.name), ["Clawk"])
        XCTAssertEqual(ProjectCatalog.filter(all, query: "").map(\.name), ["Clawk", "portfolio"])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -project Clawk.xcodeproj -scheme KishOSMac -destination 'platform=macOS' -only-testing:KishOSMacTests/ProjectCatalogTests`
Expected: COMPILE FAILURE — no type `ProjectCatalog`.

- [ ] **Step 3: Implement**

Create `Clawk/KishOSCore/ProjectCatalog.swift`:

```swift
import Foundation

@MainActor
final class ProjectCatalog: ObservableObject {
    @Published var recents: [Project] = []
    @Published var all: [Project] = []
    @Published var isLoadingRecents = false
    @Published var isLoadingAll = false
    @Published var loadError: String?

    // Pinned folders float to the top; recents fill the rest. Path-deduped, pinned wins.
    static func merge(recents: [Project], pinned: [PinnedProject]) -> [Project] {
        let pinnedProjects = pinned.map { Project(name: $0.name, path: $0.path, relPath: $0.name) }
        let pinnedPaths = Set(pinned.map(\.path))
        return pinnedProjects + recents.filter { !pinnedPaths.contains($0.path) }
    }

    static func filter(_ projects: [Project], query: String) -> [Project] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return projects }
        return projects.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    func loadRecents(using client: KishAgentClient) async {
        isLoadingRecents = true
        defer { isLoadingRecents = false }
        do {
            recents = try await client.fetchProjects(all: false)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func loadAll(using client: KishAgentClient) async {
        isLoadingAll = true
        defer { isLoadingAll = false }
        do {
            all = try await client.fetchProjects(all: true)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
```

> Match the access-control convention from Task B2 Step 3.

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -project Clawk.xcodeproj -scheme KishOSMac -destination 'platform=macOS' -only-testing:KishOSMacTests/ProjectCatalogTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Clawk/KishOSCore/ProjectCatalog.swift Clawk/KishOSMacTests/ProjectCatalogTests.swift Clawk/project.yml Clawk/Clawk.xcodeproj/project.pbxproj
git commit -m "feat(core): ProjectCatalog loads, merges pinned, and filters projects"
```

### Task C2: iOS project picker sheet

**Files:**
- Create: `Clawk/Clawk/ProjectPickerSheet.swift`
- Modify: `Clawk/Clawk.xcodeproj/project.pbxproj` (add to the `Clawk` iOS target via Task B2 Step 0 mechanism)

- [ ] **Step 1: Build the sheet**

Create `Clawk/Clawk/ProjectPickerSheet.swift`:

```swift
import SwiftUI

// nil selection == Home (~). A non-nil Project pins on selection.
struct ProjectPickerSheet: View {
    @ObservedObject var client: KishAgentClient
    @ObservedObject var catalog: ProjectCatalog
    @ObservedObject var pinned: ProjectStore
    let onSelect: (Project?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var showingAll = false
    @State private var customPath = ""

    private var quickList: [Project] {
        ProjectCatalog.filter(ProjectCatalog.merge(recents: catalog.recents, pinned: pinned.pinned), query: query)
    }

    private var fullList: [Project] {
        ProjectCatalog.filter(catalog.all, query: query)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onSelect(nil)
                        dismiss()
                    } label: {
                        Label("Home (~)", systemImage: "house")
                    }
                }

                Section(showingAll ? "All folders" : "Recent (7 days)") {
                    if currentLoading {
                        HStack { ProgressView(); Text("Loading").foregroundStyle(.secondary) }
                    }
                    ForEach(showingAll ? fullList : quickList) { project in
                        Button {
                            pinned.pin(path: project.path, name: project.name)
                            onSelect(project)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(project.name)
                                    if let branch = project.branch {
                                        Text(branch).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                if !showingAll {
                    Section {
                        Button {
                            showingAll = true
                            Task { await catalog.loadAll(using: client) }
                        } label: {
                            Label("Browse all folders", systemImage: "folder.badge.plus")
                        }
                    }
                }

                Section("Custom path") {
                    HStack {
                        TextField("~/path/to/folder", text: $customPath)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit(useCustomPath)
                        Button("Use", action: useCustomPath)
                            .disabled(customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .searchable(text: $query)
            .navigationTitle("Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await catalog.loadRecents(using: client) }
        }
    }

    private var currentLoading: Bool {
        showingAll ? catalog.isLoadingAll : catalog.isLoadingRecents
    }

    // The agent validates the path on send; an invalid one surfaces as a chat error.
    private func useCustomPath() {
        let trimmed = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let base = (trimmed as NSString).lastPathComponent
        let project = Project(name: base.isEmpty ? trimmed : base, path: trimmed, relPath: trimmed)
        pinned.pin(path: project.path, name: project.name)
        onSelect(project)
        dismiss()
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `xcodebuild build -project Clawk.xcodeproj -scheme Clawk -destination 'generic/platform=iOS' | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Clawk/Clawk/ProjectPickerSheet.swift Clawk/project.yml Clawk/Clawk.xcodeproj/project.pbxproj
git commit -m "feat(ios): project picker sheet (home, recents, browse, pinned)"
```

### Task C3: Wire the picker + chip into the iOS new-chat flow

**Files:**
- Modify: `Clawk/Clawk/KishOSIOSRootView.swift` (state ~line 29, `send` ~line 230, `ChatScreen` ~line 470, `IOSComposer` ~line 859, `startNewChat` ~line 199)

- [ ] **Step 1: Add catalog, pinned store, and pending-project state**

In `KishOSIOSRootView`, after the existing `@StateObject` lines (~line 27) add:

```swift
    @StateObject private var projectCatalog = ProjectCatalog()
    @StateObject private var projectStore = ProjectStore()
```

and after `@State private var selection: IOSChatSelection = .newChat` (~line 29) add:

```swift
    @State private var pendingProject: Project?
    @State private var showingProjectPicker = false
```

- [ ] **Step 2: Compute the active project (selected conversation locks it; new chat uses pending)**

Add a computed property near `selectedConversation` (~line 183):

```swift
    // For an existing conversation the project is fixed; for a new chat it's the pending pick.
    private var activeProjectName: String {
        if let convo = selectedConversation {
            return convo.projectName ?? "Home"
        }
        return pendingProject?.name ?? "Home"
    }

    private var activeProjectIsLocked: Bool {
        selectedConversation != nil
    }
```

- [ ] **Step 3: Pass the project into conversation creation**

In `send(_:attachments:)` (~line 230), change the `createConversation` call (currently `workspace.createConversation(firstMessage: outgoingText, attachments: attachments)`) to:

```swift
            conversation = workspace.createConversation(
                firstMessage: outgoingText,
                attachments: attachments,
                projectPath: pendingProject?.path,
                projectName: pendingProject?.name
            )
            selection = .conversation(conversation.id)
```

Do the same in the offline `queue(_:attachments:)` path (~line 283) — change `workspace.queueConversation(firstMessage: text, attachments: attachments)`. First add a `projectPath`/`projectName` passthrough to `queueConversation` mirroring Task B5 (it calls `createConversation` with `deliveryState: .queued`):

In `KishOSWorkspace.swift`, change `queueConversation` to:

```swift
    func queueConversation(firstMessage: String, now: Date = Date(), attachments: [ChatAttachment] = [], projectPath: String? = nil, projectName: String? = nil) -> Conversation {
        createConversation(firstMessage: firstMessage, now: now, deliveryState: .queued, attachments: attachments, projectPath: projectPath, projectName: projectName)
    }
```

then in the iOS `queue(...)`:

```swift
            conversation = workspace.queueConversation(firstMessage: text, attachments: attachments, projectPath: pendingProject?.path, projectName: pendingProject?.name)
```

- [ ] **Step 4: Send `projectPath` on the wire**

In `sendPreparedMessage` (~line 258) the call is `client.sendStreaming(text, threadId:, conversationId:, attachments:) { ... }`. Add the conversation's project so the agent binds it:

```swift
                let result = try await client.sendStreaming(
                    text,
                    threadId: conversation.threadId,
                    conversationId: conversation.id,
                    attachments: attachments,
                    projectPath: conversation.projectPath
                ) { event in
```

Apply the same `projectPath: ...` addition to the other two `client.sendStreaming(...)` call sites in this file: `retry(_:)` (~line 305, use `retry.conversation.projectPath`) and `drainQueuedMessages()` (~line 441, use `prepared.conversation.projectPath`).

- [ ] **Step 5: Reset pending project when starting a new chat**

In `startNewChat()` (~line 199):

```swift
    private func startNewChat() {
        selection = .newChat
        pendingProject = nil
    }
```

- [ ] **Step 6: Add the project chip to the composer row**

Pass project info into `ChatScreen` and `IOSComposer`. In the `ChatScreen(...)` construction (~line 38) add parameters:

```swift
                        projectName: activeProjectName,
                        projectLocked: activeProjectIsLocked,
                        onPickProject: { showingProjectPicker = true },
```

Add matching stored properties to `ChatScreen` (~line 470, after `let approvals: [ApprovalRequest]`):

```swift
    let projectName: String
    let projectLocked: Bool
    let onPickProject: () -> Void
```

and forward them into `IOSComposer(...)` (~line 551):

```swift
                    projectName: projectName,
                    projectLocked: projectLocked,
                    onPickProject: onPickProject,
```

Add to `IOSComposer` (~line 859) the stored properties (after `let onSend: () -> Void`):

```swift
    let projectName: String
    let projectLocked: Bool
    let onPickProject: () -> Void
```

In `IOSComposer.body`, render the chip just above the main input `HStack(alignment: .bottom, spacing: 8)` (~line 907). Insert:

```swift
            Button(action: onPickProject) {
                HStack(spacing: 5) {
                    Image(systemName: projectLocked ? "folder.fill" : "folder")
                        .font(.caption2)
                    Text(projectName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if !projectLocked {
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(IOSTheme.elevatedBackground, in: Capsule())
                .overlay(Capsule().stroke(IOSTheme.hairline))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(projectLocked)
            .accessibilityLabel("Project: \(projectName)")
```

- [ ] **Step 7: Present the picker sheet**

On the `NavigationStack { ... }` in `KishOSIOSRootView.body` (the modifiers around line 85-115), add:

```swift
                    .sheet(isPresented: $showingProjectPicker) {
                        ProjectPickerSheet(
                            client: client,
                            catalog: projectCatalog,
                            pinned: projectStore,
                            onSelect: { project in pendingProject = project }
                        )
                    }
```

- [ ] **Step 8: Build**

Run: `xcodebuild build -project Clawk.xcodeproj -scheme Clawk -destination 'generic/platform=iOS' | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Commit**

```bash
git add Clawk/Clawk/KishOSIOSRootView.swift Clawk/KishOSCore/KishOSWorkspace.swift
git commit -m "feat(ios): pick a project on new chat and send it to the agent"
```

### Task C4: iOS sidebar project badge

**Files:**
- Modify: `Clawk/Clawk/KishOSIOSRootView.swift` (`ConversationPickerRow` — find with `grep -n "struct ConversationPickerRow" Clawk/Clawk/KishOSIOSRootView.swift`)

- [ ] **Step 1: Add the badge to the row**

In `ConversationPickerRow`'s body, where the conversation title/subtitle render, add a small badge line shown only when the conversation has a project. Insert near the title block:

```swift
            if let projectName = conversation.projectName {
                HStack(spacing: 4) {
                    Image(systemName: "folder").font(.caption2)
                    Text(projectName).font(.caption2)
                    if let branch = conversation.branch {
                        Image(systemName: "arrow.triangle.branch").font(.caption2)
                        Text(branch).font(.caption2)
                    }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
```

(If `ConversationPickerRow` does not currently receive the full `Conversation`, confirm it does — it is constructed with `conversation: conversation` at ~line 1695. Use `conversation.projectName` / `conversation.branch` directly.)

- [ ] **Step 2: Build**

Run: `xcodebuild build -project Clawk.xcodeproj -scheme Clawk -destination 'generic/platform=iOS' | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Clawk/Clawk/KishOSIOSRootView.swift
git commit -m "feat(ios): show project + branch badge on conversation rows"
```

---

## Phase D — Mac UI: picker, chip, badge

The Mac app (`KishOSMac/KishOSMacApp.swift`) mirrors the iOS flow with the same core types. It already has parallel `send` / `sendPreparedMessage` / `uploadAttachment` methods.

### Task D1: Mac project picker popover

**Files:**
- Create: `Clawk/KishOSMac/ProjectPickerPopover.swift` (add to the `KishOSMac` target per Task B2 Step 0)

- [ ] **Step 1: Build the popover**

Create `Clawk/KishOSMac/ProjectPickerPopover.swift`. It is the same logic as the iOS sheet but presented in a fixed-size popover. Reuse `ProjectCatalog` and `ProjectStore`:

```swift
import SwiftUI

struct ProjectPickerPopover: View {
    @ObservedObject var client: KishAgentClient
    @ObservedObject var catalog: ProjectCatalog
    @ObservedObject var pinned: ProjectStore
    let onSelect: (Project?) -> Void
    let onClose: () -> Void

    @State private var query = ""
    @State private var showingAll = false
    @State private var customPath = ""

    private var quickList: [Project] {
        ProjectCatalog.filter(ProjectCatalog.merge(recents: catalog.recents, pinned: pinned.pinned), query: query)
    }
    private var fullList: [Project] {
        ProjectCatalog.filter(catalog.all, query: query)
    }

    private func useCustomPath() {
        let trimmed = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let base = (trimmed as NSString).lastPathComponent
        let project = Project(name: base.isEmpty ? trimmed : base, path: trimmed, relPath: trimmed)
        pinned.pin(path: project.path, name: project.name)
        onSelect(project); onClose()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search folders", text: $query)
                .textFieldStyle(.roundedBorder)

            Button {
                onSelect(nil); onClose()
            } label: {
                Label("Home (~)", systemImage: "house")
            }
            .buttonStyle(.plain)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(showingAll ? fullList : quickList) { project in
                        Button {
                            pinned.pin(path: project.path, name: project.name)
                            onSelect(project); onClose()
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                Text(project.name)
                                if let branch = project.branch {
                                    Text(branch).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 280)

            if !showingAll {
                Button {
                    showingAll = true
                    Task { await catalog.loadAll(using: client) }
                } label: {
                    Label("Browse all folders", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
            }

            Divider()

            HStack {
                TextField("~/path/to/folder", text: $customPath)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(useCustomPath)
                Button("Use", action: useCustomPath)
                    .disabled(customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 300)
        .task { await catalog.loadRecents(using: client) }
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -project Clawk.xcodeproj -scheme KishOSMac -destination 'platform=macOS' | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Clawk/KishOSMac/ProjectPickerPopover.swift Clawk/project.yml Clawk/Clawk.xcodeproj/project.pbxproj
git commit -m "feat(mac): project picker popover"
```

### Task D2: Wire the picker + chip + send into the Mac flow

**Files:**
- Modify: `Clawk/KishOSMac/KishOSMacApp.swift` (root view state, `send` ~line 237, `sendPreparedMessage` ~line 264, the composer, the conversation list rows)

- [ ] **Step 1: Add state**

In the Mac root view, mirror Task C3 Step 1-2 and Step 5: add `@StateObject private var projectCatalog = ProjectCatalog()`, `@StateObject private var projectStore = ProjectStore()`, `@State private var pendingProject: Project?`, `@State private var showingProjectPicker = false`, plus the `activeProjectName` / `activeProjectIsLocked` computed properties (using the Mac view's selected-conversation accessor — find it with `grep -n "selectedConversation" Clawk/KishOSMac/KishOSMacApp.swift`).

- [ ] **Step 2: Pass project into creation and the wire**

In the Mac `send(_:attachments:in:)` (~line 237), find its `createConversation(...)` call and add `projectPath: pendingProject?.path, projectName: pendingProject?.name` (same as Task C3 Step 3). In `sendPreparedMessage` (~line 264) and any other `client.sendStreaming(...)` call sites in this file, add `projectPath: conversation.projectPath` (same as Task C3 Step 4). Reset `pendingProject = nil` wherever the Mac app starts a new chat.

- [ ] **Step 3: Add the chip + popover**

Add a folder chip button to the Mac composer (find the composer view in `KishOSMacApp.swift`) styled to match its toolbar, disabled when `activeProjectIsLocked`, showing `activeProjectName`. Attach a `.popover(isPresented: $showingProjectPicker)` presenting `ProjectPickerPopover(client:catalog:pinned:onSelect:onClose:)` with `onSelect: { pendingProject = $0 }` and `onClose: { showingProjectPicker = false }`.

- [ ] **Step 4: Add the badge to Mac conversation rows**

In the Mac conversation list row view, add the same project + branch badge as Task C4 Step 1, reading `conversation.projectName` / `conversation.branch`.

- [ ] **Step 5: Build**

Run: `xcodebuild build -project Clawk.xcodeproj -scheme KishOSMac -destination 'platform=macOS' | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Clawk/KishOSMac/KishOSMacApp.swift
git commit -m "feat(mac): pick a project on new chat, send it, and badge rows"
```

---

## Phase E — End-to-end verification

### Task E1: Full suite + device smoke test

**Files:** none

- [ ] **Step 1: Run the full Swift test suite**

Run: `cd Clawk && xcodebuild test -project Clawk.xcodeproj -scheme KishOSMac -destination 'platform=macOS' -only-testing:KishOSMacTests | tail -20`
Expected: ALL PASS.

- [ ] **Step 2: Confirm the agent suite still passes**

Run: `cd ~/Code/kish-agent/listener && node --test projects.test.js`
Expected: ALL PASS.

- [ ] **Step 3: Manual device pass (iOS)**

Build/run the iOS app on the phone (or simulator pointed at the mini). Verify:
- New chat shows a "Home" chip. Tapping it opens the picker; recents list folders edited in the last 7 days; "Browse all folders" shows the full alphabetical list; search filters.
- Pick a repo (e.g. `clawk-ios`), send "run pwd and reply with only the output". Reply shows that folder's path.
- The sidebar row shows the folder name + branch badge.
- That folder now appears pinned at the top of the picker on the next new chat.
- Reopen the conversation: the chip is locked to the chosen folder (not tappable).
- Start a chat without picking: it runs from Home, no badge (or "Home").

- [ ] **Step 4: Cross-device sync check**

Open the Mac app. The conversation created on the phone shows the same folder + branch badge (proves project round-trips through `/conversations`).

- [ ] **Step 5: Final commit / branch is ready for PR**

```bash
git status
git log --oneline origin/main..HEAD
```
Expected: a clean tree and the Phase B-D commits ready to PR. (Agent commits live in `~/Code/kish-agent` and were handled in Task A6 Step 10.)

---

## Notes for the implementer

- **Two repos, one feature.** The agent (`~/Code/kish-agent`, edited locally, `code-sync push` + launchctl restart to deploy) and the app (this repo) must both land. The app is useless until Phase A is deployed (Task A6).
- **Access control.** KishOSCore is compiled into the app targets directly, so it likely uses no `public` keyword. Before adding `public`, confirm the prevailing style (Task B2 Step 3 note) and match it — getting this wrong produces a wall of access errors.
- **XcodeGen.** New Swift files must be registered (Task B2 Step 0). If the repo regenerates `project.pbxproj` from `project.yml`, run that; otherwise add files in Xcode. A new file that compiles locally but is missing from the target will fail CI.
- **The folder is fixed at creation.** The agent enforces this (first binding wins); the app reflects it (locked chip on existing conversations). Do not add a "change folder" affordance — it is explicitly out of scope.
