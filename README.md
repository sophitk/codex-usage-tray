# Codex Usage Tray

An unofficial, local-only Windows tray widget for reading remaining usage from Codex session events. Not affiliated with or endorsed by OpenAI.

## Requirements and run
Windows 10/11 with Windows PowerShell 5.1 and desktop UI support. Double-click Start-CodexUsageTray.cmd.

For a read-only diagnostic, run:

    powershell.exe -NoProfile -File .\CodexUsageTray.ps1 -Once

Add -Json for structured output or -CodexHome to select another local Codex directory.

## Behavior
- Green ≥50%, amber 20–49%, red <20% remaining.
- Refreshes every 30 seconds. Startup integration is opt-in.
- Uses local event files; no API key and no network requests.
- Compares event timestamps within recent candidate files. It does not guarantee that local events reflect current account limits.

## Privacy and limitations
No session logs are included. JSON diagnostics include a local source path; redact it before sharing. Parser compatibility depends on the local event schema. Candidate scan is limited to recent folders/files/tail lines.

## Test
Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\UsageFixture.Tests.ps1

## Portfolio focus
Windows tray UX, PowerShell event parsing and freshness handling. Developed with AI assistance.

## License
MIT — see LICENSE and LICENSE-STATUS.md.
