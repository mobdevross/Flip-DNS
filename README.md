# Flip

A native macOS menu bar app for switching between your network's DNS (including
your home adblocker) and Cloudflare public DNS. Requires macOS 13 or later and
Xcode or the Swift command line tools to build. No third-party dependencies.

## Build and run

```sh
bash scripts/build-app.sh
open 'dist/Flip.app'
```

The menu bar shows only a network icon: plain for Automatic, with an arrow badge
for manual DNS, or a clock badge for a timed bypass. An exclamation mark indicates
an error or pending restoration; a question mark means the DNS state is
unavailable. Hover or open the menu for the current mode and timer. The app has no
Dock icon. Launching it does not change DNS.

For everyday use, move `dist/Flip.app` to Applications, then open that copy.
Enable **Launch at Login** from its menu if desired. Keep the app at a stable
location after enabling that option. The build script signs the app for local
use; it does not require a developer certificate. This build is not notarized for
distribution to other Macs.

Quit the app before rebuilding a copy you are currently running.

If upgrading from DNS Switch, quit that app before opening Flip. The existing
app identifier and saved timers are retained. The previous build is left in place.

## Switch DNS

- **Automatic** removes manually configured DNS server addresses so each network
  service can use DNS supplied by the network.
- **Public DNS** uses Cloudflare's standard unfiltered resolvers:
  `1.1.1.1`, `1.0.0.1`, `2606:4700:4700::1111`, and `2606:4700:4700::1001`.
- **Public DNS for…** offers 5, 15, or 60 minutes, then attempts to restore
  Automatic.

macOS can ask for administrator approval when DNS changes. There is no installed
root helper and the app never stores your administrator password. Re-selecting
a mode already applied to all eligible services does not request approval.

Changes apply together to enabled Wi-Fi and Ethernet services in the current
macOS network location, including disconnected adapters. USB tethering services
that macOS identifies as Ethernet are included. Disabled, VPN, PPP, and bridge
services are left unchanged. DNS search domains and other network settings are
preserved. The app observes changes and checks DNS whenever the menu opens, so
there is no manual Refresh command.

The menu reports configured service DNS, rather than claiming adblocking is on
or off. Browser secure DNS, VPN resolvers, and router DNS interception can take
precedence. Some applications retain cached results; reload or restart the
affected application if a previous DNS answer persists.

## Timed bypasses

Keep Flip running for automatic restoration. The deadline persists across
sleep and app relaunch; an overdue timer is checked when the app resumes. A Mac
that is asleep restores after waking, not while it is asleep.

At expiry, macOS may need administrator approval again. If approval is cancelled
or restoration fails, the icon shows an exclamation badge and the menu shows **Restore
pending**. Choose **Restore Automatic Now…** to retry. The app does not repeatedly
show permission prompts. Public DNS may stay enabled until restoration succeeds.

Restoration affects only the original bypass services whose DNS addresses still
match the public preset. DNS changes made elsewhere are preserved. A successful
manual selection replaces or cancels the timer; a failed selection keeps the
previous timer. Quitting during a timed bypass offers to restore first, keep the
current settings and cancel the timer, or leave the app running.

If a network update fails after saving, the app attempts to restore the complete
previous DNS configuration. An unsuccessful recovery is reported in the menu;
check **System Settings → Network → your connection → Details → DNS** if needed.

## Verify

```sh
bash scripts/test.sh
'dist/Flip.app/Contents/MacOS/DNSSwitch' --diagnose
```

Tests use isolated in-memory network services and clocks; they do not change the
Mac's DNS. `--diagnose` prints the current network location's configured services
as JSON and never requests administrator access or changes settings. An execution
sandbox that blocks SystemConfiguration may prevent this diagnostic from reading
the network; run it in Terminal in that case.

For a manual integration check on the home network:

1. Open the app and compare the current mode with System Settings. The menu bar
   should show a plain icon for Automatic, with no text label.
2. Select **Public DNS**, approve the macOS prompt, and verify the DNS addresses
   in System Settings and with `scutil --dns`. Test a fresh lookup and a website
   normally blocked by the home DNS. The icon should gain an arrow badge.
3. Select **Automatic** and verify that the explicit server addresses are gone
   and network-provided DNS is used again. The icon should return to plain, and
   search domains should be unchanged. Changes made in System Settings should
   update the icon automatically or when opening the menu.
4. Start a 5-minute bypass and leave the app open. Check the expiry prompt and
   restoration; the icon should show a clock while the timer runs. Repeat while
   declining approval, then retry from **Restore
   Automatic Now…**.
5. Start another bypass, sleep past its deadline, and wake the Mac. Also test
   making a different DNS edit in System Settings before expiry; that edit should
   survive the timer. Check the three choices when quitting with a timer active.

## Development

`DNSCore` contains configuration classification, transactional updates, and the
persistent timer model. `DNSSwitch` contains the AppKit menu and the
SystemConfiguration/Authorization Services adapter. DNS work runs on a serial
background queue so permission prompts do not block the menu's main thread.

The build and test scripts keep compiler caches inside `.build/`. SwiftPM's
manifest sandbox is disabled because this package has no dependencies or plugins
and this supports running inside an existing restricted development environment.
There are no runtime sandbox entitlements: changing system DNS uses macOS
Authorization Services.
