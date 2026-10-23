# Contributing

Thanks for wanting to help with Mneme Atrium (记忆花园). Issues and pull requests are welcome, in English or Chinese.

## Before you start

- **Small fixes** (typos, obvious bugs, a missing edge case): just open a PR.
- **Anything bigger** (a new feature, a new import source, a dependency, a refactor that touches many files): open an issue first, so we can agree on the approach before you spend time on it.
- The project is a **0.x preview**. Some areas are being actively reworked: memory, the terminal / sandbox, and the chat page. Changes in those areas may conflict with work in flight, so ask in an issue before starting there.

## How the repository works

This public repository is published as **snapshots** of the maintainer's development repository. When a PR is accepted, it's applied there and comes back in the next snapshot. You stay credited through a `Co-authored-by:` trailer on the resulting commit. The PR is closed with a link to the snapshot that contains it, rather than merged with GitHub's button.

## Contributor License Agreement

Before your first PR can be accepted, you need to sign the [CLA](CLA.md). The CLA Assistant bot posts a link on your PR. You sign once with your GitHub account, and that covers every later PR.

The project is AGPL-3.0, but the app is also distributed through the App Store, and the App Store's terms aren't compatible with the GPL. The CLA lets the maintainer keep shipping the code you contribute there. You keep your copyright. [CLA.md](CLA.md) has the full text.

## Development setup

Follow [BUILDING.md](BUILDING.md). In short:

```sh
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
xcodegen generate
```

Then build the platform you're touching. [ARCHITECTURE.md](ARCHITECTURE.md) explains where things live.

## Making a change

- **`project.yml` is the source of truth.** Never commit the generated `.xcodeproj`. The one exception is the already-tracked `Package.resolved`; update it when you change a package version.
- **Shared code builds for both platforms.** Most of `MemoryPalace/` compiles into both the macOS and the iOS app. If you touch shared code, build both. Wrap platform-specific code in `#if os(iOS)` / `#if os(macOS)`.
- **Match the surrounding code.** Follow its naming, structure, and comment density, even where you'd write it differently. Existing comments are mostly Chinese; new comments can be in English or Chinese.
- **Keep the diff focused.** Every changed line should trace back to what the PR is for. Don't reformat or "tidy up" unrelated code in the same PR; send that separately if you think it's worth doing.
- **No hardcoded names in prompts or UI.** Character and user names come from the active floor's settings, so never write a specific character's or person's name into prompt text or UI strings.
- **New dependencies need an issue first.** Any new Swift package or `cc-bridge` npm dependency must be license-compatible with AGPL-3.0, and gets added to [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
- **Don't copy code you can't license.** If you port or adapt code from elsewhere, say so in the PR and keep its copyright notice. GPLv2-only code can't be combined with this project.

## Tests

- Add or update tests for behavior you change. Unit tests live in `MemoryPalaceTests/` (macOS-hosted). `cc-bridge` tests sit next to their sources as `*.test.ts`.
- Run them before opening the PR (commands in [BUILDING.md § Tests](BUILDING.md#4-tests)).
- **Importers** are tested against synthetic exports, either files under `fixtures/` or data built inside the test. If you fix or add an importer, add a **synthetic** case that reproduces the issue. Never add a real export, even a "harmless" one.

## Privacy: never commit or paste real data

This app handles people's private conversations. In code, fixtures, issues, PRs, screenshots, and logs:

- Don't include real chat logs, export packages, memory dumps, or database files, whether yours or anyone else's.
- Don't include API keys, tokens, passwords, or anything from your keychain.
- Don't include personal paths, hostnames, IP addresses, or account identifiers.

If a bug only reproduces with your data, reduce it to a synthetic example. If you can't, describe the shape of the data (field names, structure, sizes) instead of the content.

## Pull request checklist

- [ ] The PR describes **what** changed and **why**, and links the issue if there is one.
- [ ] It builds on every platform it touches (macOS, and/or iOS Simulator).
- [ ] Tests are added or updated, and they pass.
- [ ] UI changes include before / after screenshots, made with demo data.
- [ ] It contains no private data and no secrets.
- [ ] You've signed the CLA (the bot will tell you).

## Reporting security issues

Don't open a public issue for security problems, such as anything exposing keys, chat data, or the paired-computer bridge. Use GitHub's **"Report a vulnerability"** button on the repository's Security tab instead.

## License

By contributing, you agree that your contributions are licensed under the [GNU AGPL-3.0](LICENSE), with the additional grants described in the [CLA](CLA.md).
