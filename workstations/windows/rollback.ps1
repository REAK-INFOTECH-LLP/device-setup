#Requires -Version 5.1
<#
.SYNOPSIS
    Reverts the changes made by workstations/windows/setup.ps1.

.DESCRIPTION
    Windows counterpart of workstations/ubuntu/rollback.sh. By default it:
      1. Restores the SSH configuration (removes the REAK hardening block, or
         restores the original file saved by setup.ps1) and restarts sshd.
      2. Removes the given SSH public key from the authorized key files.
      3. Removes the Fleet agent (stops the services, uninstalls the package and
         deletes the leftover state).

    Optional:
      -RemoveUser  delete the workstation user account and its profile.
      -RemoveApps  best-effort removal of the applications installed by setup.ps1.

.PARAMETER Username
    Workstation account. Default: reak (or REAK_USERNAME).

.PARAMETER SshUser
    Account allowed to log in over SSH. Default: administrator (or
    REAK_SSH_USER).

.PARAMETER SshPubKey
    The public key to remove. Can also be supplied through SSH_PUB_KEY.

.EXAMPLE
    $env:SSH_PUB_KEY = (Get-Content C:\keys\reak-admin.pub -Raw)
    .\rollback.ps1
#>
[CmdletBinding()]
param(
    [string] $Username = '',
    [string] $SshUser = '',
    [string] $SshPubKey = '',
    [switch] $RemoveUser,
    [switch] $RemoveApps
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:SshdConfigMarkerBegin = '# >>> REAK managed hardening'
$script:SshdConfigMarkerEnd = '# <<< REAK managed hardening'

function Write-Info {
    param([string] $Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string] $Message)
    Write-Host "[ OK ] $Message" -ForegroundColor Green
}

function Write-WarnMessage {
    param([string] $Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string] $Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Stop-WithError {
    param([string] $Message)
    $script:AbortReason = $Message
    Write-Fail $Message
    exit 1
}

function Get-Setting {
    param(
        [string] $ParameterValue,
        [string] $EnvironmentName,
        [string] $Default
    )
    if (-not [string]::IsNullOrWhiteSpace($ParameterValue)) { return $ParameterValue }
    $fromEnv = [Environment]::GetEnvironmentVariable($EnvironmentName)
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) { return $fromEnv.Trim() }
    return $Default
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-UserProfilePath {
    param([Parameter(Mandatory = $true)][string] $Name)
    try {
        $account = New-Object Security.Principal.NTAccount($Name)
        $sid = $account.Translate([Security.Principal.SecurityIdentifier]).Value
        $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
        $entry = Get-ItemProperty -Path $key -ErrorAction Stop
        if ($entry.ProfileImagePath) { return $entry.ProfileImagePath }
    } catch {
        Write-Verbose 'No profile registry entry was found, using the default profile location.'
    }
    return (Join-Path $env:SystemDrive ("Users\" + $Name))
}

function Remove-PublicKeyFromFile {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Key
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
    if (-not $lines) { return }
    $kept = @($lines | Where-Object { $_.Trim() -ne $Key.Trim() })
    if ($kept.Count -eq $lines.Count) { return }
    if ($kept.Count -eq 0) {
        Set-Content -LiteralPath $Path -Value @() -Encoding ASCII
    } else {
        Set-Content -LiteralPath $Path -Value $kept -Encoding ASCII
    }
    Write-Ok "Removed the public key from $Path"
}

function Uninstall-MsiProduct {
    param([string] $DisplayNamePattern)
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        $keys = Get-ChildItem -Path $root -ErrorAction SilentlyContinue
        foreach ($key in $keys) {
            $properties = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            if (-not $properties) { continue }
            if ($properties.DisplayName -notlike $DisplayNamePattern) { continue }
            $productCode = $properties.PSChildName
            Write-Info "Uninstalling '$($properties.DisplayName)' ..."
            $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/x', $productCode, '/qn', '/norestart') -Wait -PassThru -WindowStyle Hidden
            if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010 -or $process.ExitCode -eq 1641) {
                Write-Ok "Removed '$($properties.DisplayName)'."
            } else {
                Write-WarnMessage "Uninstalling '$($properties.DisplayName)' failed with exit code $($process.ExitCode)."
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Resolve settings
# ---------------------------------------------------------------------------

$Username = Get-Setting -ParameterValue $Username -EnvironmentName 'REAK_USERNAME' -Default 'reak'
$SshUser = Get-Setting -ParameterValue $SshUser -EnvironmentName 'REAK_SSH_USER' -Default 'administrator'
$SshPubKey = Get-Setting -ParameterValue $SshPubKey -EnvironmentName 'SSH_PUB_KEY' -Default ''

if (-not (Test-Administrator)) {
    Stop-WithError 'Run this script from an elevated PowerShell session (Run as Administrator).'
}

Write-Info "Workstation account: $Username"
Write-Info "SSH account: $SshUser"

# ---------------------------------------------------------------------------
# 1. SSH configuration
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '=== 1/4 SSH configuration ===' -ForegroundColor White

$sshDir = Join-Path $env:ProgramData 'ssh'
$sshdConfig = Join-Path $sshDir 'sshd_config'
$sshdConfigOriginal = "$sshdConfig.reak.orig"

if (Test-Path -LiteralPath $sshdConfig) {
    if (Test-Path -LiteralPath $sshdConfigOriginal) {
        Copy-Item -LiteralPath $sshdConfigOriginal -Destination $sshdConfig -Force
        Remove-Item -LiteralPath $sshdConfigOriginal -Force
        Write-Ok "Restored the original sshd_config from $sshdConfigOriginal."
    } else {
        $content = Get-Content -LiteralPath $sshdConfig -Raw
        $pattern = "(?ms)^$([regex]::Escape($script:SshdConfigMarkerBegin)).*?$([regex]::Escape($script:SshdConfigMarkerEnd))\r?\n?"
        $stripped = [regex]::Replace($content, $pattern, '')
        if ($stripped -ne $content) {
            Set-Content -LiteralPath $sshdConfig -Value $stripped -Encoding ASCII -NoNewline
            Write-Ok 'Removed the REAK hardening block from sshd_config.'
        } else {
            Write-Info 'No REAK hardening block was found in sshd_config.'
        }
    }
} else {
    Write-WarnMessage "No sshd_config was found at $sshdConfig."
}

if (-not [string]::IsNullOrWhiteSpace($SshPubKey)) {
    $key = $SshPubKey.Trim()
    Remove-PublicKeyFromFile -Path (Join-Path $sshDir 'administrators_authorized_keys') -Key $key
    $sshUserProfile = Get-UserProfilePath -Name $SshUser
    Remove-PublicKeyFromFile -Path (Join-Path $sshUserProfile '.ssh\authorized_keys') -Key $key
} else {
    Write-WarnMessage 'SSH_PUB_KEY was not set, so the authorized key files were left unchanged.'
}

if (Get-Service -Name 'sshd' -ErrorAction SilentlyContinue) {
    Restart-Service -Name 'sshd' -ErrorAction SilentlyContinue
    Write-Ok 'Restarted the sshd service.'
}

# ---------------------------------------------------------------------------
# 2. Fleet agent
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '=== 2/4 Fleet agent ===' -ForegroundColor White

$fleetServices = @(Get-Service -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like '*osquery*' -or $_.DisplayName -like '*osquery*' -or
        $_.Name -like '*orbit*' -or $_.DisplayName -like '*orbit*'
    })
foreach ($service in $fleetServices) {
    Write-Info "Stopping $($service.Name) ..."
    Stop-Service -Name $service.Name -Force -ErrorAction SilentlyContinue
}

Uninstall-MsiProduct -DisplayNamePattern 'Fleet osquery*'

foreach ($leftover in @((Join-Path $env:ProgramFiles 'Orbit'), (Join-Path $env:ProgramData 'Orbit'))) {
    if (Test-Path -LiteralPath $leftover) {
        Remove-Item -LiteralPath $leftover -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $leftover) {
            Write-WarnMessage "Could not remove the leftover directory $leftover."
        } else {
            Write-Ok "Removed the leftover directory $leftover."
        }
    }
}

# ---------------------------------------------------------------------------
# 3. Applications (optional)
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '=== 3/4 Applications ===' -ForegroundColor White

if ($RemoveApps) {
    Uninstall-MsiProduct -DisplayNamePattern 'Google Chrome*'
    Uninstall-MsiProduct -DisplayNamePattern 'Microsoft Visual Studio Code*'
    Uninstall-MsiProduct -DisplayNamePattern 'Bruno*'
    Uninstall-MsiProduct -DisplayNamePattern 'Mozilla Firefox*'
    Uninstall-MsiProduct -DisplayNamePattern 'Docker Desktop*'
    Uninstall-MsiProduct -DisplayNamePattern 'NVM for Windows*'

    $goInstallDir = Join-Path $env:ProgramFiles 'Go'
    if (Test-Path -LiteralPath $goInstallDir) {
        Remove-Item -LiteralPath $goInstallDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok "Removed $goInstallDir."
    }
    $opksshDir = Join-Path $env:ProgramFiles 'opkssh'
    if (Test-Path -LiteralPath $opksshDir) {
        Remove-Item -LiteralPath $opksshDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok "Removed $opksshDir."
    }
} else {
    Write-Info 'Applications are kept by default. Re-run with -RemoveApps to remove them.'
}

# ---------------------------------------------------------------------------
# 4. Workstation account (optional)
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '=== 4/4 Workstation account ===' -ForegroundColor White

if ($RemoveUser) {
    $account = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
    if ($account) {
        $userProfile = Get-UserProfilePath -Name $Username
        Remove-LocalUser -Name $Username -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $userProfile) {
            Remove-Item -LiteralPath $userProfile -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Ok "Removed the account '$Username'."
    } else {
        Write-Info "The account '$Username' does not exist."
    }
} else {
    Write-Info "The account '$Username' is kept by default. Re-run with -RemoveUser to delete it."
}

Write-Host ''
Write-Host 'Rollback complete.' -ForegroundColor White
