#Requires -Version 5.1
<#
.SYNOPSIS
    REAK Windows workstation baseline and Fleet enrollment.

.DESCRIPTION
    Windows counterpart of workstations/ubuntu/setup.sh. Performs the baseline
    workstation setup (local account, hardened OpenSSH server, developer tools)
    and then enrolls the host in Fleet, unless enrollment is skipped.

    Must run elevated (Administrator). The script mirrors the guarantees of the
    Ubuntu bootstrap: the SSH public key is validated before SSH configuration
    is touched, the sshd configuration is verified with `sshd -t` and `sshd -T`
    before the service is restarted, and a failed verification restores the
    previous configuration.

.PARAMETER Username
    Local workstation account to create or use. Default: reak (or REAK_USERNAME).

.PARAMETER SshUser
    Local account allowed to log in over SSH. Default: administrator (or
    REAK_SSH_USER).

.PARAMETER SshPubKey
    Approved SSH public key for the SSH account. Required. Can also be supplied
    through the SSH_PUB_KEY environment variable.

.PARAMETER EnrollSecret
    Fleet enrollment secret. Can also be supplied through ENROLL_SECRET. The
    script prompts for it on an interactive terminal when it is missing.

.PARAMETER SkipFleet
    Run the baseline setup only and do not enroll the host in Fleet.

.PARAMETER FleetUrl
    Fleet server URL. Default: https://fleet.reak.in

.PARAMETER FleetPackagePath
    Use a pre-generated Fleet MSI instead of generating one locally. Generating
    an MSI on Windows needs Docker or a local WiX v3 toolset, so distributing a
    pre-built MSI is usually simpler.

.PARAMETER FleetWixDir
    Directory holding the WiX v3 binaries (candle.exe, light.exe, heat.exe) used
    to build the MSI locally instead of the Docker image.

.PARAMETER FleetDisableScripts
    Do not pass --enable-scripts to fleetctl, so Fleet cannot run scripts on the
    host.

.PARAMETER InstallDocker
    Install Docker Desktop. It needs WSL2 or Hyper-V and usually a reboot, so
    it is off by default on Windows.

.PARAMETER DockerGroupAccess
    Add the workstation account to the root-equivalent Docker group.

.PARAMETER InstallCopilot
    Install the GitHub Copilot extension in VS Code. It is off by default
    because it has code-sharing and privacy implications.

.PARAMETER InstallNvm
    Install NVM for Windows. It is off by default because the installer is a
    per-user install that needs elevated rights to create symlinks.

.EXAMPLE
    $env:SSH_PUB_KEY = (Get-Content C:\keys\reak-admin.pub -Raw)
    $env:ENROLL_SECRET = 'YOUR_FLEET_ENROLL_SECRET'
    .\setup.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'The account password is a throwaway random value that is generated here, never displayed and never stored. New-LocalUser needs a SecureString.')]
[CmdletBinding()]
param(
    [string] $Username = '',
    [string] $SshUser = '',
    [string] $SshPubKey = '',
    [string] $EnrollSecret = '',
    [switch] $SkipFleet,
    [string] $FleetUrl = '',
    [string] $FleetPackagePath = '',
    [string] $FleetWixDir = '',
    [switch] $FleetDisableScripts,
    [switch] $InstallDocker,
    [switch] $DockerGroupAccess,
    [switch] $InstallCopilot,
    [switch] $InstallNvm
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Windows PowerShell 5.1 defaults to TLS 1.0 for some callers.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Verbose 'Could not force TLS 1.2; older .NET runtimes already negotiate it by default.'
}

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$script:BrunoVersion = '2.9.1'
$script:ChromeUrl = 'https://dl.google.com/chrome/install/latest/chrome_installer.exe'
$script:GoChecksumBase = 'https://dl.google.com/go'
$script:GoDownloadBase = 'https://go.dev/dl'
$script:VSCodeUrl = 'https://update.code.visualstudio.com/latest/win32-x64/stable'
$script:FleetReleases = 'https://github.com/fleetdm/fleet/releases'
$script:OpksshUrl = 'https://github.com/openpubkey/opkssh/releases/latest/download/opkssh-windows-amd64.exe'
$script:SshdConfigMarkerBegin = '# >>> REAK managed hardening'
$script:SshdConfigMarkerEnd = '# <<< REAK managed hardening'
$script:SystemSid = 'S-1-5-18'
$script:AdministratorsSid = 'S-1-5-32-544'
$script:DockerUsersSid = 'S-1-5-93-2-1'
$script:AbortReason = ''

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

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

function Write-Step {
    param([string] $Message)
    Write-Host ''
    Write-Host "=== $Message ===" -ForegroundColor White
}

function Stop-WithError {
    param([string] $Message)
    $script:AbortReason = $Message
    Write-Fail $Message
    exit 1
}

# ---------------------------------------------------------------------------
# Setting resolution: explicit parameter, then environment variable, then default
# ---------------------------------------------------------------------------

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

function Get-FlagSetting {
    param(
        [bool] $ParameterValue,
        [bool] $ParameterProvided,
        [string] $EnvironmentName,
        [bool] $Default
    )
    if ($ParameterProvided) { return $ParameterValue }
    $raw = [Environment]::GetEnvironmentVariable($EnvironmentName)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    switch -Regex ($raw.Trim().ToLowerInvariant()) {
        '^(1|true|yes|on|enabled?)$' { return $true }
        '^(0|false|no|off|disabled?)$' { return $false }
        default { Stop-WithError "Invalid value for ${EnvironmentName}: '$raw'. Use 1 or 0." }
    }
}

# ---------------------------------------------------------------------------
# Filesystem and process helpers
# ---------------------------------------------------------------------------

function Remove-TemporaryWorkspace {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

function New-TemporaryWorkspace {
    param([string] $Prefix = 'reak-setup')
    $path = Join-Path ([IO.Path]::GetTempPath()) ("{0}-{1}" -f $Prefix, ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    # Restrict the workspace to the current user and SYSTEM.
    $currentSid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
    Invoke-Native -FilePath 'icacls.exe' -ArgumentList @(
        $path,
        '/inheritance:r',
        '/grant',
        "*${currentSid}:(OI)(CI)F",
        '/grant',
        "*$($script:SystemSid):(OI)(CI)F"
    ) | Out-Null
    return $path
}

function Invoke-Download {
    param(
        [Parameter(Mandatory = $true)][string] $Uri,
        [Parameter(Mandatory = $true)][string] $OutFile
    )
    $previous = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -MaximumRedirection 10
    } finally {
        $ProgressPreference = $previous
    }
    if (-not (Test-Path -LiteralPath $OutFile)) {
        throw "Download failed: $Uri"
    }
    return $OutFile
}

function Invoke-Native {
    <#
        Runs a native executable and captures stdout and stderr without the
        native stderr stream turning into a terminating error.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [string[]] $ArgumentList = @()
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $FilePath @ArgumentList 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    return [PSCustomObject]@{ Output = $output; ExitCode = $code }
}

function Expand-ArchiveFile {
    param(
        [Parameter(Mandatory = $true)][string] $ArchivePath,
        [Parameter(Mandatory = $true)][string] $Destination
    )
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    # tar ships with Windows 10 1803+ and is considerably faster than
    # Expand-Archive for large archives.
    $tar = Get-Command 'tar.exe' -ErrorAction SilentlyContinue
    if ($tar) {
        $result = Invoke-Native -FilePath $tar.Source -ArgumentList @('-xf', $ArchivePath, '-C', $Destination)
        if ($result.ExitCode -eq 0) { return }
        Write-WarnMessage "tar could not expand '$ArchivePath', falling back to Expand-Archive."
    }
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $Destination -Force
}

function Invoke-SilentInstaller {
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [string[]] $ArgumentList = @(),
        [string] $Description = 'installer'
    )
    Write-Info "Running $Description ..."
    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru -WindowStyle Hidden
    return $process.ExitCode
}

function Install-MsiPackage {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [string] $LogPath = ''
    )
    $arguments = @('/i', ('"{0}"' -f $Path), '/qn', '/norestart')
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        $arguments += @('/l*v', ('"{0}"' -f $LogPath))
    }
    Write-Info "Installing MSI $(Split-Path -Leaf $Path) ..."
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    $code = $process.ExitCode
    # 0 = success, 1641 = success with reboot initiated, 3010 = success, reboot required.
    if ($code -eq 0 -or $code -eq 1641 -or $code -eq 3010) {
        if ($code -ne 0) {
            Write-WarnMessage "MSI installed but a reboot is required (msiexec exit $code)."
        }
        return $true
    }
    Write-Fail "msiexec failed with exit code $code for $Path"
    return $false
}

function Add-MachinePathEntry {
    param([string[]] $Entries)
    $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $parts = @()
    if (-not [string]::IsNullOrWhiteSpace($current)) {
        $parts = @($current -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $changed = $false
    foreach ($entry in $Entries) {
        if ($parts -notcontains $entry) {
            $parts += $entry
            $changed = $true
        }
    }
    if ($changed) {
        [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'Machine')
        Send-EnvironmentChange
    }
}

function Send-EnvironmentChange {
    # Let newly started processes pick up machine environment changes.
    try {
        if (-not ('Reak.NativeMethods' -as [type])) {
            Add-Type -Namespace 'Reak' -Name 'NativeMethods' -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@ -ErrorAction Stop
        }
        $result = [UIntPtr]::Zero
        [void][Reak.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
    } catch {
        Write-Verbose 'The environment broadcast failed; new shells still read the registry.'
    }
}

function Get-LocalGroupBySid {
    <#
        Return the plain name of a local group. The LocalAccounts cmdlets want
        the local name, not the qualified "BUILTIN\Administrators" form that
        an SID translation produces.
    #>
    param([Parameter(Mandatory = $true)][string] $Sid)
    try {
        $group = Get-LocalGroup -SID $Sid -ErrorAction Stop
        if ($group.Name) { return $group.Name }
    } catch {
        # Fall back to the SID translation below.
    }
    $identity = New-Object Security.Principal.SecurityIdentifier($Sid)
    $qualified = $identity.Translate([Security.Principal.NTAccount]).Value
    return ($qualified -split '\\')[-1]
}

function Set-RestrictedAcl {
    <#
        Restrict a path to the given principals and drop inherited access.
        Principals are given as SIDs so the script works on localized Windows.
        icacls is used because it leaves the owner untouched, which matters for
        the files OpenSSH validates.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string[]] $AllowedSids
    )
    # icacls wants "/grant" and the access control entry as separate
    # arguments. "/grant:<ace>" is rejected with "Invalid parameter". The SID
    # needs the asterisk prefix, otherwise icacls tries to resolve it as a
    # name and fails on a localized Windows.
    $arguments = @($Path, '/inheritance:r')
    foreach ($sidValue in $AllowedSids) {
        $arguments += '/grant'
        $arguments += "*${sidValue}:F"
    }
    $result = Invoke-Native -FilePath 'icacls.exe' -ArgumentList $arguments
    if ($result.ExitCode -ne 0) {
        throw "icacls failed for '$Path': $($result.Output -join ' ')"
    }
}

function Set-FileOwner {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $OwnerSid
    )
    $owner = (New-Object Security.Principal.SecurityIdentifier($OwnerSid)).Translate([Security.Principal.NTAccount]).Value
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetOwner((New-Object Security.Principal.NTAccount($owner)))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Set-PasswordExpired {
    <#
        Mark an account so Windows asks for a new password at the next logon.
        The ADSI WinNT provider does not implement PasswordExpired, so the
        account flags are read and written with NetUserGetInfo and
        NetUserSetInfo instead. UF_SCRIPT has to be set together with
        UF_PASSWORD_EXPIRED, and the existing flags are preserved.
    #>
    param([Parameter(Mandatory = $true)][string] $Name)

    if (-not ('Reak.NetUser' -as [type])) {
        Add-Type -Namespace 'Reak' -Name 'NetUser' -ErrorAction Stop -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct USER_INFO_1
{
    [MarshalAs(UnmanagedType.LPWStr)] public string Name;
    [MarshalAs(UnmanagedType.LPWStr)] public string Password;
    public uint PasswordAge;
    public uint Privilege;
    [MarshalAs(UnmanagedType.LPWStr)] public string HomeDir;
    [MarshalAs(UnmanagedType.LPWStr)] public string Comment;
    public uint Flags;
    [MarshalAs(UnmanagedType.LPWStr)] public string ScriptPath;
    public uint AuthFlags;
    [MarshalAs(UnmanagedType.LPWStr)] public string FullName;
    [MarshalAs(UnmanagedType.LPWStr)] public string UsrComment;
    [MarshalAs(UnmanagedType.LPWStr)] public string Parms;
    [MarshalAs(UnmanagedType.LPWStr)] public string Workstations;
    public uint MaxLogonHours;
    public uint LogonHours;
}

public static class NetUserApi
{
    [DllImport("netapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint NetUserGetInfo(string serverName, string userName, int level, out IntPtr info, int bufferSize, out int errorCode, out int entriesRead, out int totalEntries);

    [DllImport("netapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint NetUserSetInfo(string serverName, string userName, int level, ref USER_INFO_1 info, int bufferSize);

    [DllImport("netapi32.dll", SetLastError = true)]
    public static extern uint NetApiBufferFree(IntPtr buffer);
}
'@
    }

    $buffer = [IntPtr]::Zero
    $errorCode = 0
    $entriesRead = 0
    $totalEntries = 0
    $result = [Reak.NetUserApi]::NetUserGetInfo($null, $Name, 1, [ref]$buffer, 0, [ref]$errorCode, [ref]$entriesRead, [ref]$totalEntries)
    if ($result -ne 0) {
        throw "NetUserGetInfo failed with error $result."
    }
    try {
        $current = [Runtime.InteropServices.Marshal]::PtrToStructure($buffer, [type][Reak.NetUserApi+USER_INFO_1])
        $updated = New-Object Reak.NetUserApi+USER_INFO_1
        $updated.Name = $current.Name
        $updated.Password = $current.Password
        $updated.PasswordAge = $current.PasswordAge
        $updated.Privilege = $current.Privilege
        $updated.HomeDir = $current.HomeDir
        $updated.Comment = $current.Comment
        # UF_SCRIPT (0x1) and UF_PASSWORD_EXPIRED (0x80000000).
        $updated.Flags = $current.Flags -bor 0x00000001 -bor 0x80000000
        $updated.ScriptPath = $current.ScriptPath
        $updated.AuthFlags = $current.AuthFlags
        $updated.FullName = $current.FullName
        $updated.UsrComment = $current.UsrComment
        $updated.Parms = $current.Parms
        $updated.Workstations = $current.Workstations
        $updated.MaxLogonHours = $current.MaxLogonHours
        $updated.LogonHours = $current.LogonHours

        $setResult = [Reak.NetUserApi]::NetUserSetInfo($null, $Name, 1, [ref]$updated, -1)
        if ($setResult -ne 0) {
            throw "NetUserSetInfo failed with error $setResult."
        }
    } finally {
        if ($buffer -ne [IntPtr]::Zero) {
            [void][Reak.NetUserApi]::NetApiBufferFree($buffer)
        }
    }
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-RandomPassword {
    param([int] $Length = 32)
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower = 'abcdefghijkmnopqrstuvwxyz'
    $digit = '23456789'
    $symbol = '!@#$%^&*()-_=+[]{}'
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        function Get-RandomIndex {
            param([int] $Maximum)
            # Rejection sampling keeps the result uniform.
            $buffer = New-Object byte[] 4
            $range = [double] [uint32]::MaxValue + 1
            $limit = [long] ([math]::Floor($range / $Maximum) * $Maximum)
            do {
                $rng.GetBytes($buffer)
                $value = [long] [BitConverter]::ToUInt32($buffer, 0)
            } while ($value -ge $limit)
            return [int] ($value % $Maximum)
        }
        function Get-RandomChar {
            param([string] $Set)
            return [char] $Set[(Get-RandomIndex $Set.Length)]
        }
        $characters = @(
            (Get-RandomChar $upper),
            (Get-RandomChar $lower),
            (Get-RandomChar $digit),
            (Get-RandomChar $symbol)
        )
        $all = $upper + $lower + $digit + $symbol
        while ($characters.Count -lt $Length) {
            $characters += (Get-RandomChar $all)
        }
        # Shuffle so the guaranteed characters are not always in front.
        for ($i = $characters.Count - 1; $i -gt 0; $i--) {
            $j = Get-RandomIndex ($i + 1)
            $tmp = $characters[$i]
            $characters[$i] = $characters[$j]
            $characters[$j] = $tmp
        }
        return (-join $characters)
    } finally {
        $rng.Dispose()
    }
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

function Get-FleetService {
    $services = @(Get-Service -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like '*osquery*' -or $_.DisplayName -like '*osquery*' -or
            $_.Name -like '*orbit*' -or $_.DisplayName -like '*orbit*'
        })
    return $services
}

# ---------------------------------------------------------------------------
# Resolve settings
# ---------------------------------------------------------------------------

$Username = Get-Setting -ParameterValue $Username -EnvironmentName 'REAK_USERNAME' -Default 'reak'
$SshUser = Get-Setting -ParameterValue $SshUser -EnvironmentName 'REAK_SSH_USER' -Default 'administrator'
$SshPubKey = Get-Setting -ParameterValue $SshPubKey -EnvironmentName 'SSH_PUB_KEY' -Default ''
$EnrollSecret = Get-Setting -ParameterValue $EnrollSecret -EnvironmentName 'ENROLL_SECRET' -Default ''
$FleetUrl = Get-Setting -ParameterValue $FleetUrl -EnvironmentName 'FLEET_URL' -Default 'https://fleet.reak.in'
$FleetPackagePath = Get-Setting -ParameterValue $FleetPackagePath -EnvironmentName 'FLEET_PACKAGE_PATH' -Default ''
$FleetWixDir = Get-Setting -ParameterValue $FleetWixDir -EnvironmentName 'FLEET_WIX_DIR' -Default ''

$skipFleet = Get-FlagSetting -ParameterValue $SkipFleet.IsPresent -ParameterProvided $PSBoundParameters.ContainsKey('SkipFleet') -EnvironmentName 'SKIP_FLEET' -Default $false
$installDocker = Get-FlagSetting -ParameterValue $InstallDocker.IsPresent -ParameterProvided $PSBoundParameters.ContainsKey('InstallDocker') -EnvironmentName 'INSTALL_DOCKER' -Default $false
$dockerGroupAccess = Get-FlagSetting -ParameterValue $DockerGroupAccess.IsPresent -ParameterProvided $PSBoundParameters.ContainsKey('DockerGroupAccess') -EnvironmentName 'DOCKER_GROUP_ACCESS' -Default $false
$installCopilot = Get-FlagSetting -ParameterValue $InstallCopilot.IsPresent -ParameterProvided $PSBoundParameters.ContainsKey('InstallCopilot') -EnvironmentName 'INSTALL_COPILOT' -Default $false
$installNvm = Get-FlagSetting -ParameterValue $InstallNvm.IsPresent -ParameterProvided $PSBoundParameters.ContainsKey('InstallNvm') -EnvironmentName 'INSTALL_NVM' -Default $false
$enableFleetScripts = Get-FlagSetting -ParameterValue (-not $FleetDisableScripts.IsPresent) -ParameterProvided $PSBoundParameters.ContainsKey('FleetDisableScripts') -EnvironmentName 'FLEET_ENABLE_SCRIPTS' -Default $true

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------

# The temporary workspace is removed on every exit path, including failures.
# PowerShell activates a trap for the whole scope, so it is registered here,
# after the helper functions it calls are defined.
$workspace = ''

trap {
    Remove-TemporaryWorkspace -Path $workspace
    if ([string]::IsNullOrWhiteSpace($script:AbortReason)) {
        Write-Fail "Setup failed: $($_.Exception.Message)"
    }
    exit 1
}

Write-Step '1/6 Preflight checks'

if (-not (Test-Administrator)) {
    Stop-WithError 'Run this script from an elevated PowerShell session (Run as Administrator).'
}

$osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
Write-Info "OS: $($osInfo.Caption) $($osInfo.Version)"

if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    Stop-WithError "This script supports x64 Windows only; found $($env:PROCESSOR_ARCHITECTURE)."
}

if ($Username -notmatch '^[A-Za-z][A-Za-z0-9._-]{0,20}$') {
    Stop-WithError "Invalid workstation username '$Username'."
}
if ($SshUser -notmatch '^[A-Za-z][A-Za-z0-9._-]{0,20}$') {
    Stop-WithError "Invalid SSH username '$SshUser'."
}

$sshAccount = Get-LocalUser -Name $SshUser -ErrorAction SilentlyContinue
if (-not $sshAccount) {
    Stop-WithError "Required SSH account '$SshUser' does not exist on this host."
}
if ([string]::IsNullOrWhiteSpace($SshPubKey)) {
    Stop-WithError 'Set SSH_PUB_KEY (or -SshPubKey) to the approved administrator public key.'
}

$sshPubKey = $sshPubKey.Trim()

Write-Ok "Workstation account: $Username"
Write-Ok "SSH account: $SshUser"
Write-Ok "Fleet URL: $FleetUrl"

$workspace = New-TemporaryWorkspace -Prefix 'reak-setup'
Write-Info "Workspace: $workspace"

# ---------------------------------------------------------------------------
# 2. Workstation account
# ---------------------------------------------------------------------------

Write-Step '2/6 Workstation account'

$workstationUser = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
if (-not $workstationUser) {
    Write-Info "Creating local account '$Username' with a random password that must be changed at first logon."
    $password = New-RandomPassword
    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
    New-LocalUser -Name $Username -Password $securePassword -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword:$false -Description 'REAK workstation account' | Out-Null
    # Mark the password as expired so Windows asks for a new one at first logon.
    try {
        Set-PasswordExpired -Name $Username
        Write-Ok "Account '$Username' created. The password must be changed at first logon."
    } catch {
        Write-WarnMessage "Could not force a password change for '$Username' ($($_.Exception.Message)). The random password is unknown, so the account stays locked until an administrator sets one with: net user $Username <password>"
    }
} else {
    Write-Ok "Account '$Username' already exists."
}

$administratorsGroup = Get-LocalGroupBySid -Sid $script:AdministratorsSid
$administratorMembers = @(Get-LocalGroupMember -Group $administratorsGroup -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*\$Username" })
if ($administratorMembers.Count -eq 0) {
    try {
        Add-LocalGroupMember -Group $administratorsGroup -Member $Username -ErrorAction Stop
        Write-Ok "Added '$Username' to the local Administrators group."
    } catch {
        Write-WarnMessage "Could not add '$Username' to the local Administrators group ($($_.Exception.Message))."
    }
}

# ---------------------------------------------------------------------------
# 3. OpenSSH server
# ---------------------------------------------------------------------------

Write-Step '3/6 OpenSSH server'

$sshCapability = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' -ErrorAction SilentlyContinue
if (-not $sshCapability) {
    Stop-WithError 'The OpenSSH Server optional feature is not available on this Windows build.'
}
if ($sshCapability.State -ne 'Installed') {
    Write-Info 'Installing the OpenSSH Server capability. This can take several minutes ...'
    Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
}

$clientCapability = Get-WindowsCapability -Online -Name 'OpenSSH.Client~~~~0.0.1.0' -ErrorAction SilentlyContinue
if ($clientCapability -and $clientCapability.State -ne 'Installed') {
    Add-WindowsCapability -Online -Name 'OpenSSH.Client~~~~0.0.1.0' | Out-Null
}

$openSshDir = Join-Path $env:WINDIR 'System32\OpenSSH'
$sshdExe = Join-Path $openSshDir 'sshd.exe'
$sshKeygenExe = Join-Path $openSshDir 'ssh-keygen.exe'
if (-not (Test-Path -LiteralPath $sshdExe)) {
    Stop-WithError "OpenSSH server binary not found at $sshdExe."
}
if (-not (Test-Path -LiteralPath $sshKeygenExe)) {
    Stop-WithError "OpenSSH client binary not found at $sshKeygenExe."
}

# Validate the public key before touching any SSH configuration.
$keyProbe = Join-Path $workspace 'authorized_key_probe'
Set-Content -LiteralPath $keyProbe -Value $sshPubKey -Encoding ASCII
$keyCheck = Invoke-Native -FilePath $sshKeygenExe -ArgumentList @('-l', '-f', $keyProbe)
if ($keyCheck.ExitCode -ne 0) {
    Stop-WithError 'SSH_PUB_KEY is not a valid SSH public key.'
}
Remove-Item -LiteralPath $keyProbe -Force
Write-Ok 'SSH public key validated.'

$sshDir = Join-Path $env:ProgramData 'ssh'
$sshdConfig = Join-Path $sshDir 'sshd_config'
$adminKeysFile = Join-Path $sshDir 'administrators_authorized_keys'
New-Item -ItemType Directory -Path $sshDir -Force | Out-Null

# Windows OpenSSH ignores per-user authorized_keys for members of the
# Administrators group and reads %ProgramData%\ssh\administrators_authorized_keys
# instead, so the key is written there as well.
$sshUserSid = (New-Object Security.Principal.NTAccount($SshUser)).Translate([Security.Principal.SecurityIdentifier]).Value

$existingKeys = @()
if (Test-Path -LiteralPath $adminKeysFile) {
    $existingKeys = @(Get-Content -LiteralPath $adminKeysFile -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() })
}
if ($existingKeys -notcontains $sshPubKey) {
    $existingKeys += $sshPubKey
}
Set-Content -LiteralPath $adminKeysFile -Value $existingKeys -Encoding ASCII
Set-RestrictedAcl -Path $adminKeysFile -AllowedSids @($script:SystemSid, $script:AdministratorsSid)
try {
    Set-FileOwner -Path $adminKeysFile -OwnerSid $script:AdministratorsSid
} catch {
    # The access control list is what OpenSSH checks, the owner is a nicety.
    Write-WarnMessage "Could not set the owner of $adminKeysFile ($($_.Exception.Message))."
}
Write-Ok "Authorized key written to $adminKeysFile"

$sshUserProfile = Get-UserProfilePath -Name $SshUser
if (Test-Path -LiteralPath $sshUserProfile) {
    $userSshDir = Join-Path $sshUserProfile '.ssh'
    $userKeysFile = Join-Path $userSshDir 'authorized_keys'
    New-Item -ItemType Directory -Path $userSshDir -Force | Out-Null
    $userKeys = @()
    if (Test-Path -LiteralPath $userKeysFile) {
        $userKeys = @(Get-Content -LiteralPath $userKeysFile -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() })
    }
    if ($userKeys -notcontains $sshPubKey) {
        $userKeys += $sshPubKey
    }
    Set-Content -LiteralPath $userKeysFile -Value $userKeys -Encoding ASCII
    Set-RestrictedAcl -Path $userSshDir -AllowedSids @($script:SystemSid, $script:AdministratorsSid, $sshUserSid)
    Set-RestrictedAcl -Path $userKeysFile -AllowedSids @($script:SystemSid, $script:AdministratorsSid, $sshUserSid)
    try {
        Set-FileOwner -Path $userKeysFile -OwnerSid $sshUserSid
    } catch {
        Write-WarnMessage "Could not set the owner of $userKeysFile ($($_.Exception.Message))."
    }
    Write-Ok "Authorized key written to $userKeysFile"
} else {
    Write-WarnMessage "Profile directory '$sshUserProfile' does not exist yet; only the ProgramData key file was written."
}

# Host keys must exist before sshd can start.
Invoke-Native -FilePath $sshKeygenExe -ArgumentList @('-A') | Out-Null

# Clean up corrupted logs directory if it exists (known Windows OpenSSH bug where
# inherited ACEs cause sshd to crash on startup with Error 1067).
$sshLogsDir = Join-Path $sshDir 'logs'
if (Test-Path -LiteralPath $sshLogsDir) {
    Remove-Item -LiteralPath $sshLogsDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Ensure ProgramData\ssh folder and its host keys / config files have strict ACLs.
# OpenSSH strictly rejects starting if unprivileged users have write access.
Set-RestrictedAcl -Path $sshDir -AllowedSids @($script:SystemSid, $script:AdministratorsSid)
Get-ChildItem -LiteralPath $sshDir -File -ErrorAction SilentlyContinue | ForEach-Object {
    Set-RestrictedAcl -Path $_.FullName -AllowedSids @($script:SystemSid, $script:AdministratorsSid)
}

$sshdConfigOriginal = "$sshdConfig.reak.orig"
if (-not (Test-Path -LiteralPath $sshdConfigOriginal) -and (Test-Path -LiteralPath $sshdConfig)) {
    Copy-Item -LiteralPath $sshdConfig -Destination $sshdConfigOriginal -Force
}

$existingConfig = ''
if (Test-Path -LiteralPath $sshdConfig) {
    $existingConfig = Get-Content -LiteralPath $sshdConfig -Raw
}

# Drop a previous REAK block so the script is idempotent.
$blockPattern = "(?ms)^$([regex]::Escape($script:SshdConfigMarkerBegin)).*?$([regex]::Escape($script:SshdConfigMarkerEnd))\r?\n?"
$existingConfig = [regex]::Replace($existingConfig, $blockPattern, '')

# KbdInteractiveAuthentication only exists in OpenSSH 8.7+. Windows 10 ships
# OpenSSH 8.6 and rejects the newer keyword, so the keyword is probed instead
# of being guessed from the file version.
$kbdCandidates = @('KbdInteractiveAuthentication no', 'ChallengeResponseAuthentication no')
$kbdSetting = ''
$sshdTest = $null

function Write-SshdConfig {
    param([string] $KeyboardInteractiveSetting)
    $block = @"
$($script:SshdConfigMarkerBegin)
# Managed by workstations/windows/setup.ps1 - edit that script, not this file.
PasswordAuthentication no
$KeyboardInteractiveSetting
PermitRootLogin no
PubkeyAuthentication yes
AllowUsers $SshUser
$($script:SshdConfigMarkerEnd)
"@
    # OpenSSH uses the first value it reads for a keyword, so the hardening
    # block has to be at the very top of the file, before any Match block.
    Set-Content -LiteralPath $sshdConfig -Value ($block + "`r`n" + $existingConfig) -Encoding ASCII -NoNewline
}

function Restore-SshdConfig {
    if (Test-Path -LiteralPath $sshdConfigOriginal) {
        Copy-Item -LiteralPath $sshdConfigOriginal -Destination $sshdConfig -Force
    } else {
        Remove-Item -LiteralPath $sshdConfig -Force -ErrorAction SilentlyContinue
    }
}

foreach ($candidate in $kbdCandidates) {
    Write-SshdConfig -KeyboardInteractiveSetting $candidate
    $sshdTest = Invoke-Native -FilePath $sshdExe -ArgumentList @('-t')
    if ($sshdTest.ExitCode -eq 0) {
        $kbdSetting = $candidate
        break
    }
    # Only try the other keyword when this one is what sshd rejected.
    if (($sshdTest.Output -join ' ') -notmatch '(?i)kbdinteractiveauthentication') {
        break
    }
    Write-Info "sshd does not support '$candidate', trying the alternative keyword."
}

if (-not $kbdSetting) {
    Restore-SshdConfig
    Stop-WithError "sshd -t failed, the previous configuration was restored: $($sshdTest.Output -join ' ')"
}

$sshdEffective = Invoke-Native -FilePath $sshdExe -ArgumentList @('-T')
if ($sshdEffective.ExitCode -ne 0) {
    Restore-SshdConfig
    Stop-WithError "sshd -T failed, the previous configuration was restored: $($sshdEffective.Output -join ' ')"
}

$effectiveText = ($sshdEffective.Output -join "`n")
$checksPassed = $true
if ($effectiveText -notmatch '(?im)^passwordauthentication no$') { $checksPassed = $false; Write-WarnMessage 'PasswordAuthentication is not disabled.' }
if ($effectiveText -notmatch '(?im)^(kbdinteractiveauthentication|challengeresponseauthentication) no$') { $checksPassed = $false; Write-WarnMessage 'Keyboard-interactive authentication is not disabled.' }
if ($effectiveText -notmatch '(?im)^permitrootlogin no$') { $checksPassed = $false; Write-WarnMessage 'PermitRootLogin is not disabled.' }
if ($effectiveText -notmatch "(?im)^allowusers\s+$([regex]::Escape($SshUser))\s*$") { $checksPassed = $false; Write-WarnMessage "AllowUsers does not restrict logins to $SshUser." }
if (-not $checksPassed) {
    Restore-SshdConfig
    Stop-WithError 'The effective SSH configuration did not pass the hardening checks, so the previous configuration was restored.'
}
Write-Ok 'SSH configuration verified with sshd -t and sshd -T.'

if (-not (Get-Service -Name 'sshd' -ErrorAction SilentlyContinue)) {
    Stop-WithError 'The sshd service was not created by the OpenSSH Server capability.'
}
Set-Service -Name 'sshd' -StartupType Automatic -ErrorAction SilentlyContinue

# Restart or start the sshd service with retries and diagnostic reporting.
$serviceStarted = $false
$maxServiceAttempts = 3
for ($attempt = 1; $attempt -le $maxServiceAttempts; $attempt++) {
    try {
        Restart-Service -Name 'sshd' -Force -ErrorAction Stop
        $serviceStarted = $true
        break
    } catch {
        Write-Info "Restart-Service attempt $attempt failed ($($_.Exception.Message)). Retrying with Start-Service..."
        Start-Sleep -Seconds 2
        try {
            Start-Service -Name 'sshd' -ErrorAction Stop
            $serviceStarted = $true
            break
        } catch {
            if ($attempt -lt $maxServiceAttempts) {
                # Attempt to repair file permissions on ProgramData\ssh before next try
                Set-RestrictedAcl -Path $sshDir -AllowedSids @($script:SystemSid, $script:AdministratorsSid)
                Get-ChildItem -LiteralPath $sshDir -File -ErrorAction SilentlyContinue | ForEach-Object {
                    Set-RestrictedAcl -Path $_.FullName -AllowedSids @($script:SystemSid, $script:AdministratorsSid)
                }
                Start-Sleep -Seconds 3
            }
        }
    }
}

if (-not $serviceStarted) {
    # Run sshd in debug mode to extract the exact reason why Windows refused to start it.
    $diag = Invoke-Native -FilePath $sshdExe -ArgumentList @('-d')
    $diagOutput = ($diag.Output -join ' ')
    Stop-WithError "Failed to start OpenSSH SSH Server (sshd). Diagnostic output: $diagOutput"
}
Write-Ok 'OpenSSH server started and set to start automatically.'

try {
    if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    }
    Write-Ok 'Inbound firewall rule for TCP/22 is present.'
} catch {
    Write-WarnMessage "Could not verify the Windows Firewall rule for TCP/22 ($($_.Exception.Message))."
}

# ---------------------------------------------------------------------------
# 4. Desktop applications
# ---------------------------------------------------------------------------

Write-Step '4/6 Desktop applications'

$chromePath = Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'
if (-not (Test-Path -LiteralPath $chromePath)) {
    $chromeInstaller = Join-Path $workspace 'chrome_installer.exe'
    Write-Info 'Installing Chrome.'
    Invoke-Download -Uri $script:ChromeUrl -OutFile $chromeInstaller | Out-Null
    Invoke-SilentInstaller -FilePath $chromeInstaller -ArgumentList @('/silent', '/install', '/system-level') -Description 'Chrome' | Out-Null
    if (-not (Test-Path -LiteralPath $chromePath)) {
        Write-WarnMessage 'Chrome was not found in Program Files after installation. Check the per-user install location.'
    } else {
        Write-Ok 'Chrome installed.'
    }
} else {
    Write-Ok 'Chrome is already installed.'
}

$vsCodePath = Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe'
if (-not (Test-Path -LiteralPath $vsCodePath)) {
    $vsCodeInstaller = Join-Path $workspace 'vscode-setup.exe'
    Write-Info 'Installing VS Code.'
    Invoke-Download -Uri $script:VSCodeUrl -OutFile $vsCodeInstaller | Out-Null
    Invoke-SilentInstaller -FilePath $vsCodeInstaller -ArgumentList @('/silent', '/norestart') -Description 'VS Code' | Out-Null
    if (-not (Test-Path -LiteralPath $vsCodePath)) {
        Write-WarnMessage 'VS Code was not found in Program Files after installation.'
    } else {
        Write-Ok 'VS Code installed.'
    }
} else {
    Write-Ok 'VS Code is already installed.'
}

$brunoMsi = Join-Path $workspace 'bruno.msi'
$brunoVersion = $script:BrunoVersion
Write-Info "Installing Bruno $brunoVersion."
Invoke-Download -Uri "https://github.com/usebruno/bruno/releases/download/v${brunoVersion}/bruno_${brunoVersion}_x64_win.msi" -OutFile $brunoMsi | Out-Null
if (Install-MsiPackage -Path $brunoMsi -LogPath (Join-Path $workspace 'bruno-install.log')) {
    Write-Ok 'Bruno installed.'
}

# VS Code telemetry is disabled for the workstation account.
$workstationProfile = Get-UserProfilePath -Name $Username
$vsCodeSettingsDir = Join-Path $workstationProfile 'AppData\Roaming\Code\User'
New-Item -ItemType Directory -Path $vsCodeSettingsDir -Force | Out-Null
$vsCodeSettingsFile = Join-Path $vsCodeSettingsDir 'settings.json'
$settings = @{}
if (Test-Path -LiteralPath $vsCodeSettingsFile) {
    try {
        $existing = Get-Content -LiteralPath $vsCodeSettingsFile -Raw | ConvertFrom-Json
        foreach ($property in $existing.PSObject.Properties) {
            $settings[$property.Name] = $property.Value
        }
    } catch {
        Write-WarnMessage 'The existing VS Code settings.json could not be parsed and will be replaced.'
    }
}
$settings['telemetry.telemetryLevel'] = 'off'
$settings | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $vsCodeSettingsFile -Encoding UTF8
Write-Ok "VS Code telemetry disabled in $vsCodeSettingsFile"

if ($installCopilot) {
    Write-Info 'Installing the GitHub Copilot extension for VS Code.'
    $codeExe = Get-Command 'code' -ErrorAction SilentlyContinue
    if ($codeExe) {
        & $codeExe.Source --install-extension 'GitHub.copilot' --force *> $null
        Write-Ok 'GitHub Copilot extension installed.'
    } else {
        Write-WarnMessage 'The "code" command is not on PATH yet. Install the extension from the VS Code Extensions view.'
    }
} else {
    Write-Info 'GitHub Copilot is not installed by default. Re-run with INSTALL_COPILOT=1 to install it.'
}

$firefoxDir = Join-Path $env:ProgramFiles 'Mozilla Firefox'
if (-not (Test-Path -LiteralPath $firefoxDir)) {
    Write-Info 'Installing Firefox.'
    try {
        $versions = Invoke-RestMethod -Uri 'https://product-details.mozilla.org/1.0/firefox_versions.json' -UseBasicParsing
        $firefoxVersion = $versions.LATEST_FIREFOX_VERSION
        if (-not $firefoxVersion) { throw 'Mozilla did not report a latest Firefox version.' }
        $firefoxMsi = Join-Path $workspace 'firefox.msi'
        $firefoxUrl = "https://ftp.mozilla.org/pub/firefox/releases/$firefoxVersion/win64/en-US/Firefox Setup $firefoxVersion.msi"
        Invoke-Download -Uri $firefoxUrl -OutFile $firefoxMsi | Out-Null
        if (Install-MsiPackage -Path $firefoxMsi -LogPath (Join-Path $workspace 'firefox-install.log')) {
            Write-Ok "Firefox $firefoxVersion installed."
        }
    } catch {
        Write-WarnMessage "Firefox could not be installed automatically ($($_.Exception.Message))."
    }
} else {
    Write-Ok 'Firefox is already installed.'
}

# Firefox enterprise policy: force-install uBlock Origin.
$firefoxPolicyDir = Join-Path $firefoxDir 'distribution'
New-Item -ItemType Directory -Path $firefoxPolicyDir -Force | Out-Null
$firefoxPolicyFile = Join-Path $firefoxPolicyDir 'policies.json'
$firefoxPolicy = @{
    policies = @{
        ExtensionSettings = @{
            'uBlock0@raymondhill.net' = @{
                installation_mode = 'force_installed'
                install_url       = 'https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi'
            }
        }
    }
} | ConvertTo-Json -Depth 10
Set-Content -LiteralPath $firefoxPolicyFile -Value $firefoxPolicy -Encoding UTF8
Write-Ok "Firefox uBlock Origin policy written to $firefoxPolicyFile"

# ---------------------------------------------------------------------------
# 5. Developer tooling
# ---------------------------------------------------------------------------

Write-Step '5/6 Developer tooling'

$goInstallDir = Join-Path $env:ProgramFiles 'Go'
if (-not (Test-Path -LiteralPath (Join-Path $goInstallDir 'bin\go.exe'))) {
    Write-Info 'Installing the latest Go release.'
    $goVersion = (Invoke-WebRequest -Uri 'https://go.dev/VERSION?m=text' -UseBasicParsing).Content -split "`n" | Select-Object -First 1
    $goVersion = $goVersion.Trim()
    if ($goVersion -notmatch '^go[0-9]+\.[0-9]+(\.[0-9]+)?$') {
        Stop-WithError 'Could not determine a valid Go release.'
    }
    $goArchive = Join-Path $workspace "$goVersion.windows-amd64.zip"
    Invoke-Download -Uri "$script:GoDownloadBase/$goVersion.windows-amd64.zip" -OutFile $goArchive | Out-Null
    # go.dev serves an HTML page for the .sha256 URL, so the bare hash is
    # fetched from dl.google.com and compared explicitly.
    $goChecksumFile = Join-Path $workspace "$goVersion.windows-amd64.zip.sha256"
    Invoke-Download -Uri "$script:GoChecksumBase/$goVersion.windows-amd64.zip.sha256" -OutFile $goChecksumFile | Out-Null
    $expectedSum = ((Get-Content -LiteralPath $goChecksumFile -Raw) -replace '\s', '')
    if ($expectedSum -notmatch '^[0-9a-f]{64}$') {
        Stop-WithError 'Invalid Go checksum file.'
    }
    $actualSum = (Get-FileHash -LiteralPath $goArchive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSum -ne $expectedSum) {
        Stop-WithError 'Go checksum mismatch.'
    }
    Remove-Item -LiteralPath $goInstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Expand-ArchiveFile -ArchivePath $goArchive -Destination $env:ProgramFiles
    Write-Ok "Go $goVersion installed in $goInstallDir."
} else {
    Write-Ok 'Go is already installed.'
}

[Environment]::SetEnvironmentVariable('GOROOT', $goInstallDir, 'Machine')
Add-MachinePathEntry -Entries @((Join-Path $goInstallDir 'bin'))

if ($installNvm) {
    Write-Info 'Installing NVM for Windows.'
    try {
        $nvmRelease = Invoke-RestMethod -Uri 'https://api.github.com/repos/coreybutler/nvm-windows/releases/latest' -UseBasicParsing -Headers @{ 'User-Agent' = 'reak-setup' }
        $nvmAsset = $nvmRelease.assets | Where-Object { $_.name -match '^nvm-[0-9.]+-x64-setup\.exe$' } | Select-Object -First 1
        if (-not $nvmAsset) {
            throw 'No x64 setup asset was found in the latest nvm-windows release.'
        }
        $nvmInstaller = Join-Path $workspace 'nvm-setup.exe'
        Invoke-Download -Uri $nvmAsset.browser_download_url -OutFile $nvmInstaller | Out-Null
        Invoke-SilentInstaller -FilePath $nvmInstaller -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -Description 'NVM for Windows' | Out-Null

        # The installer is a per-user install. Locate it and move it to a
        # machine-wide location so every account on the host can use it.
        $nvmCandidates = @(
            (Join-Path $env:ProgramData 'nvm\nvm.exe'),
            (Join-Path $env:APPDATA 'nvm\nvm.exe'),
            (Join-Path $env:LOCALAPPDATA 'nvm\nvm.exe')
        )
        $nvmExe = $nvmCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $nvmExe) {
            throw 'nvm.exe was not found after the installation.'
        }
        $nvmHome = Split-Path -Parent $nvmExe
        $machineNvmHome = Join-Path $env:ProgramData 'nvm'
        if (-not (Test-Path -LiteralPath (Join-Path $machineNvmHome 'nvm.exe'))) {
            New-Item -ItemType Directory -Path $machineNvmHome -Force | Out-Null
            Copy-Item -Path (Join-Path $nvmHome '*') -Destination $machineNvmHome -Recurse -Force
            $nvmHome = $machineNvmHome
        }
        $nvmSymlink = Join-Path $env:ProgramFiles 'nodejs'
        [Environment]::SetEnvironmentVariable('NVM_HOME', $nvmHome, 'Machine')
        [Environment]::SetEnvironmentVariable('NVM_SYMLINK', $nvmSymlink, 'Machine')
        Add-MachinePathEntry -Entries @($nvmHome, $nvmSymlink)
        Write-Ok "NVM for Windows installed in $nvmHome. Run 'nvm install lts' in an elevated shell to add a Node.js version."
    } catch {
        Write-WarnMessage "NVM for Windows could not be installed automatically ($($_.Exception.Message))."
    }
} else {
    Write-Info 'NVM for Windows is not installed by default. Re-run with INSTALL_NVM=1 to install it.'
}

$opksshDir = Join-Path $env:ProgramFiles 'opkssh'
if (-not (Test-Path -LiteralPath (Join-Path $opksshDir 'opkssh.exe'))) {
    Write-Info 'Installing opkssh.'
    New-Item -ItemType Directory -Path $opksshDir -Force | Out-Null
    $opksshExe = Join-Path $opksshDir 'opkssh.exe'
    Invoke-Download -Uri $script:OpksshUrl -OutFile $opksshExe | Out-Null
    Write-Ok 'opkssh installed.'
}
Add-MachinePathEntry -Entries @($opksshDir)

if ($installDocker) {
    Write-Info 'Installing Docker Desktop. This needs WSL2 or Hyper-V and usually a reboot.'
    try {
        $dockerInstaller = Join-Path $workspace 'docker-installer.exe'
        Invoke-Download -Uri 'https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe' -OutFile $dockerInstaller | Out-Null
        Invoke-SilentInstaller -FilePath $dockerInstaller -ArgumentList @('install', '--quiet', '--accept-license', '--backend=wsl-2') -Description 'Docker Desktop' | Out-Null
        Write-Ok 'Docker Desktop installed. A reboot is required before the engine can start.'
    } catch {
        Write-WarnMessage "Docker Desktop could not be installed automatically ($($_.Exception.Message))."
    }
    if ($dockerGroupAccess) {
        try {
            $dockerUsers = Get-LocalGroupBySid -Sid $script:DockerUsersSid
            Add-LocalGroupMember -Group $dockerUsers -Member $Username -ErrorAction Stop
            Write-Ok "Added '$Username' to the $dockerUsers group. This is root-equivalent access."
        } catch {
            Write-WarnMessage "Could not add '$Username' to the Docker group ($($_.Exception.Message))."
        }
    } else {
        Write-Info "Leaving '$Username' out of the root-equivalent Docker group."
    }
} else {
    Write-Info 'Docker Desktop is not installed by default. Re-run with INSTALL_DOCKER=1 to install it.'
    if ($dockerGroupAccess) {
        Write-WarnMessage 'DOCKER_GROUP_ACCESS was requested but Docker Desktop is not installed.'
    }
}

# ---------------------------------------------------------------------------
# 6. Fleet enrollment
# ---------------------------------------------------------------------------

Write-Step '6/6 Fleet enrollment'

if ($skipFleet) {
    Write-Info 'Skipping Fleet enrollment (SKIP_FLEET=1).'
    Write-Ok 'Baseline setup complete.'
    Remove-TemporaryWorkspace -Path $workspace
    exit 0
}

$fleetServices = Get-FleetService
$runningFleetService = @($fleetServices | Where-Object { $_.Status -eq 'Running' })
if ($runningFleetService.Count -gt 0) {
    Write-Ok 'A Fleet agent is already running on this host, leaving it unchanged.'
    Write-Info "Status: Get-Service -Name '$($runningFleetService[0].Name)'"
    Write-Info "Dashboard: $FleetUrl/hosts/manage"
    Remove-TemporaryWorkspace -Path $workspace
    exit 0
}

$fleetctlDir = Join-Path $env:ProgramData 'fleetctl'
$fleetctlExe = Join-Path $fleetctlDir 'fleetctl.exe'
if (-not (Test-Path -LiteralPath $fleetctlExe)) {
    Write-Info 'Installing the Fleet CLI.'
    try {
        $location = ''
        try {
            $response = Invoke-WebRequest -Uri "$script:FleetReleases/latest" -UseBasicParsing -MaximumRedirection 0 -ErrorAction Stop
            $location = [string] $response.Headers['Location']
        } catch {
            $location = ''
            if ($_.Exception.Response) {
                try { $location = [string] $_.Exception.Response.Headers['Location'] } catch { $location = '' }
            }
        }
        if ([string]::IsNullOrWhiteSpace($location)) {
            $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/fleetdm/fleet/releases/latest' -UseBasicParsing -Headers @{ 'User-Agent' = 'reak-setup' }
            $location = [string] $release.tag_name
        }
        if ($location -notmatch 'fleet-v(\d+\.\d+\.\d+)') {
            throw "Could not determine the latest fleetctl version from '$location'."
        }
        $fleetctlVersion = $Matches[1]
        $archiveName = "fleetctl_v${fleetctlVersion}_windows_amd64.zip"
        $archivePath = Join-Path $workspace $archiveName
        Invoke-Download -Uri "$script:FleetReleases/download/fleet-v$fleetctlVersion/$archiveName" -OutFile $archivePath | Out-Null

        $checksumsPath = Join-Path $workspace 'checksums.txt'
        Invoke-Download -Uri "$script:FleetReleases/download/fleet-v$fleetctlVersion/checksums.txt" -OutFile $checksumsPath | Out-Null
        $expected = ''
        foreach ($line in (Get-Content -LiteralPath $checksumsPath)) {
            if ($line -match "^\s*([0-9a-fA-F]{64})\s+\*?$([regex]::Escape($archiveName))\s*$") {
                $expected = $Matches[1].ToLowerInvariant()
            }
        }
        if ($expected) {
            $actual = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -ne $expected) {
                throw "Checksum mismatch for $archiveName."
            }
            Write-Ok "fleetctl $archiveName checksum verified."
        } else {
            Write-WarnMessage "No checksum for $archiveName was published; continuing without verification."
        }

        New-Item -ItemType Directory -Path $fleetctlDir -Force | Out-Null
        Expand-ArchiveFile -ArchivePath $archivePath -Destination $fleetctlDir
        if (-not (Test-Path -LiteralPath $fleetctlExe)) {
            # Some archives keep the binary in a versioned subdirectory.
            $found = Get-ChildItem -Path $fleetctlDir -Filter 'fleetctl.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) {
                Move-Item -LiteralPath $found.FullName -Destination $fleetctlExe -Force
            }
        }
        if (-not (Test-Path -LiteralPath $fleetctlExe)) {
            throw "fleetctl.exe was not found in $archiveName."
        }
        Add-MachinePathEntry -Entries @($fleetctlDir)
        Write-Ok "fleetctl $fleetctlVersion installed in $fleetctlDir."
    } catch {
        Stop-WithError "Could not install the Fleet CLI: $($_.Exception.Message)"
    }
} else {
    Write-Ok 'The Fleet CLI is already installed.'
}

if ([string]::IsNullOrWhiteSpace($EnrollSecret)) {
    if ([Environment]::UserInteractive) {
        $secure = Read-Host -Prompt 'Fleet enrollment secret' -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $EnrollSecret = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    } else {
        Stop-WithError 'ENROLL_SECRET is required in non-interactive mode.'
    }
}
if ([string]::IsNullOrWhiteSpace($EnrollSecret)) {
    Stop-WithError 'The enrollment secret cannot be empty.'
}

$msiPath = ''
if (-not [string]::IsNullOrWhiteSpace($FleetPackagePath)) {
    if (-not (Test-Path -LiteralPath $FleetPackagePath)) {
        Stop-WithError "The Fleet package '$FleetPackagePath' does not exist."
    }
    $msiPath = Join-Path $workspace 'fleet-osquery.msi'
    Copy-Item -LiteralPath $FleetPackagePath -Destination $msiPath -Force
    Write-Ok "Using the pre-generated Fleet package $FleetPackagePath."
} else {
    Write-Info "Generating the Fleet agent package for $FleetUrl."
    $packageArgs = @(
        'package',
        '--type=msi',
        '--fleet-desktop',
        "--fleet-url=$FleetUrl",
        "--enroll-secret=$EnrollSecret"
    )
    if ($enableFleetScripts) { $packageArgs += '--enable-scripts' }
    if (-not [string]::IsNullOrWhiteSpace($FleetWixDir)) {
        if (-not (Test-Path -LiteralPath $FleetWixDir)) {
            Stop-WithError "The WiX directory '$FleetWixDir' does not exist."
        }
        $packageArgs += "--local-wix-dir=$FleetWixDir"
    } elseif (-not (Get-Command 'docker' -ErrorAction SilentlyContinue)) {
        Stop-WithError @'
Generating an MSI needs Docker or a local WiX v3 toolset.
Install Docker Desktop, point FLEET_WIX_DIR at a directory holding candle.exe,
light.exe and heat.exe, or pass FLEET_PACKAGE_PATH with a pre-generated MSI.
'@
    }

    Push-Location $workspace
    try {
        $packageResult = Invoke-Native -FilePath $fleetctlExe -ArgumentList $packageArgs
        if ($packageResult.ExitCode -ne 0) {
            Stop-WithError "Fleet package generation failed: $($packageResult.Output -join ' ')"
        }
    } finally {
        Pop-Location
    }

    $generated = Get-ChildItem -Path $workspace -Filter 'fleet-osquery*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $generated) {
        Stop-WithError 'The generated Fleet package was not found.'
    }
    $msiPath = $generated.FullName
    Write-Ok "Fleet package generated: $msiPath"
}

# The secret was embedded in the package, so drop it from the environment.
$EnrollSecret = $null
[Environment]::SetEnvironmentVariable('ENROLL_SECRET', $null, 'Process')

if (-not (Install-MsiPackage -Path $msiPath -LogPath (Join-Path $workspace 'fleet-install.log'))) {
    Stop-WithError 'The Fleet agent package could not be installed.'
}
Write-Ok 'Fleet agent installed.'

Remove-Item -LiteralPath $msiPath -Force -ErrorAction SilentlyContinue

# Keep the installer log outside the workspace so it survives the cleanup.
$keptLog = ''
$fleetLog = Join-Path $workspace 'fleet-install.log'
if (Test-Path -LiteralPath $fleetLog) {
    $keptLog = Join-Path $env:TEMP 'reak-fleet-install.log'
    Copy-Item -LiteralPath $fleetLog -Destination $keptLog -Force -ErrorAction SilentlyContinue
}

Start-Sleep -Seconds 10
$fleetServices = Get-FleetService
$runningFleetService = @($fleetServices | Where-Object { $_.Status -eq 'Running' })
if ($runningFleetService.Count -gt 0) {
    Write-Ok "Fleet service '$($runningFleetService[0].Name)' is running."
} elseif ($keptLog) {
    Write-WarnMessage "No running Fleet service was found. The installer log was kept at $keptLog."
} else {
    Write-WarnMessage 'No running Fleet service was found. Reinstall the Fleet agent to get the installer log.'
}

$httpCode = '000'
try {
    $response = Invoke-WebRequest -Uri "$FleetUrl/api/v1/fleet/status" -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    $httpCode = [string] $response.StatusCode
} catch {
    if ($_.Exception.Response) {
        try { $httpCode = [string] [int] $_.Exception.Response.StatusCode } catch { $httpCode = '000' }
    }
}
if ($httpCode -ne '000') {
    Write-Ok "The Fleet server responded over HTTPS (HTTP $httpCode)."
} else {
    Write-WarnMessage 'The Fleet API check failed. Check DNS, TLS, the proxy and the server availability.'
}

Remove-TemporaryWorkspace -Path $workspace

Write-Step 'Setup complete'
Write-Ok "Hostname: $env:COMPUTERNAME"
Write-Ok "SSH account: $SshUser"
Write-Ok "Fleet dashboard: $FleetUrl/hosts/manage"
Write-WarnMessage 'Confirm the host appears in Fleet under Hosts. A running service alone does not prove enrollment.'
