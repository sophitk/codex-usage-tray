$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('usage-fixture-' + [guid]::NewGuid().ToString('N'))
try {
    $day = Join-Path $root ('sessions\' + [DateTime]::Today.ToString('yyyy/MM/dd'))
    New-Item -ItemType Directory -Path $day -Force | Out-Null
    $older = Join-Path $day 'older-event.jsonl'
    $newer = Join-Path $day 'newer-event.jsonl'
    function Write-Fixture($file, $stamp, $used, $modified) {
        $event = @{ type='event_msg'; timestamp=$stamp; payload=@{ type='token_count'; rate_limits=@{
            primary=@{ used_percent=$used; window_minutes=300; resets_at=2000000000 }; secondary=$null; plan_type='fixture'
        } } }
        Set-Content -LiteralPath $file -Value ($event | ConvertTo-Json -Depth 8 -Compress) -Encoding UTF8
        (Get-Item -LiteralPath $file).LastWriteTimeUtc = $modified
    }
    $now = [DateTime]::UtcNow
    Write-Fixture $older ($now.AddMinutes(-10).ToString('o')) 80 $now
    Write-Fixture $newer ($now.AddMinutes(-1).ToString('o')) 25 ($now.AddMinutes(-20))
    $scriptFile = Join-Path $PSScriptRoot '..\CodexUsageTray.ps1'
    $result = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptFile -Once -Json -CodexHome $root | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $result.RemainingPercent -ne 75 -or $result.PlanType -ne 'fixture') {
        throw 'Expected latest event timestamp to win over file modification order.'
    }
    Write-Output 'PASS: synthetic fixture selects freshest event across files; no real session data read.'
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFileName($resolved)).StartsWith('usage-fixture-')) {
        throw 'Refusing cleanup outside the owned temporary fixture.'
    }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
