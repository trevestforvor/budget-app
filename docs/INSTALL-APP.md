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

Connect your iPhone to this Mac with a cable, unlock it and tap **Trust**. Then:

```sh
./setup.sh app
```

This does the following:
1. asks for your team ID and bundle prefix, suggesting the teams signed in to Xcode, and writes `Config/Local.xcconfig`;
2. generates the Xcode project;
3. builds a Release build;
4. installs it on the phone and opens it.

When it's done, it prints your server's address and where to find the token. To update the app later, run `git pull`, then `./setup.sh app` again.

For an agent or a script, give the answers up front: `BUDGET_TEAM_ID=… BUDGET_BUNDLE_PREFIX=com.yourname BUDGET_YES=1 ./setup.sh app`. If more than one phone is connected, add `BUDGET_DEVICE=<name or UDID>`.

## What you need

- **A Mac with Xcode 26 or later.** It can be the server Mac.
- **An Apple Developer team, signed in to Xcode** (Xcode → Settings → Accounts).
  - A paid membership ($99 a year) gives you the morning push, and builds that last a year.
  - A free Personal Team works too, with two limits: no push, and the app stops opening after 7 days until you install it again. Before building, remove the `entitlements:` block from `project.yml` in your copy, or signing fails.
- **A bundle ID prefix you own**, such as `com.yourname`. The app becomes `com.yourname.budget`.
- **Developer Mode on the phone:** Settings → Privacy & Security → Developer Mode. The phone restarts. The setting only appears after the phone has been connected to Xcode once.

## By hand

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
#   DEVELOPMENT_TEAM = <your team ID>           https://developer.apple.com/account → Membership details
#   BUDGET_BUNDLE_PREFIX = com.yourname
xcodegen generate
open Budget.xcodeproj         # pick your iPhone, then Run
```

`Local.xcconfig` is never committed. Run `xcodegen generate` again after changing it or `project.yml`.

## Connect to your server

On first launch, the app asks for two things:
- **Server URL:** the HTTPS address from [INSTALL-SERVER.md step 5](INSTALL-SERVER.md#5-give-the-phone-an-https-address), such as `https://budget.your-domain.com`.
- **Token:** on the dashboard (http://budget.localhost:8081 on the server Mac), go to Settings → Connect your phone and tap **Show**, then copy it from there. Don't paste it into chats or notes.

The app keeps both in the Keychain. You can change them later in Settings → Advanced.

## After it's connected

- **Morning summary:** in the app's Settings, once the server's Notifications settings are filled in ([INSTALL-SERVER.md step 8](INSTALL-SERVER.md#8-morning-summary-optional)). The server needs the app's bundle ID, `<your prefix>.budget`.
- **App lock:** Settings → Privacy & security → Face ID lock.
- **Check a price:** the Action button and the camera price scanner show a price in hours of work.

## Troubleshooting

| What you see | What to do |
|---|---|
| "No Account for Team" or "No profiles for …" | Sign in to that team in Xcode → Settings → Accounts, then run it again. `./setup.sh app` passes `-allowProvisioningUpdates`, so Xcode creates the profile |
| "Failed to register bundle identifier" | Another team owns that ID. Pick a different `BUDGET_BUNDLE_PREFIX` |
| Push or `aps-environment` signing errors on a free team | Remove the `entitlements:` block from `project.yml`, then `xcodegen generate` |
| `./setup.sh app` says no iPhone is connected | Unlock the phone, tap Trust, and turn on Developer Mode. Check with `xcrun devicectl list devices` |
| Install fails with "developer mode disabled" | Settings → Privacy & Security → Developer Mode, then restart the phone |
| "Untrusted Developer" when opening | Settings → General → VPN & Device Management, then trust your team |
| On a free team, the app stopped opening after a week | The free profile expired. Run `./setup.sh app` again |
| "Can't reach your server" | Open `https://<address>/health` in Safari on the phone. If that fails, the problem is the server or its address ([INSTALL-SERVER.md → Troubleshooting](INSTALL-SERVER.md#troubleshooting)) |
| The server turns every request away (401) | The token doesn't match. Copy it again from the dashboard |
| The build log | `./setup.sh app` keeps it at `~/Library/Developer/Xcode/DerivedData/Budget-setup/build.log` |
