# Exercises the oh.ps1 changes on real Windows.
# Run under both Windows PowerShell 5.1 and PowerShell 7 - the launcher ships for 5.1.
$ErrorActionPreference = 'Stop'
$fail = 0

Write-Host "=== PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)) ==="

########################################################################
Write-Host "`n--- 1. oh.ps1 parses ---"
$errors = $null; $tokens = $null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path ./oh.ps1).Path, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors -and $errors.Count -gt 0) {
    $errors | Select-Object -First 5 | ForEach-Object { Write-Host "  line $($_.Extent.StartLineNumber): $($_.Message)" }
    Write-Host "  FAIL"; $fail++
} else { Write-Host "  OK - no syntax errors" }

########################################################################
Write-Host "`n--- 2. settings substitutions, running the real lines from oh.ps1 ---"
# the lines are used as they stand in the file; only the paths are pointed at a scratch copy
$OH_PATH = (Get-Location).Path
$OH_DIR = "t"; $OH_SETTINGS = "settings.properties"
New-Item -ItemType Directory -Force -Path "$OH_PATH/$OH_DIR/rsc" | Out-Null

# only the block inside write_config_files: from the line that generates the file out of the
# template, through the last interface replacement. Matching on $OH_SETTINGS alone also catches
# set_oh_mode and set_language, which run against a file this test has not created yet.
$all = Get-Content ./oh.ps1
$from = ($all | Select-String -SimpleMatch '$OH_SETTINGS.dist").replace("OH_MODE"' | Select-Object -First 1).LineNumber - 1
$to = ($all | Select-String -SimpleMatch 'UI_INTERFACE=off' | Select-Object -Last 1).LineNumber - 1
if ($from -lt 0 -or $to -lt $from) { Write-Host "  FAIL - settings block not located"; $fail++; $settingsLines = @() }
else { $settingsLines = $all[$from..$to] | Where-Object { $_ -match 'rsc/\$OH_SETTINGS' } }
Write-Host "  lines taken from oh.ps1 (rows $($from+1)-$($to+1)): $($settingsLines.Count)"

function Invoke-Settings($api, $gui, $ui) {
    $API_SERVER = $api; $GUI_INTERFACE = $gui; $UI_INTERFACE = $ui
    $OH_MODE = "PORTABLE"; $OH_LANGUAGE = "en"; $OH_DOC_DIR = "doc"
    $PHOTO_DIR = "data/photo"; $OH_SINGLE_USER = "no"; $DEMO_DATA = "off"
    @("APISERVER=off", "GUI_INTERFACE=on", "UI_INTERFACE=off") |
        Set-Content "$OH_PATH/$OH_DIR/rsc/$OH_SETTINGS.dist"
    foreach ($l in $settingsLines) { Invoke-Expression $l }
    (Get-Content "$OH_PATH/$OH_DIR/rsc/$OH_SETTINGS") -join ' '
}

$cases = @(
    @{ api = "off"; gui = "on";  ui = "off"; want = "APISERVER=off GUI_INTERFACE=on UI_INTERFACE=off" },
    @{ api = "on";  gui = "off"; ui = "on";  want = "APISERVER=on GUI_INTERFACE=off UI_INTERFACE=on" },
    @{ api = "on";  gui = "on";  ui = "off"; want = "APISERVER=on GUI_INTERFACE=on UI_INTERFACE=off" }
)
foreach ($c in $cases) {
    $got = Invoke-Settings $c.api $c.gui $c.ui
    if ($got -eq $c.want) { Write-Host "  OK   API=$($c.api) GUI=$($c.gui) UI=$($c.ui) -> $got" }
    else { Write-Host "  FAIL API=$($c.api) GUI=$($c.gui) UI=$($c.ui)`n       got  $got`n       want $($c.want)"; $fail++ }
}

########################################################################
Write-Host "`n--- 3. database_port_open, taken from oh.ps1 ---"
$src = Get-Content ./oh.ps1 -Raw
$i = $src.IndexOf("function database_port_open")
if ($i -lt 0) { Write-Host "  FAIL - function not found"; $fail++ }
else {
    $depth = 0; $j = $i
    while ($true) {
        if ($src[$j] -eq '{') { $depth++ }
        elseif ($src[$j] -eq '}') { $depth--; if ($depth -eq 0) { break } }
        $j++
    }
    Invoke-Expression $src.Substring($i, $j - $i + 1)

    $DATABASE_SERVER = "127.0.0.1"; $DATABASE_PORT = 65031
    if (database_port_open) { Write-Host "  FAIL - reported open with nothing listening"; $fail++ }
    else { Write-Host "  OK   closed port -> False, no exception escaped" }

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 65031)
    $listener.Start()
    if (database_port_open) { Write-Host "  OK   listening port -> True" }
    else { Write-Host "  FAIL - reported closed with a listener up"; $fail++ }
    $listener.Stop()
    Start-Sleep -Milliseconds 300
    if (database_port_open) { Write-Host "  FAIL - still reported open after the listener stopped"; $fail++ }
    else { Write-Host "  OK   listener stopped -> False" }
}

########################################################################
Write-Host "`n--- 4. the real mysqld.exe: a start that fails is not waited out ---"
$mysqld = Get-ChildItem -Path ./pkg -Recurse -Filter mysqld.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $mysqld) { Write-Host "  SKIP - mysqld.exe not found under ./pkg" }
else {
    Write-Host "  using $($mysqld.FullName)"
    New-Item -ItemType Directory -Force -Path ./logs | Out-Null
    # a configuration it will refuse, so the process exits almost at once
    $proc = Start-Process -PassThru -FilePath $mysqld.FullName `
        -ArgumentList "--defaults-file=$OH_PATH\does-not-exist.cnf" `
        -NoNewWindow -RedirectStandardOutput ./logs/out.txt -RedirectStandardError ./logs/err.txt

    $DATABASE_SERVER = "127.0.0.1"; $DATABASE_PORT = 65032
    $DATABASE_WAIT_TIMEOUT = 90
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $waited = 0; $exitedDetected = $false
    while ( !(database_port_open) ) {
        if ($proc -And $proc.HasExited) { $exitedDetected = $true; break }
        if ($waited -ge $DATABASE_WAIT_TIMEOUT) { break }
        Start-Sleep -Seconds 1
        $waited++
    }
    $sw.Stop()
    if ($exitedDetected -and $sw.Elapsed.TotalSeconds -lt 15) {
        Write-Host ("  OK   HasExited caught the dead server after {0:N1}s, not at the {1}s timeout" -f $sw.Elapsed.TotalSeconds, $DATABASE_WAIT_TIMEOUT)
    } else {
        Write-Host ("  FAIL exitedDetected=$exitedDetected after {0:N1}s" -f $sw.Elapsed.TotalSeconds); $fail++
    }
    Write-Host "  mysqld said: $((Get-Content ./logs/err.txt -ErrorAction SilentlyContinue | Select-Object -First 2) -join ' / ')"
}

########################################################################
Write-Host "`n=== failures: $fail ==="
if ($fail -gt 0) { exit 1 }
