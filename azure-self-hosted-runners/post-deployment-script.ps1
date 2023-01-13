param (
    # GitHub Actions Runner registration token. Note that these tokens are only valid for one hour after creation, so we always expect the user to provide one.
    # https://docs.github.com/en/actions/hosting-your-own-runners/adding-self-hosted-runners
    [Parameter(Mandatory = $true)]
    [string]$GitHubActionsRunnerToken,

    # GitHub Actions Runner repository. E.g. "https://github.com/MY_ORG" (org-level) or "https://github.com/MY_ORG/MY_REPO" (repo-level)
    # https://docs.github.com/en/actions/hosting-your-own-runners/adding-self-hosted-runners
    [Parameter(Mandatory = $true)]
    [string]$GithubActionsRunnerRegistrationUrl,

    # Actions Runner name. Needs to be unique in the org/repo
    [Parameter(Mandatory = $true)]
    [string]$GithubActionsRunnerName,

    # Stop Service immediately (useful for spinning up runners preemptively)
    [Parameter(Mandatory = $false)]
    [ValidateSet('true', 'false')]
    [string]$StopService = 'true',

    # Path to the Actions Runner. Keep this path short to prevent Long Path issues, e.g. D:\a
    [Parameter(Mandatory = $true)]
    [string]$GitHubActionsRunnerPath
)

Write-Output "Starting post-deployment script."

# =================================
# TOOL VERSIONS AND OTHER VARIABLES
# =================================
#
# This header is used for both Git for Windows and GitHub Actions Runner
[hashtable]$GithubHeaders = @{
    "Accept"               = "application/vnd.github.v3+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

# =================================
# Get download and hash information for the latest release of Git for Windows
# =================================
#
# This will return the latest release of Git for Windows download link, hash and the name of the outfile
# Everything will be saved in the object $GitHubGit
#
# url for Github API to get the latest release
[string]$GitHubUrl = "https://api.github.com/repos/git-for-windows/git/releases/latest"
#
# Name of the exe file that should be verified and downloaded
[string]$GithubExeName = "Git-.*-64-bit.exe"

try {
    [System.Object]$GithubRestData = Invoke-RestMethod -Uri $GitHubUrl -Method Get -Headers $GithubHeaders -TimeoutSec 10 | Select-Object -Property assets, body
    [System.Object]$GitHubAsset = $GithubRestData.assets | Where-Object { $_.name -match $GithubExeName }
    if ($GithubRestData.body -match "\b${[Regex]::Escape($GitHubAsset.name)}.*?\|.*?([a-zA-Z0-9]{64})" -eq $True) {
        [System.Object]$GitHubGit = [PSCustomObject]@{
            DownloadUrl = [string]$GitHubAsset.browser_download_url
            Hash        = [string]$Matches[1].ToUpper()
            OutFile     = "./git-for-windows-installer.exe"
        }
    }
    else {
        throw "Could not find hash for $GithubExeName"
        break;
    }
}
catch {
    Write-Output @"
   "Message: "$($_.Exception.Message)`n
   "Error Line: "$($_.InvocationInfo.Line)`n
   "Line Number: "$($_.InvocationInfo.ScriptLineNumber)`n
"@
    break;
}

#
# Note that the GitHub Actions Runner auto-updates itself by default, but do try to reference a relatively new version here.
$GitHubActionsRunnerVersion = "2.300.2"
$GithubActionsRunnerArch = "arm64"
$GithubActionsRunnerHash = "9409e50d9ad33d8031355ed079b8f56cf3699f35cf5d0ca51e54deed432758ef"
$GithubActionsRunnerLabels = "self-hosted,Windows,ARM64"

# ======================
# WINDOWS DEVELOPER MODE
# ======================

# Needed for symlink support
Write-Output "Enabling Windows Developer Mode..."
Start-Process -Wait "reg" 'add "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v "AllowDevelopmentWithoutDevLicense" /d "1"'
Write-Output "Enabled Windows developer mode."

# =============================
# MICROSOFT DEFENDER EXCLUSIONS
# =============================

Write-Output "Adding Microsoft Defender Exclusions..."
Add-MpPreference -ExclusionPath "C:\"
Write-Output "Finished adding Microsoft Defender Exclusions."

# ======================
# GIT FOR WINDOWS
# ======================

Write-Output "Downloading Git for Windows..."
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -UseBasicParsing -Uri $GitHubGit.DownloadUrl -OutFile $GitHubGit.OutFile
$ProgressPreference = 'Continue'

if ((Get-FileHash -Path $GitHubGit.OutFile -Algorithm SHA256).Hash.ToUpper() -ne $GitHubGit.Hash) {
    throw 'Computed checksum did not match'
}

Write-Output "Installing Git for Windows..."
@"
[Setup]
Lang=default
Dir=C:\Program Files\Git
Group=Git
NoIcons=0
SetupType=default
Components=gitlfs,windowsterminal
Tasks=
EditorOption=VIM
CustomEditorPath=
DefaultBranchOption= 
PathOption=CmdTools
SSHOption=OpenSSH
TortoiseOption=false
CURLOption=WinSSL
CRLFOption=CRLFAlways
BashTerminalOption=ConHost
GitPullBehaviorOption=FFOnly
UseCredentialManager=Core
PerformanceTweaksFSCache=Enabled
EnableSymlinks=Disabled
EnablePseudoConsoleSupport=Disabled
EnableFSMonitor=Disabled
"@ | Out-File -FilePath "./git-installer-config.inf"

Start-Process -Wait $GitHubGit.OutFile '/VERYSILENT /NORESTART /NOCANCEL /SP- /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS /LOADINF="./git-installer-config.inf"'

Write-Output "Finished installing Git for Windows."

# ======================
# GITHUB ACTIONS RUNNER
# ======================

Write-Output "Downloading GitHub Actions runner..."

mkdir $GitHubActionsRunnerPath | Out-Null
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -UseBasicParsing -Uri https://github.com/actions/runner/releases/download/v${GitHubActionsRunnerVersion}/actions-runner-win-${GithubActionsRunnerArch}-${GitHubActionsRunnerVersion}.zip -OutFile ${GitHubActionsRunnerPath}\actions-runner-win-${GithubActionsRunnerArch}-${GitHubActionsRunnerVersion}.zip
$ProgressPreference = 'Continue'
if ((Get-FileHash -Path ${GitHubActionsRunnerPath}\actions-runner-win-${GithubActionsRunnerArch}-${GitHubActionsRunnerVersion}.zip -Algorithm SHA256).Hash.ToUpper() -ne $GithubActionsRunnerHash.ToUpper()) { throw 'Computed checksum did not match' }

Write-Output "Installing GitHub Actions runner ${GitHubActionsRunnerVersion} as a Windows service with labels ${GithubActionsRunnerLabels}..."

Add-Type -AssemblyName System.IO.Compression.FileSystem ; [System.IO.Compression.ZipFile]::ExtractToDirectory("${GitHubActionsRunnerPath}\actions-runner-win-${GithubActionsRunnerArch}-${GitHubActionsRunnerVersion}.zip", $GitHubActionsRunnerPath)

Write-Output "Configuring the runner to shut down automatically after running"
Set-Content -Path "${GitHubActionsRunnerPath}\shut-down.ps1" -Value "shutdown -s -t 60 -d p:4:0 -c `"workflow job is done`""
[System.Environment]::SetEnvironmentVariable("ACTIONS_RUNNER_HOOK_JOB_COMPLETED", "${GitHubActionsRunnerPath}\shut-down.ps1", [System.EnvironmentVariableTarget]::Machine)

Write-Output "Configuring the runner"
cmd.exe /c "${GitHubActionsRunnerPath}\config.cmd" --unattended --ephemeral --name ${GithubActionsRunnerName} --runasservice --labels ${GithubActionsRunnerLabels} --url ${GithubActionsRunnerRegistrationUrl} --token ${GitHubActionsRunnerToken}

# Ensure that the service was created. If not, exit with error code.
$MatchedServices = Get-Service -Name "actions.runner.*"
if ($MatchedServices.count -eq 0) {
    Write-Error "GitHub Actions service not found (should start with actions.runner). Check the logs in ${GitHubActionsRunnerPath}\_diag for more details."
    exit 1
}

# Immediately stop the service as we want to leave the VM in a deallocated state for later use. The service will automatically be started when Windows starts.
if (${StopService} -eq 'true') {
    Stop-Service -Name "actions.runner.*" -Verbose
}

Write-Output "Finished installing GitHub Actions runner."
