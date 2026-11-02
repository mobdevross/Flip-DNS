---
name: flip-dns
description: Diagnose suspected local DNS adblocking when Google Ads, Analytics, advertising or tracking domains, or other services fail to resolve or connect on this Mac. Use Flip for a temporary public-DNS bypass and restore afterward. Applies to local connectivity failures, not API authentication or permission errors.
---

# Flip DNS troubleshooting

Flip is a macOS menu bar app with a JSON CLI. The app owns the DNS changes,
timer, and administrator approval, so a bypass does not depend on the assistant
staying alive. Use `flip` on PATH or `"$HOME/.local/bin/flip"` explicitly.

## Diagnose the local failure

Consider the home network's DNS adblocker when a local lookup or request to an
advertising, analytics, tracking, or other filtered service fails. Inspect the
actual failing hostname and compare resolution or connectivity with a public
resolver when useful. A request that reaches an API and returns an authentication
or permission error needs its normal troubleshooting.

Flip changes this Mac's DNS. It cannot fix requests executed by a hosted connector
or cloud agent on another machine.

## Start a bounded bypass

Use the user's existing task or standing authorization for temporary DNS
troubleshooting; ask before changing DNS only when that authority is missing.

```sh
"$HOME/.local/bin/flip" status
"$HOME/.local/bin/flip" bypass --minutes 5
```

Read the JSON result, not just the exit status. Start your own bypass only from
`status.mode: "automatic"`, with `busy: false`, no `expiresAt`, and
`restorePending: false`. Preserve custom or mixed DNS and any existing bypass.
If public DNS is already selected, investigate the failure without starting a
new timer or taking ownership of the existing configuration.

Prefer five minutes for a diagnostic retry. Use 15 or 60 only when the task calls
for it. Record the returned `expiresAt`, then retry the blocked operation once.
If it still fails, restore your bypass and continue diagnosis instead of cycling DNS.

## Restore the bypass you started

Flip has one shared timer. Avoid overlapping bypasses across assistants. In
cleanup, check status and restore only if the active timer still has the expiry
returned by your request. If another actor replaced or ended it, leave that state
alone. Flip's restore operation also preserves DNS addresses edited elsewhere.

```sh
"$HOME/.local/bin/flip" status
"$HOME/.local/bin/flip" restore
```

Inspect the returned mode and `restorePending`. Report whether the retry worked
and whether restoration succeeded, remains pending, or was left to another actor.

## Handle unavailable or pending control

- `app_unavailable`: open or restart the current Flip app before trying control
  again. Keep restoration owned by Flip rather than changing DNS through another tool.
- `busy`: a change or macOS approval is already in progress; check status before retrying.
- `timeout`: the request was not cancelled and may still finish after approval.
  Check status before issuing another change.
- `restorePending: true` or `change_failed`: approval or a manual retry may be
  needed. Do not claim Automatic is restored or repeatedly trigger prompts.
