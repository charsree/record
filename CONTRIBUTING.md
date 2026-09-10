# Contributing to Record

Thanks for your interest! This project is small and personal, but PRs and issues are welcome.

## Ground rules

- **Local-first is non-negotiable.** No feature should silently phone home. If a feature needs the network, it must be opt-in via Preferences and clearly documented in the README.
- **Keep the dependency tree lean.** Prefer Apple frameworks and small vendored dependencies. Ask before adding a new SwiftPM dependency.
- **Match the existing style.** Swift 6.2. `MeetingSession.shared` is `@MainActor`. Long-running work goes into actors or `Task.detached`.

## Getting set up

```sh
git clone https://github.com/charsree/record.git
cd record
brew install whisper-cpp sqlite
swift build -c release
zsh scripts/build-app.sh
open Build/Record.app
```

## Making a change

1. Fork and create a branch.
2. Run the tests locally: `swift test`.
3. Update relevant documentation (README, code comments).
4. Open a pull request against `main` with a clear description of the change and why.

## Reporting bugs

Open an [issue](https://github.com/charsree/record/issues) with:
- macOS version + Mac model
- Record version (visible in Preferences → General)
- Steps to reproduce
- The tail of `~/Library/Application Support/Record/kiro-stderr.log` if Kiro is involved

## Releasing

Maintainers only:

```sh
zsh scripts/release.sh 0.3.0
gh release create v0.3.0 dist/Record-0.3.0.zip --title "Record 0.3.0"
```

Then update the `Casks/record.rb` in `charsree/homebrew-record` with the new SHA256 printed by the release script.
