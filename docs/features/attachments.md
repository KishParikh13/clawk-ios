# KishOS iOS Attachments Spec

Status: live. This doc is retained as the feature-specific implementation record.

Current roadmap source of truth: `docs/ROADMAP.md`.

Preserved app commits:

- `9da7f3a` attachment model/composer/client base
- `f6fc2d0` attachment request tests
- `959a9f2` iOS image previews
- `af7d387` Mac file attachment uploads

Verified backend commits on the Mac mini:

- `979ec8f feat: add native KishOS app bridge`
- `763f7a1 add native attachment uploads`

## Goal

Make iOS and Mac chat attachments work like the existing Slack path: when Kish attaches an image, PDF, text file, or other document, the agent can actually inspect the file, not just see a filename or OCR fallback.

The first useful version should let Kish:

- Choose a photo and ask the agent about the image.
- Select a local file and ask the agent to read/analyze it.
- Send attachments with a normal chat message.
- See clear attachment chips before sending and in the chat history.
- Continue using offline queueing without losing attachment intent.

## Current State

This section captures the original baseline. It is retained for historical context;
the implementation now exists in the commits listed above.

### iOS app

Relevant files:

- `Clawk/Clawk/KishOSIOSRootView.swift`
- `Clawk/Clawk/CameraTextCaptureView.swift`
- `Clawk/Clawk/FileTextPickerView.swift`
- `Clawk/KishOSCore/Conversation.swift`
- `Clawk/KishOSCore/AgentClient.swift`

Current behavior:

- `+` menu has `Camera`, `Choose a photo`, and `Select a file`.
- `Choose a photo` currently opens a photo picker through `CameraTextCaptureView(sourceType: .photoLibrary)`.
- Photos are only run through local Vision OCR. If there is no readable text, the app shows `No text found.`
- `Select a file` reads UTF-8-ish files into `.textContext`; non-text files become only a `.file` chip with title.
- `messageTextForAgent(_:, attachments:)` injects `.text` attachments into the prompt.
- `.image`, `.file`, and `.url` attachments currently render only as a placeholder line like `[Context 1: filename]`.
- `KishAgentClient.sendStreaming` posts JSON to `/chat-stream` with only:
  - `threadId`
  - `message`
  - `conversationId`
- There is no iOS binary upload contract yet.

### kish-agent / Slack

Relevant reference repo:

- `/Users/kishparikh/Code/kish-agent/listener/index.js`

Slack already has the desired pattern:

- Inbound Slack files are downloaded with `downloadInputFiles(files, inputDir)`.
- Files are saved into a per-run upload directory under `_input`.
- Prompt includes an attachment note with local file paths.
- Codex can receive `imagePaths`.
- Claude/Codex are told files are available on disk.
- Agent-generated files are collected from the per-request upload dir and uploaded back to Slack.

Important code locations in Slack listener:

- Attachment download helper: `downloadInputFiles` around `listener/index.js:1005`.
- Per-run upload dir: `makeUploadDir` around `listener/index.js:1047`.
- Prompt attachment note: around `listener/index.js:1272`.
- Engine call using image paths for Codex: around `listener/index.js:1319`.

Unknown:

- The HTTP bridge serving `http://kishs-mac-mini-1:17891` was not found in `/Users/kishparikh/Code/kish-agent` during this session. It may live in a different workspace/process. The iOS client confirms the current API shape, but the backend source needs to be located before implementation.

## Product Behavior

### Composer

The `+` menu should keep:

- `Camera`: capture a new photo.
- `Choose a photo`: choose from Photos.
- `Select a file`: choose from Files.

Selecting any item should create an attachment chip. It should not auto-send.

Recommended chip states:

- `Uploading...` while the file is being uploaded to the bridge.
- `Ready` when upload succeeds.
- `Failed` with retry/remove affordance if upload fails.

The send button should be disabled only if:

- there is no text and no ready attachment, or
- a chat response is currently pending, or
- an attachment upload is in progress and the user has not chosen to send without it.

### Sending

If the user sends text plus attachments, the agent should receive both.

If the user sends only attachments, default prompt should be:

```text
Look at the attached file(s) and respond.
```

If a photo has no OCR text, that should not be an error. It should still upload as an image.

### Offline

Current offline queue stores `ChatAttachment` in `ChatMessage.attachments`, but it does not store binary file data. For a safe first version:

- If online: upload immediately, store returned attachment ids in conversation state, then send.
- If offline before upload: keep a local attachment reference and show `Waiting to upload`.
- If app restarts before upload: either preserve security-scoped bookmark/local copy, or mark attachment as needing reselect. Do not silently send a filename-only placeholder.

For the first implementation, it is acceptable to make offline file sending explicit:

- Text-only messages queue as today.
- Attachment messages queue only after files have been uploaded successfully.
- If offline and the user attaches a not-yet-uploaded file, show `Reconnect to upload`.

## Data Model

Current:

```swift
struct ChatAttachment: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case text
        case image
        case file
        case url
    }

    var id: UUID
    var kind: Kind
    var title: String
    var text: String?
    var createdAt: Date
}
```

Proposed:

```swift
struct ChatAttachment: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case text
        case image
        case file
        case url
    }

    enum UploadState: String, Codable, Equatable {
        case local
        case uploading
        case ready
        case failed
    }

    var id: UUID
    var kind: Kind
    var title: String
    var text: String?
    var createdAt: Date

    var mimeType: String?
    var byteCount: Int?
    var uploadId: String?
    var localFilename: String?
    var uploadState: UploadState
    var uploadError: String?
}
```

For source payloads, do not store large binary data directly in `Conversation` JSON. Use a separate local cache:

```swift
struct PendingAttachmentPayload {
    let attachmentId: UUID
    let filename: String
    let mimeType: String
    let data: Data
}
```

Possible local cache:

- `Application Support/KishOS/Attachments/<attachment UUID>/<filename>`
- Store only while pending upload or for recent history previews.
- Clean up after successful upload and after old conversations are deleted.

## API Contract

Preferred bridge contract:

### `POST /attachments`

Multipart upload.

Request fields:

- `file`: binary body
- `filename`: original filename
- `mimeType`: content type
- `conversationId`: optional UUID
- `threadId`: optional string

Response:

```json
{
  "ok": true,
  "attachment": {
    "id": "att_...",
    "filename": "receipt.jpg",
    "mimeType": "image/jpeg",
    "byteCount": 123456,
    "kind": "image"
  }
}
```

Failure:

```json
{
  "ok": false,
  "error": "File exceeds 25 MB limit"
}
```

### `POST /chat-stream`

Extend current JSON body:

```json
{
  "threadId": "...",
  "conversationId": "...",
  "message": "What is this?",
  "attachments": [
    {
      "id": "att_...",
      "filename": "receipt.jpg",
      "mimeType": "image/jpeg",
      "kind": "image"
    }
  ]
}
```

Bridge behavior:

1. Resolve `attachment.id` to a local file path.
2. Create/choose a per-run upload dir.
3. Copy or symlink uploaded files into `<uploadDir>/_input`.
4. Add an attachment note to the prompt:

```text
[ATTACHMENTS - Kish attached these and they are saved on disk. Read / analyze them as part of your answer:
- /tmp/kishos-ios-uploads/.../_input/receipt.jpg (image/jpeg)
]
```

5. If engine is Codex and attachment is image, include the path in `imagePaths` if that runtime supports it.
6. Run engine.
7. Stream output exactly as today.

Alternative one-call contract:

- `POST /chat-stream` as multipart with JSON part plus files.
- This is simpler for the app but less reusable. Prefer separate `/attachments` so attachments can upload before send and show ready/failed state.

## Backend Implementation Notes

Reuse Slack patterns from `listener/index.js`:

- Same max file limits:
  - `MAX_INPUT_FILES`
  - `MAX_INPUT_BYTES`
- Same sanitization:
  - replace unsafe filename chars
- Same per-run `_input` convention.
- Same prompt note style.

New backend storage:

- `UPLOAD_ROOT = path.join(os.tmpdir(), 'kishos-ios-uploads')`
- `POST /attachments` writes into a staging dir:
  - `<UPLOAD_ROOT>/staging/<attachmentId>/<filename>`
- `/chat-stream` copies staged attachments into the current run dir:
  - `<UPLOAD_ROOT>/<runId>/_input/<filename>`

Security:

- Do not allow path traversal.
- Limit file count and byte size.
- MIME type is user-provided; infer when possible.
- Delete staged uploads after TTL or after conversation deletion.

## iOS Implementation Plan

### Phase 1 - Real Attachment Model

Files:

- `Clawk/KishOSCore/Conversation.swift`
- `Clawk/Clawk/KishOSIOSRootView.swift`
- `Clawk/Clawk/FileTextPickerView.swift`
- `Clawk/Clawk/CameraTextCaptureView.swift`

Tasks:

- Extend `ChatAttachment` with upload fields.
- Add local payload cache for picked files/photos.
- Change `Choose a photo` to attach an image, not OCR-only.
- Keep OCR optional as supplemental text, not required.
- Change `Camera` to attach captured image. Optional OCR can create a text preview, but no `No text found` failure for image attachment.
- Change `Select a file` to attach any selected file with MIME/type metadata.
- Keep text extraction for plain text files as a convenience, but still preserve file payload.

Acceptance:

- Selecting a normal photo creates an image chip even if OCR finds no text.
- Selecting a PDF creates a file chip.
- Selecting a `.txt` creates a file chip and may include text preview.

### Phase 2 - Upload Client

Files:

- `Clawk/KishOSCore/AgentClient.swift`
- `Clawk/Clawk/KishOSIOSRootView.swift`

Tasks:

- Add `uploadAttachment(payload:) async throws -> UploadedAttachment`.
- Implement multipart upload.
- Mark chips as uploading/ready/failed.
- Disable send while any selected attachment is uploading.
- Include upload ids in the chat request.

Acceptance:

- Upload succeeds against local bridge.
- Failed upload shows retry/remove.
- No binary data is embedded in conversation sync JSON.

### Phase 3 - Chat Request Contract

Files:

- `Clawk/KishOSCore/AgentClient.swift`
- backend bridge source, once located.

Tasks:

- Add `attachments: [ChatRequestAttachment]` to `ChatRequest`.
- Keep backwards compatibility when `attachments` is empty.
- Update backend `/chat-stream` schema.
- Preserve streaming events and approval flow unchanged.

Acceptance:

- Sending text-only messages still works.
- Sending text plus file works.
- Sending file-only message works.

### Phase 4 - Mac Parity

Files:

- `Clawk/KishOSMac/KishOSMacApp.swift`

Tasks:

- Add file picker to Mac composer.
- Use same `ChatAttachment` model and `AgentClient.uploadAttachment`.
- Drag-and-drop can be a later improvement.

Acceptance:

- Mac can select a file and send it to the agent.

## UX Details

Attachment chip examples:

- `receipt.jpg`
- `report.pdf`
- `notes.txt`

Substates:

- uploading: spinner
- ready: no extra text or a subtle check
- failed: red outline and retry affordance

Error copy:

- Upload too large: `File is too large.`
- Unsupported picker result: `Could not read that file.`
- Offline before upload: `Reconnect to upload.`
- Backend rejected: use backend error text when short.

Do not show `No text found` for photos. That should only apply if the explicit action is “scan text,” not “choose a photo.”

## Testing Plan

### Unit Tests

Add tests around:

- `ChatAttachment` codable backward compatibility.
- `messageTextForAgent` text attachment rendering.
- New chat request encoding with and without attachment ids.
- Upload state transitions if state logic is separated.

### Manual iOS Tests

1. Text-only message still sends.
2. Photo with no text attaches and sends.
3. Screenshot with text attaches and sends.
4. PDF attaches and sends.
5. Plain text file attaches and sends.
6. Large file is rejected clearly.
7. Offline text message queues as today.
8. Offline attachment before upload shows reconnect/upload-needed state.
9. Follow-up in same conversation keeps same thread and can include another attachment.
10. Agent response can refer to actual image/file contents.

### Backend Tests

1. `POST /attachments` accepts image and returns id.
2. `POST /attachments` rejects oversized file.
3. `/chat-stream` with valid attachment id creates `_input` file.
4. `/chat-stream` with missing attachment id returns clear error.
5. Cleanup removes stale uploads.
6. Existing Slack behavior is not regressed.

## Milestone Result

This was built across app and backend sessions.

### Session A - Backend Contract

Completed on the Mac mini backend:

- `POST /attachments`
- attachment staging storage
- `/chat-stream` attachment ids
- prompt attachment note

Verified backend commit: `763f7a1 add native attachment uploads`.

### Session B - iOS Client

Completed in the app:

- real image/file attachment payloads
- upload client
- chip upload states
- chat request attachment ids

Verified app commits: `9da7f3a`, `f6fc2d0`, `959a9f2`, `af7d387`.

## Open Questions

- Which engine should handle image files first: Codex image path support, Claude local file read, or both?
- Should uploaded attachment binaries be persisted across devices in shared conversation sync, or only attachment metadata/chips?
- Should we support agent-generated files back into iOS chat, matching Slack upload-back behavior?
- What is the max file size for iOS upload? Slack code uses 25 MB friendly limit; use same unless there is a better reason.
