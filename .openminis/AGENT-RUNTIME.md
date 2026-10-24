# ZEUS native project agent

The original pinned OpenMinis `AIChatViewModel` executes the conversation using
the provider/model selected in the original provider settings. There is no
Codex CLI delegation in the app's registered tools or settings. The old Python
Codex service remains historical source in `Runtime/agent_service`; it is not a
dependency of this native runtime and must not be deployed as its replacement.

The next project-contract layer is documented in [PROJECT-CONTRACT.md](PROJECT-CONTRACT.md): inline plan approval for substantial projects (small scripts and inspection tasks execute directly), native GitHub REST/Actions and evidence for every approved feature, including actual UI image review.

## Implementation and acceptance stages

1. **Native tools and provider contracts**: nested JSON schemas on OpenAI Chat
   Completions/Responses, Gemini, Antigravity and Anthropic requests; recursive
   validation before permission/execution. Native OpenAI tools explicitly use
   `strict:false` to preserve dynamic integration objects and optional fields.
   Gemini's official `parametersJsonSchema` carries full nested schemas rather
   than erasing free-form objects through the older OpenAPI subset.
   Incomplete streamed arguments and
   tool-looking prose never execute. Verify both malformed calls and the actual
   transmitted provider schema.
2. **Project execution**: context-checked multi-file `apply_patch`, real local
   Linux `exec_command`, output polling/cancellation with conversation-owned
   IDs, bounded output and retained command records. Validate the whole patch
   before writing and attempt rollback on commit failure. This is not a general
   atomic filesystem transaction, and interactive stdin uses the original
   terminal tool.
3. **Persistence and verification**: atomic per-conversation plans/checkpoints,
   call-ID deduplication across restart, refreshed bounded task context after
   compaction, configurable turn/time budgets, actual test exit codes tied to
   the edit generation, and a completion gate. `task_verify_mcp` verifies actual
   read-only MCP results against exact JSON assertions (including run/deployment
   and commit identity), so remote GitHub Actions work does not need a fake
   local shell test. Prose success messages, wrong commits and tool error
   results are rejected. Registered assertions cannot be removed or weakened;
   remote mutations invalidate earlier evidence too. Do not weaken earlier checks to
   turn a failed test green. An uncertain write is inspected, never replayed
   automatically. A lost local process is reported as possibly interrupted,
   not automatically restarted.
4. **Direct integrations**: native HTTP MCP with account-isolated OAuth tokens,
   refresh, session/version negotiation, paginated tool discovery, nested input
   validation and no automatic write replay. Account pages show real accounts,
   primary selection and actual read/write tool annotations. OAuth DCR is used
   only when advertised and accepted. Real registration testing found Railway
   currently responds `access_denied: Dynamic client registration is disabled`.
   Railway therefore requires a Native/Public client registered once in the
   workspace's Developer settings. GitHub likewise requires registering a ZEUS
   OAuth application once; the app cannot reuse ChatGPT's client. Vercel rejected
   the custom-scheme callback but accepted the native loopback callback; a ZEUS
   public client was registered successfully and its nonsecret ID is built in.
   No user's account/token was linked by that registration. Provider pages must not claim a
   successful connection before the actual tools/list completes.
5. **Skills**: 59 pinned official OpenAI plugin skills with their references,
   scripts and attribution. `ZEUSDefaultSkills/manifest.json` records source
   and installed names. Original bundled files are preserved; duplicate names
   are namespaced only in the installed SKILL.md metadata. The original skill
   store selects a bounded catalog instead of adding every skill body to every
   request. A skill does not install Xcode, grant credentials or create a shell.
6. **End-to-end acceptance**: compile on macOS, run iPhone/iPad browser and agent
   tests, verify complete original streamed messages and inline approval, and
   run a controlled provider conversation that creates two real files, records
   a failing check, repairs a file, reruns the check and completes. Separate
   native HTTP MCP fixtures verify account isolation, SSE notifications,
   pagination and pre-execution schema rejection. Controlled model fixtures
   test runtime correctness; they are not evidence of a particular live model's
   coding intelligence.
7. **Optional execution after the phone closes**: not delivered by the local
   runtime. iOS may suspend the app. A future remote continuation must carry
   this agent's selected provider, transcript, task state and permissions into
   a persistent environment. It must not silently create a second Codex task or
   require a Codex subscription. No new Railway project is authorized; any later
   deployment belongs beside the existing three services in the user's chosen
   project. The current release must describe foreground/background limits.

## Source review and provenance

These are reviewed implementation references, not claims that the entire Rust,
TypeScript or Python engines were embedded verbatim in Swift:

- [Codex](https://github.com/openai/codex), Apache-2.0:
  `codex-rs/core/src/tools/handlers/plan.rs`,
  `codex-rs/core/src/tools/handlers/unified_exec/exec_command.rs`,
  `codex-rs/core/src/tools/handlers/unified_exec/write_stdin.rs`,
  `codex-rs/apply-patch/src/parser.rs` — plans, process polling and patch grammar.
- [OpenCode](https://github.com/anomalyco/opencode), MIT, branch `dev`:
  `packages/core/src/session/prompt.ts`, `session/compaction.ts`, `mcp/index.ts`
  — continuation, context management and MCP boundaries.
- [Hermes Agent](https://github.com/NousResearch/hermes-agent), MIT:
  `agent/conversation_loop.py`, `agent/iteration_budget.py`,
  `tools/process_registry_checkpoint.py` — iteration budgets, checkpoints and
  avoiding unsafe process replay after restart.
- [Official OpenAI plugins](https://github.com/openai/plugins), revision
  `0722921d5542fc593105c27bd52630babd8b8c2a`: packaged skills/assets and their
  original licenses are recorded under `ZEUSDefaultSkills`.
- [OpenMinis](https://github.com/naruto00o9n-max/OpenMinis), revision
  `6339bfcb25190ebf80fd03086c4ead81cf9428ba`: actual UI, renderer, streaming,
  conversation storage, model/provider settings, original agent loop and Linux
  environment. `test_embed.py` verifies original views remain unchanged except
  the documented host adapters; Vendor/OpenMinis is never edited in place.

## Verification records

The first simulator run exposed a real upstream iSH `sys_uname` trap:
`strcpy(uts->hostname, host nodename)` overflows Linux's 65-byte field when the
host name is longer. `patch_ish.py` applies a bounded copy and initializes the
host result in the separate pinned dependency checkout for both SDKs.
`test_ish.py` compiles the actual C function with fortified libc and AddressSanitizer
and exercises an overlong hostname and failed host uname. Dependency caches are
versioned so the affected static libraries are rebuilt, not reused.

After that fix, real iPhone shell execution exposed two further adapter issues:
new conversations need their session-owned workspace buckets created before the
first guest mkdir, and iSH exit notifications carry Linux wait status (`256`
for shell exit `1`). The host adapters now prepare those directories, pass the
conversation ID into native path resolution and decode wait status once in the
shell executor. Tests keep the original failing check and also exercise `exit 7`.

Use the exact commit recorded by each workflow, not merely the branch name.
`zeus-native-integration.yml` checks simulator behavior; `zeus-ipa-download.yml`
packages an unsigned device IPA separately. Successful packaging is not a
substitute for successful integration tests. Do not distribute an IPA as a
verified release while those checks are failing or incomplete.

The full original model loop then exposed an upstream skill-disclosure trap:
more than 20 bundled skills made `recent.prefix(recentLimit)` receive a negative
length. The adapter now caps bundled metadata at the existing 20-entry budget
and bounds remaining counts; all other installed skill names remain discoverable.
The native regression calls the actual selector with the 59-skill catalog and
checks both the metadata budget and discoverability before exercising the full
streaming/model/tool loop. Device version is 2.9.0 (14).

Simulator validation uses Xcode's simulator signing and simulated-entitlement
packaging, with an app-owned Keychain access group. The original unsigned host
returned errSecMissingEntitlement (-34018); manual post-build device-style
entitlements were rejected by simulator launch policy, so they were removed.
There is no credential mock or in-memory fallback. The full-loop regression
reads back its fixture key using the original ProviderKeychainHelper.
Device IPAs remain unsigned in the separate packaging workflow.

GitHub authorization now uses its official public-client OAuth device grant:
https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow
The user reported Safari HTTPS-only blocking the HTTP loopback after successful
login. Device Flow avoids the HTTP browser callback entirely; it uses the same
registered client ID and requires Enable Device Flow (already enabled in the
user's screenshot). Only GitHub's HTTPS verification page is opened. Polling
honors authorization_pending, slow_down, expiry, denial and cancellation;
tokens must round-trip through original Keychain storage before account creation.
Native HTTP tests exercise those responses and reject untrusted verification URLs.
Version 2.9.1 (15) includes this fix; actual user approval remains interactive.


## OpenMinis 1.14 and provider regression fixes

The source lock now points to official `OpenMinis/OpenMinis` tag 1.14,
`b4c0661d5631ebab4d1a2e6f3fd4c805d4030a6c`. The original provider screens,
GitHub Copilot device authorization, usage/quota views, request settings,
Gemini thinking-signature history, image wire-format fixes and agent updates
come from that source. Provider support and quota availability still depend on
the account and endpoint. Browser adapters and original view comparisons remain
explicit, while audio/video/VAD resources stay excluded from the text edition.
Rclone is built as a real SDK-correct XCFramework for the new backup feature.

Native Gemini tests exercise its actual `streamGenerateContent` request,
`parametersJsonSchema`, image bytes, functionResponse and forced native repair
configuration. Custom OpenAI-compatible tests exercise streamed calls and repair
through the original OpenAI transport. These controlled local HTTP fixtures do
not claim that a live Gemini/DeepSeek account has been tested or that all models
produce equally good code.

Plan normalization accepts unambiguous equivalent IDs/titles, explicit all-feature
coverage and common check-kind aliases, but never fabricates tests or successful
results. Validation reports the exact unknown/missing IDs. Native argument
normalization repairs stringified JSON/booleans/integers and optional nulls without
accepting unknown fields, missing required fields or fractional integers. Utility
environment discovery does not create a mandatory project; an unwanted plan call
for a utility is a harmless no-op. Model-facing prompts no longer tell text-only
models to use removed FFmpeg/Pillow for image understanding; use the original
native `read_image` pipeline or configure a real vision model/group.
