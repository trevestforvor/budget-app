# Installing the app

The iPhone app is a thin client. Your ledger lives on your server ([INSTALL-SERVER.md](INSTALL-SERVER.md)), and the app reads it and sends your changes back. You build it yourself with Xcode, signed with your own Apple Developer team. There's no App Store or TestFlight build.

## Try it first: the simulator

This needs no server, team or setup:

```sh
brew install xcodegen
xcodegen generate
open Budget.xcodeproj        # pick an iPhone simulator, then Run
```

In the simulator, the app starts on the demo ledger: six months of made-up household data, computed on the device with no server and no model. A real phone never shows the demo. It starts on Connect.

## The short way

Connect your iPhone to this Mac with a cable, unlock it and tap **Trust**. The first time, also turn on Developer Mode ([below](#what-you-need)). Then:

```sh
./setup.sh app
```

This does the following:
1. asks for your team ID and bundle prefix, suggesting the teams signed in to Xcode, and writes them into `Config/Local.xcconfig`. It edits the file in place, so values you set by hand stay, and keeps the old one as `Local.xcconfig.bak` when it changes;
2. for a free Personal Team, writes `BUDGET_FREE_TEAM = YES`, so the app is built without push and Associated Domains;
3. for a paid team with a public https address, writes `BUDGET_API_HOST` for [phone reconnect](#after-its-connected);
4. on a Mac or Docker server, sets the server's `APNS_TEAM_ID`, `APNS_TOPIC` and (with a host) `BUDGET_IOS_APP_ID`, restarts it, and checks that it serves the Universal Link file;
5. generates the Xcode project and builds a Release build;
6. installs it on the phone and opens it with the server's address and token, so it's paired with no typing. The token is read from `budget.env` and never shown: it goes to the app in its launch environment (`BUDGET_TOKEN`), not on a command line.

It ends with **PAIRED**, or **NOT PAIRED** and why. When nothing was installed (no phone, several phones and no pick, or a failed build), it prints **NOT INSTALLED** and exits 1. To update the app later, run `git pull`, then `./setup.sh app` again.

For an agent or a script, give the answers up front: `BUDGET_TEAM_ID=… BUDGET_BUNDLE_PREFIX=com.yourname BUDGET_YES=1 ./setup.sh app`. More choices:
- `BUDGET_FREE_TEAM=1` (or `0`) says whether the team is a free Personal Team, when Xcode doesn't say;
- `BUDGET_RECONNECT=no` leaves phone reconnect out;
- `BUDGET_DEVICE=<name or UDID>` picks a phone when several are connected, or `BUDGET_DEVICE_PICK=<number>` picks by its place in the list it prints;
- `BUDGET_SERVER=none` when the server isn't on this Mac.

## What you need

- **A Mac with Xcode 26 or later.** It can be the server Mac.
- **An Apple Developer team, signed in to Xcode:** Xcode → Settings → Accounts → + (bottom left) → Apple Account → Continue. A free account shows up as "<your name> (Personal Team)".
  - **A paid membership** ($99 a year) gives you the morning summary and pace alerts, signing in to a bank again from the phone, and builds that last a year. Enroll at https://developer.apple.com/programs/enroll/. It needs two-factor authentication and your legal name. As an individual you pay when you enroll; Apple says to contact them if no confirmation comes within 24 hours. An organization needs a D-U-N-S number first, which can take about a week.
  - **A free Personal Team** works too. `./setup.sh app` notices it and sets `BUDGET_FREE_TEAM = YES` in `Config/Local.xcconfig`, which builds the app without push and Associated Domains. The limits: no morning summary or pace alerts, no phone reconnect (sign in to a bank again on the dashboard), at most 3 devices, and the app stops opening after 7 days until you install it again.
- **A bundle ID prefix you own**, such as `com.yourname`. The app becomes `com.yourname.budget`.
- **The phone paired with this Mac, and Developer Mode on.** The Developer Mode setting only appears after the phone has been paired:
  1. Connect the phone with a cable, unlock it, and tap **Trust** on "Trust This Computer". (In Xcode 27, Xcode → Open Developer Tool → Device Hub shows it. Pairing over Wi-Fi needs iOS 27 or later.)
  2. On the phone: Settings → Privacy & Security → **Developer Mode** (under Security), turn it on, and tap **Restart**.
  3. After the restart, unlock the phone. It asks again: tap **Turn On** (Apple's page calls it Enable) and enter your passcode.
- **The developer trusted on the phone**, if it says "Untrusted Developer" the first time the app opens: Settings → General → VPN & Device Management → Developer App → your Apple Account → **Trust**. Newer iOS may say **Allow & Restart** instead. Then run `./setup.sh app` again to pair it.

## By hand

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
#   DEVELOPMENT_TEAM = <your team ID>       a paid team: https://developer.apple.com/account → Membership details
#   BUDGET_BUNDLE_PREFIX = com.yourname
#   BUDGET_FREE_TEAM = YES                  only for a free Personal Team (YES; yes, 1 and true count too)
xcodegen generate
open Budget.xcodeproj         # pick your iPhone, then Run
```

A free Personal Team has no Membership details page. Its team ID shows in `./setup.sh app`'s list, which it reads from Xcode. `Local.xcconfig` is never committed. Run `xcodegen generate` again after changing it or `project.yml`.

## Connect to your server

`./setup.sh app` pairs the phone for you when the server runs on the same Mac and has an https address. Otherwise, on first launch the app asks for two things:
- **Server URL:** the HTTPS address from [INSTALL-SERVER.md step 5](INSTALL-SERVER.md#5-give-the-phone-an-https-address), such as `https://budget.your-domain.com`.
- **Token:** on the dashboard (http://budget.localhost:8081 on the server Mac), go to Settings → Connect your phone and tap **Show**, then copy it from there. Don't paste it into chats or notes.

The app keeps both in the Keychain. You can change them later in Settings → Advanced.

## After it's connected

- **Morning summary:** once the server's Notifications settings are filled in ([INSTALL-SERVER.md step 8](INSTALL-SERVER.md#8-morning-summary-optional)), turn on Settings → Notifications → Morning summary on the phone, then tap **Send one now** to check. Paid teams only.
- **Signing in to a Plaid bank again from the phone (optional, paid teams):** `./setup.sh app` sets this up when it can. It writes `BUDGET_API_HOST` (the host of the server's address, no `https://`) into `Config/Local.xcconfig`, and automatic signing adds Associated Domains to your App ID; there's nothing to turn on at Apple. It's left out for a free team, a Tailscale (`ts.net`) address, an address with a port or a path, or with `BUDGET_RECONNECT=no`. The server needs `BUDGET_IOS_APP_ID` (`<team ID>.<your prefix>.budget`) before the app is installed, and Plaid needs the phone's return address ([the full checklist](INSTALL-SERVER.md#signing-in-to-a-bank-again-from-the-phone)). If the Universal Link file doesn't name the app yet, `./setup.sh app` builds without the host and says to run it again later. Without the host, a bank that wants a sign-in is fixed on the dashboard instead.
- **When the phone needs the dashboard:** adding or removing a bank, and pasting a new SimpleFIN setup token, are always done on the dashboard. When the server has no dashboard address for the phone (`BUDGET_DASHBOARD_URL`, unset on a Mac or Docker install), the phone says to open http://budget.localhost:8081 on the computer that runs your server.
- **App lock:** Settings → Privacy & security → Face ID lock.
- **Check a price:** the Action button and the camera price scanner show a price in hours of work.

## Troubleshooting

| What you see | What to do |
|---|---|
| "No Account for Team" or "No profiles for …" | Sign in to that team in Xcode → Settings → Accounts, then run it again. `./setup.sh app` passes `-allowProvisioningUpdates`, so Xcode creates the profile |
| "Failed to register bundle identifier" | Another team owns that ID. Pick a different `BUDGET_BUNDLE_PREFIX` |
| Push, `aps-environment` or Associated Domains signing errors on a free team | Run `BUDGET_FREE_TEAM=1 ./setup.sh app`, or set `BUDGET_FREE_TEAM = YES` in `Config/Local.xcconfig`, then `xcodegen generate` |
| "maximum number" of apps or devices on a free team | A free team allows 3 devices and 3 apps per device. Remove an old one, or use a paid team |
| `./setup.sh app` says NOT INSTALLED: no iPhone is connected | Unlock the phone, tap Trust, and turn on Developer Mode. Check with `xcrun devicectl list devices` |
| Install fails with "developer mode disabled" | Settings → Privacy & Security → Developer Mode, Restart, then Turn On after the restart |
| "Untrusted Developer" when opening | Settings → General → VPN & Device Management → Developer App → Trust (or Allow & Restart), then `./setup.sh app` again |
| NOT PAIRED | It says why. Usually the server has no https address yet (`./setup.sh address`) or runs on another machine. Enter the address and token on the phone instead |
| On a free team, the app stopped opening after a week | The free profile expired. Run `./setup.sh app` again |
| "Can't reach your server" | Open `https://<address>/health` in Safari on the phone. If that fails, the problem is the server or its address ([INSTALL-SERVER.md → Troubleshooting](INSTALL-SERVER.md#troubleshooting)) |
| The server turns every request away (401) | The token doesn't match. Run `./setup.sh app` again with the phone connected, or copy it again from the dashboard |
| The build log | `./setup.sh app` keeps it at `~/Library/Developer/Xcode/DerivedData/Budget-setup/build.log` (or under `BUDGET_DERIVED`) |
