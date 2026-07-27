# Contributing to Fastgram

Thanks for taking an interest. Fastgram is a small fork of
[Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS), so the rules here are short.

## Before you start

- **Bugs in Telegram itself belong upstream.** If the same behaviour happens in the official
  Telegram app, report it to Telegram, not here.
- **Open an issue before a large change.** Big or invasive pull requests that nobody asked for
  are likely to be declined, no matter how good they are.
- **Build it first.** See [docs/BUILDING.md](../docs/BUILDING.md). You need your own Telegram
  `api_id` / `api_hash`.

## The rules

1. **One concern per pull request.** Keep the diff limited to the thing you set out to change.
2. **No drive-by reformatting.** Whitespace and style cleanups go in their own pull request, not
   mixed into a functional change.
3. **Match the surrounding code.** Naming, structure and comment density should look like the
   file you're editing. PascalCase for types, camelCase for values and methods.
4. **Never commit secrets.** No API credentials, certificates, provisioning profiles, passwords
   or personal paths. `build-system/fastgram-local-configuration.json` stays git-ignored.
5. **Test what you changed.** Run the app and exercise the affected screen; if the module has
   tests, run them.
6. **Write a real commit message.** Say what changed and why, and reference the issue it fixes.

## Merging upstream

Fastgram tracks upstream Telegram-iOS. If your change touches code that upstream also owns, keep
it as close to upstream's shape as you can — every divergence is a future merge conflict.

```bash
git remote add upstream https://github.com/TelegramMessenger/Telegram-iOS.git
git fetch upstream master
git rebase upstream/master
```

## Licensing

By contributing you agree that your contribution is licensed under the GNU General Public
License, version 2 or any later version, in line with [COPYING](../COPYING).
