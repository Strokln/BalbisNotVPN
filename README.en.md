[Русский](README.md) · [English](README.en.md) · [简体中文](README.zh-CN.md) · [Українська](README.uk.md)

<p align="center"><img src="macos/Resources/Balbis.png" width="112" alt="Balbis icon"></p>
<h1 align="center">BalbisNotVPN</h1>
<p align="center">Balbis by Strokin · AI services, YouTube, and other websites from your macOS menu bar</p>
<p align="center">
<img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-1c2436">
<img alt="Apple Silicon and Intel" src="https://img.shields.io/badge/CPU-Apple_Silicon_%7C_Intel-598bd9">
<img alt="MIT license" src="https://img.shields.io/badge/license-MIT-8ac9af">
</p>

Balbis helps you open selected websites. Click the shield in the menu bar, connect, and continue working. The panel includes country selection, custom websites, launch at login, and connection recovery.

The ready-to-use app runs without Homebrew, Python, Go, or drivers. The interface supports Russian, English, Ukrainian, and Simplified Chinese and follows macOS language preferences. This guide also retains the original Russian labels alongside explanations.


**0.9.0** adds automatic foreign-region comparison before connecting, search and categories with domain switches and undo, a GitHub stable-release check at launch, and actionable connection errors. ⇧⌘B opens Balbis, ⌘Return toggles the connection, ⌘, opens settings, and Esc goes back or closes the panel. Update checks can be disabled in settings; installation remains manual.


**0.10.0** adds Russian, English, Ukrainian, and Simplified Chinese interfaces. The language follows macOS preferences, including an app-specific language for Balbis. Screens, notifications, error messages, and diagnostic report labels are localized; technical identifiers and logs retain their format.

The panel is now 640 points tall, so the normal home screen fits without scrolling.

## Download

**[Latest release and checksums](https://github.com/Strokln/BalbisNotVPN/releases/latest)**

Current disk images are **0.10.0**.

| Your Mac | Download |
| --- | --- |
| Apple Silicon | [Balbis-0.10.0-macOS-arm64.dmg](https://github.com/Strokln/BalbisNotVPN/releases/download/v0.10.0/Balbis-0.10.0-macOS-arm64.dmg) |
| Intel | [Balbis-0.10.0-macOS-x86_64.dmg](https://github.com/Strokln/BalbisNotVPN/releases/download/v0.10.0/Balbis-0.10.0-macOS-x86_64.dmg) |

To identify your processor, open the Apple menu → About This Mac. An Apple chip means Apple Silicon. An Intel processor means the Intel build. See [Apple's guide](https://support.apple.com/en-us/116943) for more information.

Each DMG contains **Balbis.app** and an **Applications** shortcut. **[SHA256SUMS.txt](https://github.com/Strokln/BalbisNotVPN/releases/download/v0.10.0/SHA256SUMS.txt)** contains the checksums for both images.

<details>
<summary>Verify a downloaded image</summary>

Download the DMG and SHA256SUMS.txt from the same release into one folder. In Terminal, change to that folder and run the following command for Intel.

```sh
shasum -a 256 Balbis-0.10.0-macOS-x86_64.dmg
```

Compare the hash with that file's entry in SHA256SUMS.txt. For Apple Silicon, use the filename containing `arm64`. If you downloaded both images, you can check them together.

```sh
shasum -a 256 -c SHA256SUMS.txt
```

</details>

## Interface

<p align="center"><img src="docs/panel.png" width="320" alt="Balbis menu bar panel"></p>

A render of the native panel. Settings open in the same popover. Clicking outside the panel closes it while keeping the connection active.

## Quick start

1. Open the correct DMG, drag **Balbis.app** into **Applications**, and launch it from there.
2. Click the shield in the menu bar and choose **«Избранное»** (Selected sites).
3. In settings, keep **«Зарубежное подключение»** (Overseas connection) **enabled** and the country set to **«Автоматически»** (Automatic).
4. Click **«Подключить»** (Connect). For the first system-proxy connection, authorize helper installation with your administrator password. Wait for **«Подключено»** (Connected).
5. Open the website you need. If it is unavailable, use **Settings → «Проверить подключение»** (Check connection) and the troubleshooting section below.

Use these defaults for your first connection. The connection strategy and network service are under **«Дополнительно»** (Advanced). If Balbis is configured for a different network service, choose the network you use.

If macOS blocks the downloaded app, allow Balbis specifically in Privacy & Security settings. The build has an ad-hoc signature and has not been notarized by Apple.

## Routing modes

| Mode | Websites handled by Balbis | Websites using the overseas exit |
| --- | --- | --- |
| **«Избранное»** (Selected sites) | Domains in the Balbis list and My sites | The overseas list and custom domains when Overseas connection is enabled |
| **«Все сайты»** (All sites) | Domains requested by apps that honor the system proxy | The same overseas list and custom domains |
| **«Ручная настройка»** (Manual setup) | Apps you configure with the local SOCKS address shown in Diagnostics | The same list when Overseas connection is enabled. Existing system proxy settings are retained |

In All sites mode, other domains use local TCP processing without changing country. In Selected sites mode, other websites connect directly. Local addresses and requests by IP have separate routing restrictions. **My sites** rules apply when Overseas connection is enabled.

The **overseas list** includes AI services, YouTube, and other selected services. View it in [foreign.txt](macos/routing/foreign.txt) or extend it through **«Мои сайты»** (My sites). Rules cover subdomains. Enter `example.com` without `https://` or paths. Changes apply at the next connection.

**«YouTube через Balbis»** controls YouTube's overseas route. Turning it off leaves local TCP processing enabled for YouTube. A custom domain in My sites takes priority.

## Direct exclusions

Add domains under **«Исключения»** (Exclusions) to connect to them directly. Enter `example.com` without a URL or path. Rules include subdomains and take priority over the overseas list, My sites, and All sites mode. Changes apply at the next connection.

Exclusions work in system-proxy modes and in the manual-mode router when Overseas connection is enabled. If you use a manually configured client with only local DPI processing, configure bypass rules in that client.

## Main website list

**«Основной список сайтов»** (Main website list) lets you edit the entire bundled base list. Add or remove domains with one domain per line, without URLs or paths. Invalid entries are rejected. You can save an empty list or choose **«Восстановить встроенный»** (Restore bundled list) to return to the defaults.

From the next connection, the saved list replaces both the base list for Selected sites and the built-in overseas base. The YouTube switch still filters its route, My sites is added separately, and explicit exclusions retain highest priority.

## Launch at login and recovery

- **«Запускать вместе с macOS»** (Launch with macOS) opens Balbis in the background after login. If approval is needed, click **«Открыть настройки macOS»** and allow it in System Settings.
- **«Подключаться автоматически»** (Connect automatically) connects with saved settings when Balbis opens, once the network is ready. Enable both switches to connect at login.
- **«Восстанавливать при обрыве»** (Recover after a disconnect) is enabled by default. Balbis checks the route after wake, network changes, and periodically during use. Restarting the route requires three consecutive transport failures. An HTTP 403, 429, or 5xx response alone does not trigger it. Recovery also runs when an engine exits.
- Failed reconnection attempts wait **5, 15, 30, then 60 seconds**. **«Отключить»** (Disconnect) or **«Отменить»** (Cancel) stops attempts for the current app session. The automatic-connection preference still applies the next time Balbis opens.

If helper setup is unfinished, connect manually once. You can change the country while connected. If the new route fails to start, Balbis attempts to restore the previous one.

## Failure notifications

**«Уведомлять о сбоях»** (Notify about failures) is optional and off until you enable it. macOS permission is requested only when you explicitly turn it on.

After several failed connection or recovery attempts, Balbis sends one notification for that outage. Automatic retries continue with the existing **5, 15, 30, then 60 second** delays. The notification offers **«Повторить»** (Retry) and **«Открыть настройки»** (Open settings). Successful recovery or a manual disconnect resets the outage episode. Further notices are possible only for a new episode.

## Troubleshooting

| What happens | What to do |
| --- | --- |
| macOS blocks startup | Move the app into Applications and allow Balbis in Privacy & Security settings |
| Balbis reports another VPN or occupied proxy settings | Check which app controls the connection. Disconnect it before using Balbis's system-proxy mode. Manual setup is available for use alongside another connection |
| Status is Connected, but a site will not open | Run Check connection. If the overseas exit is restricted, try a different country |
| A website returns 403 or asks for verification | The website may restrict the shared overseas IP. Try another region and check the website separately |
| Settings remain from an earlier session | Open Settings → Diagnostics → **«Восстановить настройки»** (Restore settings) |
| Balbis reconnects repeatedly | Open Settings → Diagnostics → **«Причины переподключений»** (Reconnection reasons). Turn off Recover after a disconnect to temporarily stop retries |
| Balbis does not connect at login | Check both startup switches, macOS approval, and complete the first connection manually |

If the issue persists, [open an Issue](https://github.com/Strokln/BalbisNotVPN/issues/new/choose). Include your Balbis version, macOS version, processor, and reproduction steps. For disconnects, attach the reconnection log after removing personal information.

<details>
<summary>Why an administrator password is needed</summary>

The first system-proxy connection installs a restricted service. It runs through launchd, serves one authorized user account, and can check readiness, enable Balbis's loopback PAC, and restore settings it has recorded. It cannot execute arbitrary commands.

Enter the password in the macOS system dialog. Connections then use the installed helper. Reinstallation or a change of user may require authorization again. You can remove the helper from Diagnostics.

</details>

## Diagnostic report

Inside **«Диагностика»** (Diagnostics), click **«Подготовить отчёт»** (Prepare report). The preview appears inside that existing Diagnostics section of the settings panel. Review the selectable text, then use **«Сохранить отчёт…»** (Save report) to choose a `.txt` file in the macOS save dialog. Nothing is uploaded automatically.

The report contains the app and macOS versions, architecture, connection flags, a file-only helper installation check, and up to **100 recent structured events** from a bounded **16 KB** tail. Only recognized event formats are included. IP addresses, accounts, home paths, domain lists, tokens, and raw requests are excluded. Raw engine logs are not included.

## Scope and limitations

- Balbis uses proxies and TCP processing. System-wide TUN routing, UDP, QUIC, and voice calls are unsupported. Apps that ignore system proxies may connect directly.
- The shared Opera/SurfEasy overseas exit may be slow or unavailable. Access to a particular website or account depends on its restrictions. An OpenAI API response does not verify an authenticated ChatGPT session.
- The minimum version is **macOS 13**. Runtime testing was performed on **macOS 13.7.8 Intel**. ARM64 builds have been checked for architecture and signature. Execution on physical Apple Silicon has not yet been tested. **macOS 27 has not been tested**.
- Builds are **ad-hoc signed**. Apple notarization and automatic updates are not available yet.

See [Releases](https://github.com/Strokln/BalbisNotVPN/releases) for the changelog. [0.8.0](https://github.com/Strokln/BalbisNotVPN/releases/tag/v0.8.0) adds a main-list editor, direct exclusions, optional failure notifications, and a local diagnostic report. Version 0.7.1 fixed misleading reconnection states and handling of failed background checks.

## Complete removal

1. Disconnect Balbis. If it reports an unfinished session, restore its settings through Diagnostics first.
2. Turn off **Launch with macOS** and **Connect automatically**.
3. Open Settings → Diagnostics, click **«Удалить службу подключения»** (Remove connection helper), and approve the macOS prompt.
4. Quit Balbis using the power button at the bottom of Settings, then move the app from Applications to Trash.
5. To remove custom domains and logs, move `~/Library/Application Support/Balbis macOS` to Trash after quitting the app.

To remove saved switches and connection preferences, run this after quitting.

```sh
defaults delete local.balbis.macos
```

If the preferences domain is already absent, the command reports that. Removing these data is optional when uninstalling the app and service.

## Build and test

You need macOS and Apple Command Line Tools (`xcode-select --install`).

```sh
./macos/build.sh universal
# Or a single architecture
./macos/build.sh x86_64
./macos/build.sh arm64
```

The script produces `macos/build/Balbis.app` and a ZIP. Use the universal archive to create separate DMGs.

```sh
./macos/package-dmg.sh arm64
./macos/package-dmg.sh x86_64
```

The scripts compile tpws from included sources and download SHA-256-pinned opera-proxy binaries and, when needed, Go into local project directories. The first build needs network access. No global Go or Homebrew installation is required.

Run `./macos/test.sh` and `./macos/test-runtime.sh` for checks. They use local servers and isolated settings for lifecycle tests. A real overseas exit is checked separately. See [CONTRIBUTING.md](CONTRIBUTING.md) to contribute.

## Licenses

Balbis's native code is [MIT, © 2026 Strokin](LICENSE). The initial domain list was built from the list supplied by the user.

Third-party components retain their licenses and authorship — [tpws / zapret](macos/engine/THIRD_PARTY_NOTICES.md), [epoll-shim](macos/engine/EPOLL-SHIM-LICENSE), [opera-proxy and dependencies](macos/tunnel/THIRD_PARTY_NOTICES.md), [full license texts](macos/tunnel/licenses). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for details.

Balbis is not affiliated with or supported by Opera or SurfEasy. Their public service has its own terms and availability limits.
