# Claude Usage

A free, open-source macOS menu bar app that shows how much of your Claude plan you've used, and what your Claude Code sessions would cost at API prices.

> **Unofficial.** Claude Usage is a community project. It isn't affiliated with, endorsed by or supported by Anthropic. "Claude" is a trademark of Anthropic.

## Features

- **Live limits in the menu bar.** Your current 5-hour session and weekly usage, with a pace marker that shows whether you're on track to hit the limit before it resets.
- **Multiple accounts.** Personal and work accounts side by side, each signed in separately.
- **Sessions.** Every 5-hour limit window the app has seen, and a searchable list of your Claude Code sessions.
- **Activity.** A contribution-style heatmap of cost, tokens, responses or limit peaks over 3, 6 or 12 months. Hover or click a day to see its numbers and sessions. Also includes streaks, comparisons with the previous period, and a weekday × hour map of when you work.
- **Insights.** Weekly pace, week-over-week change, a projected monthly total, cache savings, and your busiest day, hour, model and project.
- **Claude Code stats.** API-equivalent cost by day, model and project, read from Claude Code's local logs.

## Privacy

- **No analytics and no servers of its own.** The app talks only to `claude.ai`.
- **You sign in on claude.ai's own login page,** shown in a window inside the app. The app never sees your password. Each account's cookies live in their own isolated WebKit store on your Mac.
- **Claude Code logs are read, never modified.** They live under `~/.claude/projects`.
- **Limit history is stored locally** in `~/Library/Application Support/ClaudeUsage/history.json`. Removing an account deletes its history and sign-in.

Limits are read from the same endpoint the claude.ai website uses. It isn't a public API, so a change on Anthropic's side can break this until the app is updated.

## Install

Requires macOS 14 Sonoma or later, on Apple Silicon or Intel.

1. Download the latest `Claude-Usage-<version>.zip` from the Releases page and unzip it.
2. Move **Claude Usage.app** to your Applications folder.
3. The first time you open it, macOS will warn that the app is from an unidentified developer. Releases aren't notarized because that needs a paid Apple Developer account. To allow it:
   - macOS 15 and later: try to open the app once, then go to **System Settings → Privacy & Security** and click **Open Anyway**.
   - macOS 14: right-click the app, choose **Open**, then confirm.

If you'd rather not trust a downloaded binary, building from source takes about a minute.

## Build from source

You need the Xcode Command Line Tools (`xcode-select --install`). Xcode itself isn't required.

```bash
git clone <this repository>
cd claude-usage
./build.sh --install
```

`build.sh` produces a universal app in `build/`. Run it with `--zip` to also create a release archive. The script's header lists optional settings: `VERSION`, `SOURCE_URL`, `TIP_JAR_URL` and `SIGN_IDENTITY`.

### Development

```bash
swift test
```

```bash
CLAUDE_USAGE_SNAPSHOT=/tmp/claude-usage-shots swift run
```

The snapshot command renders every tab to PNG, using sample limit data and your real Claude Code logs, then exits. It's handy for checking UI changes without clicking through the menu bar.

Code layout, all in `Sources/ClaudeUsage`:

| File | What's in it |
| --- | --- |
| `AppModel.swift` | App state, refreshing, limit history, insights |
| `WebSession.swift` | One isolated claude.ai web session per account |
| `LocalStats.swift` | Claude Code log scanner and pricing table |
| `Activity.swift` | Activity tab: heatmap, day details, weekday × hour map |
| `Views.swift` | All other tabs and settings |
| `Models.swift` | Shared types and formatting |

## Support the project

Claude Usage is free and always will be. If it's useful to you, you can leave a tip from **Settings → About** in the app. Bug reports and pull requests are just as welcome.

## License

[MIT](LICENSE)
