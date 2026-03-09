# Pre-release Open Source TODO

Last updated: 2026-03-10

## Done

- [x] Add a repository `LICENSE` with the GNU Affero General Public License v3.0 text.
- [x] Add `THIRD_PARTY_NOTICES.md` for direct dependencies and FlowDown acknowledgement.
- [x] Update `README.md` with license and acknowledgement sections.
- [x] Add an in-app `About & Licenses` entry so legal notices are reachable from the UI.
- [x] Confirm the release copyright holder name as `TennyZhuang`.
- [x] Standardize release wording on `AGPL-3.0-or-later`.
- [x] Audit repository source provenance for obvious copied/adapted upstream code markers and record the limitations.
- [x] Audit in-repo app assets for obvious FlowDown naming/branding reuse and record the limitations.
- [x] Add release documentation that maps shipped builds to repository source revisions and a release checklist.
- [x] Document the repository policy for how modified hosted `opencan-daemon` deployments should expose corresponding source.

## Next

- [ ] Confirm that external marketing materials outside this repository also avoid FlowDown proprietary name, icon, screenshots, and artwork.
- [ ] Review App Store / TestFlight distribution implications for AGPL with counsel before public release.
- [ ] Decide whether to add file-level AGPL notices across source files as an extra provenance hardening step.

## Notes

- Current direct Swift package dependencies: Citadel, MarkdownView, ListViewKit.
- FlowDown is acknowledged as an interface inspiration reference. Its repository currently states that the code is AGPL-3.0, while the FlowDown name, icon, and artwork are proprietary.
- The daemon is part of the same repository and release surface. Do not treat iOS app licensing and daemon licensing as separate unless the repository is restructured accordingly.
- Repository-facing wording should use `GNU Affero General Public License v3.0 or later` / `AGPL-3.0-or-later` consistently.
- The current repo-level provenance audit and release policy are documented in `docs/open-source-release.md`.
