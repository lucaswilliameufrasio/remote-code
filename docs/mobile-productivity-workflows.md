# Mobile productivity workflows

**Status:** implemented; real-server and real-device validation pending, 2026-10-15

## Context

The home screen can resume recently opened sessions, but pending questions and
permission requests are only visible after opening each session. Projects are
currently implicit in machine directories, and composing a longer prompt on a
phone requires typing.

## Decisions

- The **Trabalho** destination combines locally saved shortcuts with the ten
  newest global sessions from each configured machine. Refresh on entry and
  pull-to-refresh; opening a server-only session then saves it as a local
  shortcut. Keep the bookmark limit and draft persistence unchanged.
- Add a global pending-actions destination. Load it when first opened, when
  revisited, or manually refreshed; do not add background polling or push
  delivery. Use the v2 location-scoped pending-form and permission-request
  endpoints, which include each request's `sessionID`. Discover locations from
  configured directories, project canonical paths, up to 100 newest global
  sessions per machine, up to 100 local bookmarks total, and up to 20 additional
  active sessions total; cap at 100 directories per machine and 200 returned
  actions. Use bounded concurrency. Opening an item navigates to the existing
  chat so the established OpenCode v2 reply flows remain authoritative.
  These endpoints are not an all-locations query: omitting `location[directory]`
  resolves only the OpenCode server's process working directory. The inbox can
  therefore miss an older, inactive session in a directory absent from the
  bounded discovery sources; show truncation and keep this real-server check in
  acceptance testing.
- Group projects per machine using the OpenCode project ID and worktree path.
  Retain a path-based fallback for bookmarked or configured directories not
  present in the server's project list. Project details reuse the existing
  directory-filtered session journey; do not create or mutate remote projects.
- Add short voice dictation to the prompt composer. Use the platform's speech
  recognition service, insert the recognized words into the draft for review,
  and send only when the user submits the normal text prompt. Request
  microphone/speech permissions only after an explicit tap. Disclose that the
  platform recognition service may use network access; the app does not upload
  an audio recording to OpenCode.
- Keep Claude Code out of this implementation. Its official Remote Control
  already supports mobile use, while an in-app integration would require a
  separate host-side agent adapter, authentication model, and capability
  mapping. Revisit only if a unified provider experience is still desired after
  these mobile workflows are validated.

## Alternatives and trade-offs

- Polling every session continuously could make inbox counts fresher, but would
  undermine the app's reduced-network goal and be unreliable in mobile
  background execution. On-demand scans may be stale until refreshed.
- Grouping by basename alone can merge unrelated repositories. Project identity
  is scoped to its machine; directory matching is only the compatibility
  fallback.
- Sending recorded audio to a cloud transcription provider could improve
  language coverage, but adds provider credentials, cost, and another transfer
  of potentially sensitive work content. The initial feature is text dictation
  through the operating system, with an explicit review step.
- An in-app Claude Code client is technically possible through a separate
  adapter, but it is not the same API as OpenCode v2 and would expand setup,
  authorization, session lifecycle, and permission handling. The official
  Claude app/Remote Control remains the supported path for now.

## Implementation and remaining validation

- The recent-work list now merges server sessions and local bookmarks; verify
  that a session created from the machine's terminal appears after opening or
  refreshing **Trabalho**.
- Project grouping and the project-to-sessions entry point are implemented.
- The on-demand pending-actions inbox and direct chat route are implemented.
- Permission-gated dictation, editable transcript review, insertion at the draft
  cursor, and regression coverage for cancel/review/no-auto-submit are implemented.
- The current upstream v2 server source confirms `/api/form` and
  `/api/permission/request` are location-scoped, that their responses include
  request session IDs, and that an omitted location defaults to the server
  process working directory. Project inventory returns canonical directories.
  This source inspection does not replace compatibility testing against the
  user's installed OpenCode v2 server.
- Repository validation, Android/iOS builds, and the iOS onboarding simulator test
  passed on 2026-10-15. Real-device speech recognition and server-backed
  pending-action validation remain follow-up checks.

## References

- [OpenCode v2 HTTP API](https://opencode.ai/v2/docs/api/)
- [speech_to_text Flutter package](https://pub.dev/packages/speech_to_text)
- [Claude Code Remote Control](https://docs.anthropic.com/en/docs/claude-code/remote-control)
- [Claude Agent SDK](https://docs.anthropic.com/en/docs/claude-code/sdk)
