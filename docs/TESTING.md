# Testing Flip

`bash scripts/test.sh` runs the automated suites against fake DNS services,
controlled clocks, and temporary control directories. It never changes system DNS.

## Real-network checks

1. Build and open Flip. Compare its current mode with System Settings. Automatic
   should show the plain network icon, without text in the menu bar.
2. Select Public DNS, approve the macOS prompt, and compare the configured
   addresses with `scutil --dns`. Reload a site normally blocked by the home DNS.
   The icon should gain an arrow badge.
3. Select Automatic. Explicit DNS addresses should disappear, network-provided
   DNS should resume, and search domains should be unchanged.
4. Start a 5-minute bypass. The clock badge and countdown should appear. At
   expiry, approve restoration and confirm Automatic returns.
5. Repeat while declining approval. Confirm Restore pending appears, the app
   does not repeatedly prompt, and Restore Automatic Now retries successfully.
6. Sleep past a deadline, wake, and confirm restoration is attempted. Test the
   three quit choices with an active timer.
7. During a timed bypass, change DNS in System Settings. The external edit should
   survive expiry. Confirm disabled, VPN, PPP, and bridge services stay unchanged.

## Assistant control

After restarting the newly built app:

```sh
bash scripts/install-cli.sh
flip --help
flip status
flip bypass --minutes 5
flip status
flip restore
```

Check that results are JSON and the timer appears in the menu. Approve the normal
macOS prompt if requested. Stop the CLI after starting a bypass: the app should
still own and run the timer. With no active timer, restore should leave custom
DNS alone.

While a macOS approval prompt is open, another status call should return
`busy: true`; another bypass should return a busy error. A CLI timeout must not
claim the original request was cancelled. Check status before retrying it.

Quit the app and confirm status returns `app_unavailable` with exit code 1.
Restart it and confirm requests left by a previous session are not replayed.
