# User-approved project execution

ZEUS keeps the pinned OpenMinis conversation, renderer and selected provider.
This extension enforces a project contract in that same agent; it does not send
work to a Codex account or substitute another model.

## Execution

1. The actual user message activates a project requirement for app/site/project
   requests. Source-write tools also catch unclassified source work. The agent
   reads source/references and calls `project_environment` to inspect actual
   Linux tools and linked accounts before selecting a build route.
2. `propose_project_plan` renders an inline native card with platform, features,
   architecture, steps, assumptions, deliverables and acceptance checks. The
   user explicitly approves, requests changes with notes, or cancels. Tool
   permission mode does not waive this product-plan approval. Approval records
   the precise proposal hash; no model text can impersonate it.
3. Before approval, source/repository/build mutations are blocked. After
   approval, the original agent follows persisted steps, reads relevant skills
   and repository instructions, implements the product, and repairs failed
   checks. In consequential permission mode, approved workspace changes and
   scoped GitHub feature-branch actions avoid repetitive permission prompts;
   ask-every-tool mode still asks. Arbitrary commands and production changes do
   not become routine merely because a plan exists.
4. iOS projects cannot claim a Linux compiler is Xcode. Their approved route
   uses a real linked GitHub account, repository, branch and Actions workflow.
   `github_request` operates GitHub REST directly with the account's Keychain
   token. It supports repository/files/git objects/workflows/status/artifacts;
   uncertain writes are never automatically replayed. An absent compiler, one
   successful GET or a failed build cannot justify manual-build completion.
5. Completion requires current evidence for every criterion: actual local test
   exit codes or the exact successful GitHub run, repository, branch, current
   HEAD SHA, workflow, named jobs/steps and required artifacts. App/site plans
   also require UI review. Remote screenshots are downloaded by
   `github_download_artifact`, extracted into its dedicated directory, and
   actually delivered through the original `read_image` tool for that commit.
   Artifact presence alone is insufficient. Source changes invalidate evidence;
   active mutations block verification/completion.
6. Approved plan/checkpoint state survives reopening. Original persisted tool
   input identifies the progress card when UI UUIDs change. Native tool ledger
   keys use persisted RawMessage IDs, allowing providers to reuse call IDs in
   later rounds without replaying an old call. Interrupted/uncertain calls need
   inspection rather than blind repetition.

## Verification and limits

Host tests check adapters against the real pinned source and iSH hostname fix.
Native tests exercise plan approval/revision/cancellation, permission modes,
restart state, typed tools, real guest commands and a controlled model loop
that creates files, fails a test, repairs it and passes. HTTP fixtures exercise
account separation, native GitHub file/dispatch requests, exact CI evidence,
wrong/stale commits, failed/skipped checks, missing artifacts, downloaded image
bytes and prevention of credential forwarding. Fixtures do not authorize or
modify a user's live GitHub account.

The runtime cannot guarantee the design quality or reasoning ability of every
selected model. It records and checks evidence; it cannot prove that a
model-authored test fully captures the user's intent. The reviewable plan makes
that scope explicit. iOS may suspend local execution in the background; this
change does not install an unlimited cloud runner. Genuine account, network,
user-denial, storage and configured time-budget blockers preserve progress and
may require user intervention.

## Provider recovery, direct source editing and visible milestones

Project environments automatically load the full bodies of relevant enabled
skills: SwiftUI patterns/refactoring/simulator QA for Swift/iOS work, frontend
building/testing for websites. Disabled skills remain disabled. The native plan
shows which skills were loaded. Attached reference images must be inspected
with the original image tool and have design notes before proposing the UI.

`github_read_file` decodes actual repository text natively. `github_write_files`
accepts normal UTF-8 source for up to 30 files and creates blobs/tree/commit,
then updates the approved branch without force and checks its HEAD. The model
does not generate Base64, clone or push locally. Job log redirects are read
natively with no account token forwarded to the temporary host.

If an active project provider writes `tool_calls` as visible JSON, that text is
never executed. It is replaced with a clear protocol-error notice and a bounded
repair request. OpenAI-compatible chat requests select the named advertised
function on repair. A provider that still cannot produce a structured call
pauses after two repair attempts with progress preserved. Ordinary text and
quoted examples outside an active task are unaffected.

The approved plan becomes a checklist with a single active stage. Changes of
stage require a concrete model-authored explanation and may complete only one
new stage at a time. Milestones, automatic skill loading and direct source
receipts appear in a persisted notes/progress card, with a history disclosure.
The model is also instructed to send concise visible milestone updates while
continuing its tools; the card does not fabricate reasoning on its behalf.
