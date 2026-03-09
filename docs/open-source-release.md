# Open Source Release Notes

Last updated: 2026-03-10

## Scope

This document records the repository-level decisions and audits for releasing OpenCAN as open source.

- Copyright holder: `TennyZhuang`
- Repository license: `AGPL-3.0-or-later`
- Covered components in this repository:
  - iOS app target `OpenCAN`
  - bundled remote daemon `opencan-daemon`

## Repository implementation

The repository now exposes the minimum legal surfaces that can be handled in code and docs:

- Root [LICENSE](../LICENSE)
- Root [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)
- Public-facing license and acknowledgements in [README.md](../README.md)
- In-app `About & Licenses` entry in the node list gear menu
- Build-time stamping of source metadata into the app bundle via `Scripts/stamp-build-info.sh`

The app's About screen is intended to satisfy the AGPL interactive notice expectation in a practical way by showing:

- copyright notice
- no-warranty statement
- license reference
- source repository URL
- source revision / commit URL when available

This follows the AGPL guidance around "Appropriate Legal Notices" and source availability for network-interacting software.

## Provenance audit

This audit is limited to what can be confirmed from the current repository contents and git history. It is not a legal guarantee of originality.

### Direct dependencies

Confirmed from `Package.swift` / `project.yml`:

- Citadel
- MarkdownView
- ListViewKit

These are documented in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

### FlowDown-related findings

Repository search currently finds FlowDown references only in:

- docs and acknowledgements
- the `FlowDown-style` comment in `Sources/Views/ChatMessageListView.swift`

No current OpenCAN source file contains an upstream FlowDown copyright header or license header.

### Chat timeline implementation

`Sources/Views/ChatMessageListView.swift` was introduced in this repository history by local commits authored by `TennyZhuang`, beginning with:

- `a992b0ad78db440214ba669b430a9416a937326f` (`feat(ui): trial ListViewKit chat timeline`)
- `79a7a61119972c514fd862ab149f9c2d59dfb00a` (`feat(ui): adopt flowdown-style chat timeline rows`)

This supports the conclusion that the current file is maintained as in-repo code, but it does not by itself prove that no earlier external code was referenced during authorship.

### Branding assets

Current app assets under `Resources/Assets.xcassets` are branded as OpenCAN:

- `AppIcon`
- `LogoFull`
- `LogoMark`
- `LogoTagline`
- `LogoWordmark`

Git history shows these assets were introduced and iterated in commits authored by `TennyZhuang`, including:

- `77551bdf53674c72f8aedde244329e217d60587b` (`Use env-driven integration target and add app icons`)
- `2a9215b03e0c716c611f0dc524f427d0b1c6f1b8` (`Update branding assets from new OpenCAN logo`)

Repository search found no FlowDown icon filenames, screenshots, or artwork filenames inside the current app asset catalog.

### Audit limitations

The following still require maintainer confirmation and cannot be proven from repository inspection alone:

- whether any binary artwork was derived from non-repository source material
- whether external marketing screenshots, videos, or product-page copy reuse FlowDown proprietary assets
- whether any source file was originally drafted from a private copy/paste source and later rewritten enough to remove obvious markers

## Source availability policy

This repository's recommended release policy is:

1. Public app and daemon releases should be cut from a public git revision.
2. Release notes should link to the matching public tag or commit.
3. The app bundle should expose the source repository and build revision in `About & Licenses`.
4. If a modified hosted deployment of `opencan-daemon` is made available to external users, the operator should provide a visible `Source` link or equivalent pointer to the corresponding fork/commit, consistent with AGPL section 13.

This repository can document that policy and expose source links in shipped builds, but it cannot enforce compliance for third-party operators.

## Release checklist

- Confirm all distributed binaries come from a public commit or tag.
- Verify the app's `About & Licenses` page shows a valid source repository URL.
- Verify the app's `About & Licenses` page shows the stamped build revision.
- Ensure release notes and GitHub release text link to the matching source revision.
- Reconfirm no third-party brand assets appear in app icons, screenshots, or App Store metadata.
- Populate App Review information with any context needed for remote-host / daemon-backed behavior.
- Keep `LICENSE`, `THIRD_PARTY_NOTICES.md`, and `README.md` in sync with the actual release.

## Items still requiring human review

- External marketing material provenance
- App Store / TestFlight legal risk tolerance for AGPL distribution
- Employer / school copyright disclaimer, if applicable

## Primary references

- GNU AGPL v3: <https://www.gnu.org/licenses/agpl-3.0.en.html>
- GNU how-to for applying GNU licenses: <https://www.gnu.org/licenses/gpl-howto.en.html>
- Apple App Review Guidelines: <https://developer.apple.com/app-store/review/guidelines/>
- App Store Connect review submission overview: <https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/overview-of-submitting-for-review>
