# Project agreements

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
