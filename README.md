# whocan

One screen for every macOS privacy permission your terminal has — instead of clicking through a dozen panes in System Settings.

```
  Privacy permissions for iTerm.app (com.googlecode.iterm2)

  ● Accessibility                    granted
  ○ Screen & System Audio Recording  off        denied or never asked
  ● Input Monitoring                 granted
  ○ Camera                           not asked
  ○ Microphone                       not asked
  ...
  ● Automation                       granted    finder
  ○ Full Disk Access                 unknown    check in Settings
```

## Install

```sh
brew install mahdi/tap/whocan
```

Or build from source (Xcode or the Swift toolchain required):

```sh
git clone https://github.com/mahdi/whocan && cd whocan
swift build -c release && cp .build/release/whocan /usr/local/bin/
```

## Usage

```sh
whocan               # show the table
whocan --json        # machine-readable output
whocan open camera   # jump straight to that pane in System Settings
```

Keys for `open`: `accessibility screen input camera microphone contacts calendars reminders photos location bluetooth speech automation fda files devtools network`

## How it works

macOS attributes privacy (TCC) permissions to the *responsible process* — the app that launched you. When you run `whocan` from iTerm, Terminal, Ghostty or an IDE's terminal, it reports that app's grants.

It only uses Apple's public, non-prompting preflight APIs (`AXIsProcessTrusted`, `CGPreflightScreenCaptureAccess`, `AVCaptureDevice.authorizationStatus`, `AEDeterminePermissionToAutomateTarget`, …). It never triggers a permission prompt and never reads the TCC database.

### Limitations

- **Accessibility, Screen Recording, Input Monitoring** can only report granted vs. not granted, so "off" means denied *or* never asked.
- **Automation** is checked against a few common targets (System Events, Finder, Terminal, Safari), not every app.
- **Full Disk Access, Files & Folders, Developer Tools, Local Network** have no safe public API; `whocan` links you to the pane instead.

## License

MIT
