# Project agreements

Write all project content intended for publication in English, including code
comments, UI text, documentation, task lists, commit messages, and GitHub content.
The language used in conversation does not change this requirement.

Read PRODUCT.md before planning or implementing. Its accepted product direction
supersedes the original open questions in README.md. Update the README as features
become available; distinguish implemented behavior from planned work.

Use Codex for every agent role, including planning, architecture, implementation,
review and recovery. Do not invoke Claude or fall back to another provider.

Use the installed Omarchy skill and its plugins.md guide when working on shell
integration. Quickshell/QML for the UI and Go for the data helper are required.
Do not implement a Python backend. Read packaged shell examples but never
edit /usr/share/omarchy. Preserve existing user configuration and unrelated plugins.

Work through the current Forge task only, preserving working increments and
existing review findings. Run meaningful checks appropriate to the change.
Forge manages commits and publishing; implementation agents must not independently
commit, push, reset review state, or modify .forge runtime files.

Keep commits short, focused and independently reviewable. Add no AI attribution
or Co-authored-by trailers. Retain the MIT license. Keep credentials, runtime
state and fetched personal contribution data out of Git.

The user authorized automatic pushes to origin for this development run. Publish
only after the required Forge review gates pass. Do not force-push.

Keep diagnostic tool output bounded: Forge rejects any single agent event over
1 MiB. When inspecting `.forge` history or agent records, select specific JSON
fields and bounded text excerpts with jq, or use the project-targeted paginated
Forge API. Never dump or recursively search raw runtime records into tool output;
line-count limits such as `tail -100` do not bound large JSONL records. Keep each
diagnostic result below 16 KiB, and inspect further bounded pages when necessary.
Redirect verbose test output to a private temporary file and report its exit
status and bounded relevant excerpts. Preserve full evidence on disk, inspect
all relevant review findings, and never expose credentials or personal data.
