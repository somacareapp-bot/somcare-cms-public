# SomCare CMS installer for Windows (Docker based) - v2
# Run install.bat to install, update.bat to update later.
param([switch]$Update)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$Repo    = 'somacareapp-bot/somcare-cms'
$Root    = 'C:\SomCare'
$App     = Join-Path $Root 'app'
$Compose = Join-Path $App 'docker\docker-compose.yml'
$EnvRoot = Join-Path $App '.env'
$Backups = Join-Path $Root 'backups'
$AppUrl  = 'http://localhost'

function Say($m)  { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "WARNING: $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host ""; Write-Host "ERROR: $m" -ForegroundColor Red; Read-Host 'Press Enter to close'; exit 1 }
function DC       { docker compose -f $Compose --env-file $EnvRoot @args }

function New-Secret([int]$n = 32) {
    $c = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $b = New-Object byte[] $n
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    -join ($b | ForEach-Object { $c[$_ % $c.Length] })
}

# ---- 1. Run as administrator ----
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Update) { $a += '-Update' }
    Start-Process powershell -Verb RunAs -ArgumentList $a
    exit
}

# ---- 2. Check this PC ----
Say 'Checking this PC'
if (-not [Environment]::Is64BitOperatingSystem) { Fail '64-bit Windows 10 or 11 is required.' }
$ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
if ($ram -lt 8) { Warn "This PC has only $ram GB of memory. 8 GB or more is recommended." }

# ---- 3. Docker Desktop ----
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Say 'Installing Docker Desktop (several minutes)'
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Fail 'Please install Docker Desktop from docker.com, restart the PC, then run install.bat again.'
    }
    winget install -e --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements
    Write-Host ''
    Write-Host 'Docker Desktop is installed. Now: 1) RESTART the PC, 2) open Docker Desktop once and accept its terms, 3) run install.bat again.' -ForegroundColor Yellow
    Read-Host 'Press Enter to close'
    exit
}

Say 'Waiting for Docker to start'
$ready = $false
for ($i = 0; $i -lt 48; $i++) {
    cmd /c "docker info >nul 2>&1"
    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    if ($i -eq 0) {
        $dd = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
        if (Test-Path $dd) { Start-Process $dd }
    }
    Start-Sleep -Seconds 5
}
if (-not $ready) { Fail 'Docker did not start. Open Docker Desktop, wait until it says Running, then run this again.' }

# ---- 4. Get the code from GitHub ----
function Get-Code {
    Say 'Downloading SomCare from GitHub'
    $sec = Read-Host 'Paste the GitHub access token (it stays hidden)' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    $tok = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $zip = Join-Path $env:TEMP 'somcare.zip'
    $tmp = Join-Path $env:TEMP 'somcare_x'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest "https://api.github.com/repos/$Repo/zipball/main" -Headers @{ Authorization = "token $tok"; 'User-Agent' = 'somcare-installer' } -OutFile $zip
    } catch {
        Fail 'Download failed. Check the internet connection and that the token has repo access.'
    } finally { $tok = $null }
    Expand-Archive $zip $tmp -Force
    $src = (Get-ChildItem $tmp -Directory | Select-Object -First 1).FullName
    New-Item $App -ItemType Directory -Force | Out-Null
    # keep real settings and user uploads when updating
    robocopy $src $App /E /XF .env /XD uploads backups node_modules /NFL /NDL /NJH /NJS | Out-Null
    Remove-Item $zip, $tmp -Recurse -Force
}

New-Item $Root, $Backups -ItemType Directory -Force | Out-Null

if ($Update -and (Test-Path (Join-Path $Root 'backup.ps1'))) {
    Say 'Backing up the database before updating'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'backup.ps1')
}
if ($Update -or -not (Test-Path $Compose)) { Get-Code }
if (-not (Test-Path $Compose)) { Fail "Could not find docker\docker-compose.yml in $App" }

# ---- 5. Settings and secrets (first install only) ----
$DbPass = New-Secret 24
$script:DbPassUsed = $false

function Get-Generated([string]$k) {
    if ($k -match 'EXPIRE|TTL|TIME|URL|HOST|PORT|NAME|USER|ORIGIN') { return $null }
    if ($k -match '(DB|POSTGRES|DATABASE).*PASS') { $script:DbPassUsed = $true; return $DbPass }
    if ($k -match 'PASS|SECRET|KEY|TOKEN') { return (New-Secret 48) }
    return $null
}

if (-not (Test-Path $EnvRoot)) {
    Say 'Creating settings with new random passwords'
    $names = Select-String -Path $Compose -Pattern '\$\{([A-Za-z0-9_]+)' -AllMatches |
        ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    $lines = @(); $missing = @()
    foreach ($n in $names) {
        $v = Get-Generated $n
        if ($v) { $lines += "$n=$v" } else { $missing += $n; $lines += "$n=" }
    }
    Set-Content $EnvRoot $lines -Encoding ascii
    if ($missing.Count -gt 0) { Warn ("Empty values in $EnvRoot (fill in if the app needs them): " + ($missing -join ', ')) }
}

$services = @(DC config --services)
$dbSvc = $services | Where-Object { $_ -match 'postgres|db|database' } | Select-Object -First 1
$beSvc = $services | Where-Object { $_ -match 'backend|api|server' } | Select-Object -First 1

# What the database container will REALLY use (resolved by compose), so the backend always matches it
$cfg = (DC config) -join "`n"
function Get-Resolved([string]$name) {
    if ($cfg -match "(?m)^\s*$name\s*:\s*[`"']?([^`"'\r\n]+)[`"']?\s*$") { return $Matches[1].Trim() }
    return $null
}
$pgPass = Get-Resolved 'POSTGRES_PASSWORD'
$pgUser = Get-Resolved 'POSTGRES_USER'
$pgDb   = Get-Resolved 'POSTGRES_DB'
$nodeEnv = Get-Resolved 'NODE_ENV'
if ($nodeEnv -eq 'production') { Warn 'NODE_ENV is production. If tables are not created automatically, the backend needs migrations; tell your developer.' }

$ex = Join-Path $App 'backend\.env.example'
$be = Join-Path $App 'backend\.env'
if (-not (Test-Path $be) -and (Test-Path $ex)) {
    $out = Get-Content $ex | ForEach-Object {
        if ($_ -match '^\s*([A-Za-z0-9_]+)\s*=(.*)$') {
            $k = $Matches[1]
            if     ($k -match '^(DB|DATABASE|POSTGRES|TYPEORM).*HOST$' -and $dbSvc)            { "$k=$dbSvc" }
            elseif ($k -match '^(DB|DATABASE|POSTGRES|TYPEORM).*PASS' -and $pgPass)           { "$k=$pgPass" }
            elseif ($k -match '^(DB|DATABASE|POSTGRES|TYPEORM).*(USER|USERNAME)$' -and $pgUser) { "$k=$pgUser" }
            elseif ($k -match '^(DB|DATABASE|POSTGRES|TYPEORM).*(NAME)$' -and $pgDb)           { "$k=$pgDb" }
            else {
                $v = Get-Generated $k
                if ($v) { "$k=$v" } else { $_ }
            }
        } else { $_ }
    }
    Set-Content $be $out -Encoding ascii
    Warn "Review $be once (database name, user, host, and any email/SMS settings)."
}

# ---- 6. Build and start ----
Say 'Building and starting SomCare (first time: 5 to 15 minutes)'
DC up -d --build
if ($LASTEXITCODE -ne 0) { Fail 'Could not start SomCare. Send the red text above to your developer.' }

Say 'Waiting for the app to answer'
$up = $false
for ($i = 0; $i -lt 40; $i++) {
    try { $r = Invoke-WebRequest $AppUrl -UseBasicParsing -TimeoutSec 5; if ($r.StatusCode -lt 500) { $up = $true; break } } catch { }
    Start-Sleep -Seconds 5
}
if (-not $up) { Warn 'App did not answer yet. Check with: docker compose ps  (and logs with: docker compose logs backend)' }
DC ps

# ---- 7. First-time database setup ----
$marker = Join-Path $Root '.seeded'
if (-not (Test-Path $marker) -and $beSvc) {
    Say 'Preparing the database (roles, permissions, first users)'
    DC exec -T $beSvc npm run seed
    if ($LASTEXITCODE -eq 0) { Set-Content $marker (Get-Date) }
    else { Warn 'Database setup did not finish. Send the text above to your developer.' }
}

# ---- 8. Daily backup at 2 AM (runs as the logged-in user, because Docker Desktop belongs to that user) ----
$bk = @'
$cid = & docker compose -f '__COMPOSE__' --env-file '__ENV__' ps -q __DB__
if (-not $cid) { exit 1 }
$name = 'somcare_{0:yyyyMMdd_HHmm}.dump' -f (Get-Date)
docker exec $cid sh -c 'pg_dump -U $POSTGRES_USER -d $POSTGRES_DB -Fc -f /tmp/somcare.dump'
if ($LASTEXITCODE -ne 0) { exit 1 }
docker cp "${cid}:/tmp/somcare.dump" (Join-Path '__BK__' $name)
Get-ChildItem '__BK__' -Filter *.dump | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | Remove-Item -Force
'@
if ($dbSvc) {
    $bk = $bk.Replace('__COMPOSE__', $Compose).Replace('__ENV__', $EnvRoot).Replace('__DB__', $dbSvc).Replace('__BK__', $Backups)
    Set-Content (Join-Path $Root 'backup.ps1') $bk -Encoding ascii
    try {
        $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Root\backup.ps1`""
        $trg = New-ScheduledTaskTrigger -Daily -At 2am
        $pr  = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
        $st  = New-ScheduledTaskSettingsSet -StartWhenAvailable
        Register-ScheduledTask -TaskName 'SomCareBackup' -Action $act -Trigger $trg -Principal $pr -Settings $st -Force | Out-Null
    } catch { Warn 'Could not create the daily backup task. Run backup.ps1 by hand to test.' }
    Say 'Testing a backup now'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'backup.ps1')
    if ((Get-ChildItem $Backups -Filter *.dump -ErrorAction SilentlyContinue).Count -eq 0) { Warn 'Test backup produced no file. Tell your developer.' }
}

# ---- 9. Shortcut and finish ----
Set-Content (Join-Path $env:PUBLIC 'Desktop\SomCare.url') "[InternetShortcut]`r`nURL=$AppUrl"
Say 'Done'
Write-Host "SomCare is running at $AppUrl" -ForegroundColor Green
Write-Host "Files:    $App"
Write-Host "Backups:  $Backups (daily at 2 AM, kept 30 days; the PC must be on and signed in)"
Write-Host 'IMPORTANT: sign in and change the starting passwords of every seeded account.' -ForegroundColor Yellow
Start-Process $AppUrl
Read-Host 'Press Enter to close'
