<#
.SYNOPSIS
    Creates a MetalSoft golden image OS template from an image ISO that's already packaged and hosted.

.DESCRIPTION
    Runs steps 4 to 6 of "Registering a golden image OS template": writes the template directory from the
    built-in Linux (cloud-init) or Windows (Cloudbase-Init) example, checks it with
    "metalcloud-cli os-template list-directory" and creates it with "metalcloud-cli os-template
    create-from-directory".

    It doesn't check, package or upload the image (steps 1 to 3). Do that first, as the guide describes or
    with create-golden-template.sh (Linux, macOS or WSL), and give the hosted file's URL with -ImageUrl.

    Run it in a console without parameters and it asks for everything it needs, checks each answer, shows a
    summary and asks before changing anything. Any parameter you give is used instead of asking.

    Needs metalcloud-cli, configured for your controller ($env:METALCLOUD_ENDPOINT and
    $env:METALCLOUD_API_KEY). Works in Windows PowerShell 5.1 and PowerShell 7.

.PARAMETER OS
    linux or windows: which built-in example to use (cloud-init or Cloudbase-Init).

.PARAMETER ImageUrl
    URL of the image ISO (or .img) that's already packaged and hosted. The file name must end in .iso or .img.

.PARAMETER Label
    Template label, unique on the controller: lowercase letters, digits and hyphens.

.PARAMETER Name
    Template name. Default: the label.

.PARAMETER Description
    Template description.

.PARAMETER OSName
    os.name. Default: linux-golden-image or windows-golden-image. Never exactly windows, rhel or redhat.

.PARAMETER OSVersion
    os.version. Default: 1.0.

.PARAMETER BootIsoUrl
    The boot ISO. Default: https://repo.metalsoft.io/.iso/boot-golden-image.iso

.PARAMETER UserDataFile
    Your own user-data instead of the built-in example's. Like the examples, it's rendered as a template for
    each server, with the variables described in the guide.

.PARAMETER MetaDataFile
    Your own meta-data instead of the built-in example's.

.PARAMETER NetworkConfigFile
    Your own network-config instead of the built-in example's. Any of the three files you don't give comes from
    the example; when you run the script without them, it asks.

.PARAMETER TemplatesDir
    Where the template directory is written. Default: golden-templates (in the current folder).

.PARAMETER Cli
    The metalcloud-cli command, with any global flags. Default: $env:MC_CLI, or metalcloud-cli.

.PARAMETER DryRun
    Do everything except creating the template on the controller.

.PARAMETER NoPrompt
    Never ask: stop with an error if something required is missing (for scripts and CI).

.PARAMETER Interactive
    Ask even when input is redirected.

.PARAMETER Yes
    Don't ask for confirmation before making changes.

.PARAMETER Version
    Print the script's version.

.EXAMPLE
    .\create-golden-template.ps1

.EXAMPLE
    .\create-golden-template.ps1 -NoPrompt -OS windows -Label ws2025-golden-v1 -OSVersion 2025 `
        -ImageUrl https://repo.example.com/images/ws2025-golden-v1.raw.zst.iso

.NOTES
    Give every new image version a new file name and a new label: downloads are reused by file name, and the
    URL is never checked for a newer file.

    If Windows refuses to run the script (execution policy), run it as
    powershell -ExecutionPolicy Bypass -File .\create-golden-template.ps1

    The example files are embedded base64-encoded (one of them contains PowerShell here-string markers).
    They are copies of linux-cloud-init/user-data, windows-cloudbase-init/user-data, and the shared meta-data
    and network-config. After changing one, replace its block with the output of
    [Convert]::ToBase64String([IO.File]::ReadAllBytes('<file>'))
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'An interactive console script: questions and progress go to the console, not the pipeline')]
[CmdletBinding()]
param(
    [string]$OS,
    [string]$ImageUrl,
    [string]$Label,
    [string]$Name,
    [string]$Description,
    [string]$OSName,
    [string]$OSVersion,
    [string]$BootIsoUrl,
    [string]$UserDataFile,
    [string]$MetaDataFile,
    [string]$NetworkConfigFile,
    [string]$TemplatesDir = 'golden-templates',
    [string]$Cli,
    [switch]$DryRun,
    [switch]$NoPrompt,
    [switch]$Interactive,
    [switch]$Yes,
    [switch]$Version
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.0'
$DefaultBootIsoUrl = 'https://repo.metalsoft.io/.iso/boot-golden-image.iso'

if ($Version) { Write-Output "create-golden-template.ps1 $ScriptVersion"; exit 0 }

# ---------------------------------------------------------------------------------------------------------
# Output and answers
# ---------------------------------------------------------------------------------------------------------

function Write-Step([string]$Message) { Write-Host ''; Write-Host "==> $Message" }
function Write-Info([string]$Message) { Write-Host "    $Message" }
function Exit-WithError([string]$Message) { Write-Host "ERROR: $Message" -ForegroundColor Red; exit 1 }

$InputRedirected = [Console]::IsInputRedirected
$Prompt = (-not $NoPrompt) -and ($Interactive -or -not $InputRedirected)

function Read-Answer([string]$Question, [string]$Default, [scriptblock]$Check) {
    while ($true) {
        $text = $Question
        if ($Default) { $text = "$Question [$Default]" }
        if ($InputRedirected) {
            Write-Host -NoNewline "${text}: "
            $answer = [Console]::In.ReadLine()
            if ($null -eq $answer) { Exit-WithError 'no answer (end of input)' }
            Write-Host $answer
        } else {
            $answer = Read-Host $text
        }
        if (-not $answer) { $answer = $Default }
        if ($null -eq $answer) { $answer = '' }
        $message = & $Check $answer
        if (-not $message) { return $answer }
        Write-Info $message
    }
}

# Resolve-Value VALUE PARAMETER QUESTION PROMPT-DEFAULT DEFAULT CHECK: the parameter's value if given, otherwise
# the answer (when asking) or the default; stops when the result is missing or invalid
function Resolve-Value([string]$Value, [string]$Parameter, [string]$Question, [string]$PromptDefault,
                       [string]$Default, [scriptblock]$Check) {
    if (-not $Value) {
        if ($Prompt) { $Value = Read-Answer $Question $PromptDefault $Check } else { $Value = $Default }
    }
    if (-not $Value) { Exit-WithError "give -$Parameter" }
    $message = & $Check $Value
    if ($message) { Exit-WithError "-${Parameter}: $message" }
    return $Value
}

function Get-UrlFileName([string]$Url) {
    $path = $Url.Split('?')[0]
    return $path.Substring($path.LastIndexOf('/') + 1)
}

function Test-OSFamily([string]$v) { if ($v -ceq 'linux' -or $v -ceq 'windows') { return $null }; 'answer linux or windows' }
function Test-Label([string]$v) {
    if ($v -cmatch '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$') { return $null }
    'use lowercase letters, digits and hyphens, starting and ending with a letter or digit'
}
function Test-OSName([string]$v) {
    if (-not $v) { return "os.name can't be empty" }
    if (@('windows', 'rhel', 'redhat') -contains $v.ToLowerInvariant()) {
        return "os.name must not be exactly '$v': the image builder would rebuild the boot ISO as an installer ISO"
    }
    $null
}
function Test-Url([string]$v) { if ($v -match '^https?://\S+$') { return $null }; 'give an http:// or https:// URL' }
function Test-ImageUrl([string]$v) {
    $message = Test-Url $v
    if ($message) { return $message }
    $file = Get-UrlFileName $v
    if ($file -notmatch '\.(iso|img)$') {
        return "the file name must end in .iso or .img (got '$file'): BMCs mount only those"
    }
    $null
}
function Test-Text([string]$v) { if ($v) { return $null }; "this can't be empty" }
function Test-FilesChoice([string]$v) { if ($v -match '^(e|example|o|own)$') { return $null }; 'answer example or own' }
function Resolve-LocalPath([string]$Path) {
    if ($Path -like '~*') { $Path = $HOME + $Path.Substring(1) }
    if (-not [IO.Path]::IsPathRooted($Path)) {
        $Path = [IO.Path]::Combine((Get-Location).ProviderPath, $Path)
    }
    [IO.Path]::GetFullPath($Path)
}
function Test-LocalFile([string]$v) {
    if ($v -and (Test-Path -LiteralPath (Resolve-LocalPath $v) -PathType Leaf)) { return $null }
    "no such file: $v"
}
function Test-FileOrExample([string]$v) { if ($v -eq 'example') { return $null }; Test-LocalFile $v }
function Test-YesNo([string]$v) { if ($v -match '^(y(es)?|no?)$') { return $null }; 'answer y or n' }

function ConvertTo-YamlString([string]$v) { '"' + $v.Replace('\', '\\').Replace('"', '\"') + '"' }
function Format-Argument([string]$v) { if ($v -match '^[A-Za-z0-9._:/=+-]+$') { return $v }; "'" + $v.Replace("'", "''") + "'" }

function Write-TextFile([string]$Path, [string]$Text) {
    # UTF-8 without a byte order mark and with LF line endings: a BOM or CR would break #cloud-config
    [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding $false))
}

function Expand-Example([string]$Base64) {
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($Base64 -replace '\s', '')))
}

# ---------------------------------------------------------------------------------------------------------
# The controller: metalcloud-cli needs an endpoint and an API key, and must match the controller's version
# ---------------------------------------------------------------------------------------------------------

if (-not $Cli) { $Cli = $env:MC_CLI }
if (-not $Cli) { $Cli = 'metalcloud-cli' }
$CliParts = @($Cli -split '\s+' | Where-Object { $_ })
$CliExe = $CliParts[0]
$CliArgs = @()
if ($CliParts.Count -gt 1) { $CliArgs = @($CliParts[1..($CliParts.Count - 1)]) }
if (-not (Get-Command $CliExe -ErrorAction SilentlyContinue)) {
    Exit-WithError "$CliExe is required (metalcloud-cli, configured with METALCLOUD_ENDPOINT and METALCLOUD_API_KEY)"
}

function Invoke-Cli([string[]]$Arguments) {
    # native stderr must not turn into terminating errors (Windows PowerShell 5.1 with 2>&1)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $CliExe @CliArgs @Arguments 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
    return New-Object PSObject -Property @{ Code = $code; Output = (@($output) -join "`n") }
}

function Write-SetupHelp {
    Write-Info 'Set the controller and your API key (from the controller UI: your user menu, API credentials):'
    Write-Info "  `$env:METALCLOUD_ENDPOINT = 'https://<controller>'"
    Write-Info "  `$env:METALCLOUD_API_KEY = '<API key>'"
    Write-Info 'or put endpoint: and api_key: in a metalcloud.yaml in the current folder, or pass'
    Write-Info "-Cli 'metalcloud-cli -c <path to metalcloud.yaml>'."
}
function Resolve-ControllerProblem([string]$Message, [switch]$Help) {
    # a dry run only warns
    if ($Help) { Write-SetupHelp }
    if ($DryRun) { Write-Warning "$Message. A dry run doesn't need the controller; the real run would stop here." }
    else { Exit-WithError $Message }
}
function Get-Field([string]$Text, [string]$Field) {
    $m = [regex]::Match($Text, "(?m)^$([regex]::Escape($Field)):[ \t]*(.*?)[ \t]*$")
    if ($m.Success) { return $m.Groups[1].Value }
    $null
}

Write-Step 'Checking the controller'
$Controller = ''
$CheckApi = $true
# "version" shows the endpoint metalcloud-cli uses (from the environment or its configuration file), the
# controller's version, and a "User ID" line only when the API key works
$ver = (Invoke-Cli @('version')).Output
if ($null -ne (Get-Field $ver 'Metalsoft Endpoint')) {
    $Controller = Get-Field $ver 'Metalsoft Endpoint'
    if (-not $Controller) {
        Resolve-ControllerProblem 'metalcloud-cli has no API endpoint' -Help; $CheckApi = $false
    } else {
        $ctlVersion = Get-Field $ver 'Metalsoft Endpoint Version'
        if ($ctlVersion) { Write-Info "endpoint: $Controller (version $ctlVersion)" } else { Write-Info "endpoint: $Controller" }
        if ($ver -notmatch '(?m)^User ID:') {
            Resolve-ControllerProblem "metalcloud-cli has no API key, or $Controller doesn't accept it" -Help; $CheckApi = $false
        } else {
            Write-Info 'API key accepted'
        }
    }
}
if ($CheckApi) {
    # A real call: metalcloud-cli also refuses to work with a controller version it doesn't support
    $probe = Invoke-Cli @('os-template', 'list', '-f', 'json')
    if ($probe.Code -eq 0) {
        Write-Info "metalcloud-cli $(Get-Field $ver 'CLI Version') works with this controller"
    } else {
        $line = @($probe.Output -split "`n" | Where-Object { $_ -match '^Error: ' } | Select-Object -First 1)
        if ($line.Count) { $line = $line[0] -replace '^Error: ', '' }
        else { $line = @($probe.Output -split "`n" | Where-Object { $_ -and $_ -notmatch '^Returned ' } | Select-Object -First 1) -join '' }
        if ($line -like 'API endpoint is required*') { Resolve-ControllerProblem 'metalcloud-cli has no API endpoint' -Help }
        elseif ($line -like 'API key is required*') { Resolve-ControllerProblem 'metalcloud-cli has no API key' -Help }
        elseif ($line -like 'invalid API endpoint URL*') { Resolve-ControllerProblem "metalcloud-cli's endpoint isn't a valid URL ($line)" -Help }
        elseif ($line -match 'invalid version|incompatible version') {
            Resolve-ControllerProblem "metalcloud-cli doesn't support the controller's version ($line): install the CLI release that matches the controller"
        } else { Resolve-ControllerProblem "metalcloud-cli can't use the controller: $line" }
    }
}

# ---------------------------------------------------------------------------------------------------------
# Inputs: parameters first, then questions for anything missing
# ---------------------------------------------------------------------------------------------------------

$OS = Resolve-Value $OS 'OS' 'Operating system of the image (linux or windows)' 'linux' '' ${function:Test-OSFamily}
$ImageUrl = Resolve-Value $ImageUrl 'ImageUrl' 'URL of the image ISO (already packaged and hosted)' '' '' ${function:Test-ImageUrl}

if ($Prompt) { Write-Step 'Template' }
$Label = Resolve-Value $Label 'Label' 'Template label, unique on the controller (e.g. rocky-9-golden-v1)' '' '' ${function:Test-Label}
$Name = Resolve-Value $Name 'Name' 'Template name' $Label $Label ${function:Test-Text}

if ($OS -eq 'windows') {
    $CredUser = 'Administrator'
    $DefaultDescription = 'Writes a sysprepped Windows disk image to the local disk; Cloudbase-Init configures it on first boot'
} else {
    $CredUser = 'root'
    $DefaultDescription = 'Writes a Linux disk image to the local disk; cloud-init configures it on first boot'
}
$Description = Resolve-Value $Description 'Description' 'Description' $DefaultDescription $DefaultDescription ${function:Test-Text}
$OSName = Resolve-Value $OSName 'OSName' 'os.name (never exactly windows, rhel or redhat)' "$OS-golden-image" "$OS-golden-image" ${function:Test-OSName}
$OSVersion = Resolve-Value $OSVersion 'OSVersion' 'os.version' '1.0' '1.0' ${function:Test-Text}
$BootIsoUrl = Resolve-Value $BootIsoUrl 'BootIsoUrl' 'Boot ISO URL' $DefaultBootIsoUrl $DefaultBootIsoUrl ${function:Test-Url}

# First-boot files: the built-in example, or the user's own (rendered as templates for each server either way)
if (-not ($UserDataFile -or $MetaDataFile -or $NetworkConfigFile) -and $Prompt) {
    Write-Step 'First-boot files'
    $choice = Read-Answer "user-data, meta-data and network-config: the built-in $OS example, or your own? (example/own)" 'example' ${function:Test-FilesChoice}
    if ($choice -like 'o*') {
        Write-Info "Give each file's path; leave one empty to use the example's."
        $UserDataFile = Read-Answer 'user-data file' 'example' ${function:Test-FileOrExample}
        $MetaDataFile = Read-Answer 'meta-data file' 'example' ${function:Test-FileOrExample}
        $NetworkConfigFile = Read-Answer 'network-config file' 'example' ${function:Test-FileOrExample}
        if ($UserDataFile -eq 'example') { $UserDataFile = '' }
        if ($MetaDataFile -eq 'example') { $MetaDataFile = '' }
        if ($NetworkConfigFile -eq 'example') { $NetworkConfigFile = '' }
    }
}
$OwnFiles = [ordered]@{ 'user-data' = $UserDataFile; 'meta-data' = $MetaDataFile; 'network-config' = $NetworkConfigFile }
$OwnParams = @{ 'user-data' = 'UserDataFile'; 'meta-data' = 'MetaDataFile'; 'network-config' = 'NetworkConfigFile' }
foreach ($f in @($OwnFiles.Keys)) {
    if (-not $OwnFiles[$f]) { continue }
    $message = Test-LocalFile $OwnFiles[$f]
    if ($message) { Exit-WithError "-$($OwnParams[$f]): $message" }
    $OwnFiles[$f] = Resolve-LocalPath $OwnFiles[$f]
}
if ($OwnFiles['user-data']) {
    # [IO.File]::ReadAllText drops a UTF-8 byte order mark
    $first = @([IO.File]::ReadAllText($OwnFiles['user-data']) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1) -join ''
    if ($OS -eq 'linux' -and $first -notmatch '^(#|\{|Content-Type:)') {
        Write-Warning "$($OwnFiles['user-data']) doesn't start with a header such as #cloud-config or #!: cloud-init would ignore it"
    } elseif ($OS -eq 'windows' -and $first -notmatch '^(#|\{|rem cmd|<|Content-Type:)') {
        Write-Warning "$($OwnFiles['user-data']) doesn't start with a header such as #ps1_sysnative or #cloud-config: Cloudbase-Init would ignore it"
    }
}
function Get-FilesDescription {
    @(foreach ($f in $OwnFiles.Keys) { if ($OwnFiles[$f]) { "$f $($OwnFiles[$f])" } else { "$f from the $OS example" } }) -join ', '
}

# The template directory is written on this computer: asked before it's created, unless -TemplatesDir chose it
$RelDir = "golden/$OS/$Label"
$TemplatesDirShown = $TemplatesDir
$DirConfirmed = $PSBoundParameters.ContainsKey('TemplatesDir') -or $Yes -or -not $Prompt
while ($true) {
    $TemplatesDir = Resolve-LocalPath $TemplatesDirShown
    $TDir = [IO.Path]::Combine($TemplatesDir, 'golden', $OS, $Label)
    if (Test-Path -LiteralPath $TDir) {
        if (-not $Prompt) { Exit-WithError "$TDir already exists; remove it or use another -Label or -TemplatesDir" }
        Write-Info "$TDir already exists: choose another folder (or stop with Ctrl+C and use another label)"
        $TemplatesDirShown = Read-Answer 'Folder to write the template directory in' '' ${function:Test-Text}
        $DirConfirmed = $true
        continue
    }
    if ($DirConfirmed) { break }
    Write-Info "The template files are written on this computer, in $TDir"
    $answer = Read-Answer 'Create that directory? (n to choose another folder)' 'y' ${function:Test-YesNo}
    if ($answer -match '^y') { break }
    $TemplatesDirShown = Read-Answer 'Folder to write the template directory in' '' ${function:Test-Text}
    $DirConfirmed = $true
}

# ---------------------------------------------------------------------------------------------------------
# Summary, the same run as one command, and the confirmation
# ---------------------------------------------------------------------------------------------------------

Write-Step 'Summary'
Write-Info "template:      $Name ($Label), private"
Write-Info "description:   $Description"
Write-Info "os:            name $OSName, version $OSVersion, login $CredUser with a generated password"
Write-Info "first boot:    $(Get-FilesDescription)"
Write-Info "image URL:     $ImageUrl"
Write-Info "boot ISO:      $BootIsoUrl"
Write-Info "template dir:  $TDir"
if ($DryRun) {
    Write-Info 'controller:    not changed (dry run)'
} elseif ($Controller) {
    Write-Info "controller:    $Controller"
} elseif ($env:METALCLOUD_ENDPOINT) {
    Write-Info "controller:    $env:METALCLOUD_ENDPOINT"
} else {
    Write-Info 'controller:    the one in the metalcloud-cli configuration'
}

$Command = @('.\create-golden-template.ps1', '-NoPrompt', '-OS', $OS, '-Label', $Label, '-Name', (Format-Argument $Name),
             '-Description', (Format-Argument $Description), '-OSName', (Format-Argument $OSName),
             '-OSVersion', (Format-Argument $OSVersion), '-BootIsoUrl', (Format-Argument $BootIsoUrl),
             '-ImageUrl', (Format-Argument $ImageUrl))
foreach ($f in $OwnFiles.Keys) { if ($OwnFiles[$f]) { $Command += @("-$($OwnParams[$f])", (Format-Argument $OwnFiles[$f])) } }
if ($TemplatesDirShown -ne 'golden-templates') { $Command += @('-TemplatesDir', (Format-Argument $TemplatesDirShown)) }
if ($DryRun) { $Command += '-DryRun' }
Write-Host ''
Write-Info 'The same run as one command:'
Write-Info ($Command -join ' ')

if ($Prompt -and -not $Yes) {
    Write-Host ''
    $answer = Read-Answer 'Go ahead?' 'y' ${function:Test-YesNo}
    if ($answer -notmatch '^y') { Write-Step 'Stopped; nothing was changed.'; exit 0 }
}

# ---------------------------------------------------------------------------------------------------------
# The image URL, seen from this computer (the controller downloads it, so this only catches typos)
# ---------------------------------------------------------------------------------------------------------

Write-Step 'Checking the image URL'
try {
    # Windows PowerShell 5.1 may default to TLS 1.0; PowerShell 7 doesn't need this
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 }
    catch { Write-Verbose "couldn't enable TLS 1.2: $($_.Exception.Message)" }
    $response = Invoke-WebRequest -Uri $ImageUrl -Method Head -UseBasicParsing -TimeoutSec 30
    $length = $response.Headers['Content-Length']
    if ($length -is [array]) { $length = $length[0] }
    if ($length) { Write-Info ("{0} answers: {1:N0} MiB" -f $ImageUrl, ([int64]$length / 1MB)) } else { Write-Info "$ImageUrl answers" }
} catch {
    Write-Warning "$ImageUrl didn't answer from this computer ($($_.Exception.Message)). Check the URL; what matters is that the controller can download it."
}
Write-Info 'The URL must be reachable from the component that downloads it (the global controller by default,'
Write-Info "or the site controller if it builds images), with a trusted certificate if it's HTTPS."

# ---------------------------------------------------------------------------------------------------------
# Step 4: write the template directory
# ---------------------------------------------------------------------------------------------------------

Write-Step "Step 4: writing $TDir"
if (Test-Path -LiteralPath $TDir) { Exit-WithError "$TDir already exists; remove it or use another -Label" }
New-Item -ItemType Directory -Force -Path $TDir | Out-Null
$ImageFileName = Get-UrlFileName $ImageUrl
$BootFileName = Get-UrlFileName $BootIsoUrl

$TemplateYaml = @"
template:
  name: $(ConvertTo-YamlString $Name)
  label: $Label
  description: $(ConvertTo-YamlString $Description)
  visibility: private
  device:
    architecture: x86_64
    bootmode: uefi
    type: server
  imagebuild:
    required: true
  install:
    drivetype: local_drive
    method: oob
    readymethod: wait_for_power_off
  os:
    name: $(ConvertTo-YamlString $OSName)
    version: $(ConvertTo-YamlString $OSVersion)
    credential:
      username: $CredUser
      passwordtype: generated
  tags:
    - golden-image
    - $OS
templateassets:
  # Virtual media 1: MetalSoft's boot ISO (volume label CIDATA). The files below are added to it per server.
  - file:
      name: $BootFileName
      path: /$BootFileName
      mimetype: application/octet-stream
      url: $BootIsoUrl
      templatingengine: false
    usage: build_source_image
  # Virtual media 2: the golden image. Give every image version a new file name.
  - file:
      name: $ImageFileName
      path: /$ImageFileName
      mimetype: application/octet-stream
      url: $ImageUrl
      templatingengine: false
    usage: secondary_image
  - file:
      name: user-data
      path: /user-data
      mimetype: text/plain
      templatingengine: true
    usage: build_component
  - file:
      name: meta-data
      path: /meta-data
      mimetype: text/plain
      templatingengine: true
    usage: build_component
  - file:
      name: network-config
      path: /network-config
      mimetype: text/plain
      templatingengine: true
    usage: build_component

"@

$LinuxUserData = @'
I2Nsb3VkLWNvbmZpZwp7Iy0gRmlyc3QgYm9vdCBvZiB0aGUgZ29sZGVuIGltYWdlLiBjbG91ZC1pbml0IHJlYWRzIHRoaXMgZnJv
bSB0aGUgQ0lEQVRBIGJvb3QgSVNPLCB3aGljaCBzdGF5cyBhdHRhY2hlZC4gLSN9CnslLSBzZXQgc2kgPSBzZXJ2ZXJJbnN0YW5j
ZSBvciB7fSAlfQp7JS0gc2V0IHBhc3N3b3JkID0gc2kub3NDcmVkZW50aWFscy5pbml0aWFsUGFzc3dvcmRFbmNyeXB0ZWQgaWYg
c2kub3NDcmVkZW50aWFscyBlbHNlICcnICV9CnslLSBzZXQga2V5cyA9IFtdICV9CnslLSBmb3Iga2V5IGluICh1c2VyU1NIS2V5
cyBvciBbXSkgJX17JSBpZiBrZXkgJX17JSBzZXQga2V5cyA9IChrZXlzLnB1c2goa2V5KSwga2V5cykgJX17JSBlbmRpZiAlfXsl
IGVuZGZvciAlfQp7JS0gaWYgbWFuYWdlbWVudFNTSEtleSAlfXslIHNldCBrZXlzID0gKGtleXMucHVzaChtYW5hZ2VtZW50U1NI
S2V5KSwga2V5cykgJX17JSBlbmRpZiAlfQp7JS0gc2V0IGJvbmRzID0gW10gJX0KeyUtIGZvciBpbnRlcmZhY2UgaW4gKChuZXR3
b3JrLmludGVyZmFjZXMgaWYgbmV0d29yayBlbHNlIFtdKSBvciBbXSkgJX17JSBpZiBpbnRlcmZhY2UuaW50ZXJmYWNlVHlwZSA9
PSAnYm9uZCcgJX17JSBzZXQgYm9uZHMgPSAoYm9uZHMucHVzaChpbnRlcmZhY2UpLCBib25kcykgJX17JSBlbmRpZiAlfXslIGVu
ZGZvciAlfQoKcHJlc2VydmVfaG9zdG5hbWU6IGZhbHNlCmhvc3RuYW1lOiB7eyAoc2kuaG9zdG5hbWUgb3Igc2kubGFiZWwgb3Ig
J2xvY2FsaG9zdCcpIHwgZHVtcCB8IHNhZmUgfX0KeyUtIGlmIHNpLnByb3Zpc2lvbkluc3RhbmNlRG5zUmVjb3JkcyBhbmQgc2ku
ZnFkbiAlfQpmcWRuOiB7eyBzaS5mcWRuIHwgZHVtcCB8IHNhZmUgfX0KcHJlZmVyX2ZxZG5fb3Zlcl9ob3N0bmFtZTogdHJ1ZQp7
JS0gZWxzZSAlfQpwcmVmZXJfZnFkbl9vdmVyX2hvc3RuYW1lOiBmYWxzZQp7JS0gZW5kaWYgJX0KbWFuYWdlX2V0Y19ob3N0czog
dHJ1ZQp0aW1lem9uZTogVVRDCgojIEtlZXAgdGhlIGltYWdlJ3MgZGVmYXVsdCB1c2VyICh1YnVudHUsIHJvY2t5LCBkZWJpYW4s
IGNsb3VkLXVzZXIsIC4uLikgd2l0aCB0aGUgU1NIIGtleXMuCiMgZGlzYWJsZV9yb290OiBmYWxzZSBhbHNvIHB1dHMgdGhlIGtl
eXMgaW4gcm9vdCdzIGF1dGhvcml6ZWRfa2V5cy4KdXNlcnM6CiAgLSBkZWZhdWx0CmRpc2FibGVfcm9vdDogZmFsc2UKeyUtIGlm
IGtleXMgfCBsZW5ndGggJX0Kc3NoX2F1dGhvcml6ZWRfa2V5czoKeyUtIGZvciBrZXkgaW4ga2V5cyAlfQogIC0ge3sga2V5IHwg
ZHVtcCB8IHNhZmUgfX0KeyUtIGVuZGZvciAlfQp7JS0gZW5kaWYgJX0KCnslLSBpZiBwYXNzd29yZCAlfQoKIyByb290IGdldHMg
dGhlIHBhc3N3b3JkIE1ldGFsU29mdCBnZW5lcmF0ZWQgZm9yIHRoaXMgc2VydmVyIChuZWVkcyBjbG91ZC1pbml0IDIyLjMgb3Ig
bGF0ZXIpCmNocGFzc3dkOgogIGV4cGlyZTogZmFsc2UKICB1c2VyczoKICAgIC0gbmFtZTogcm9vdAogICAgICBwYXNzd29yZDog
e3sgcGFzc3dvcmQgfCBkdW1wIHwgc2FmZSB9fQogICAgICB0eXBlOiB0ZXh0CnslLSBlbmRpZiAlfQoKIyBHcm93IHRoZSByb290
IHBhcnRpdGlvbiBhbmQgZmlsZXN5c3RlbSB0byB0aGUgc2l6ZSBvZiB0aGUgZGlzawpncm93cGFydDoKICBtb2RlOiBhdXRvCiAg
ZGV2aWNlczogWyIvIl0KcmVzaXplX3Jvb3RmczogdHJ1ZQoKcGFja2FnZV91cGRhdGU6IGZhbHNlCnBhY2thZ2VfdXBncmFkZTog
ZmFsc2UKCnJ1bmNtZDoKICAjIFByb3Zpc2lvbmluZyBpcyBvbmUtc2hvdC4gV2l0aG91dCB0aGlzLCBhIGRpc3RybyB3aG9zZSBj
bG91ZC1pbml0IHN0aWxsIHJ1bnMgYWZ0ZXIgdGhlCiAgIyBDSURBVEEgSVNPIGlzIHJlbW92ZWQgbWF5IHRyZWF0IHRoZSBzZXJ2
ZXIgYXMgYSBuZXcgaW5zdGFuY2UgYW5kIHJld3JpdGUgaXRzIG5ldHdvcmsgY29uZmlnLgogIC0gW3RvdWNoLCAvZXRjL2Nsb3Vk
L2Nsb3VkLWluaXQuZGlzYWJsZWRdCnsjLQogIFdoZXJlIGNsb3VkLWluaXQgd3JpdGVzIE5ldHdvcmtNYW5hZ2VyIGZpbGVzIChS
SEVMIDEwLCBTTEVTIDE2IGFuZCBvdGhlcnMpLCBjbG91ZC1pbml0IDI2LjIgYW5kIGVhcmxpZXIKICBsZWF2ZSBsYWNwX3JhdGUg
YW5kIHhtaXRfaGFzaF9wb2xpY3kgb3V0IG9mIHRoZSBib25kIChmaXhlZCB1cHN0cmVhbSBpbiBjbG91ZC1pbml0IFBSIDY5MzYp
LiBTZXQgdGhlbQogIHdpdGggbm1jbGk7IHRoZXkgdGFrZSBlZmZlY3QgZnJvbSB0aGUgbmV4dCBib290LiBFbHNld2hlcmUgdGhl
IGZpbGUgdGVzdCBpcyBmYWxzZSBhbmQgbm90aGluZyBydW5zLgogIFRoZSB2YWx1ZXMgbWF0Y2ggdGhlIG9uZXMgaW4gbmV0d29y
ay1jb25maWcuCi0jfQp7JS0gZm9yIGJvbmQgaW4gYm9uZHMgJX0KICB7JS0gc2V0IHBhcmFtZXRlcnMgPSBib25kLnBhcmFtZXRl
cnMgb3Ige30gJX0KICB7JS0gc2V0IG1vZGUgPSBib25kLmJvbmRNb2RlIG9yIHBhcmFtZXRlcnMubW9kZSBvciAnODAyLjNhZCcg
JX0KICB7JS0gaWYgbW9kZSA9PSAnODAyLjNhZCcgb3IgbW9kZSA9PSAnYmFsYW5jZS14b3InICV9CiAgeyUtIHNldCBuYW1lID0g
J2JvbmQnIH4gYm9uZC50eXBlSW50ZXJmYWNlSWQgJX0KICB7JS0gc2V0IG9wdGlvbnMgPSAnbW9kZT0nIH4gbW9kZSB+ICcsbWlp
bW9uPScgfiAocGFyYW1ldGVycy5taWlNb25pdG9ySW50ZXJ2YWwgb3IgMTAwKSB+ICgoJyxsYWNwX3JhdGU9JyB+IChwYXJhbWV0
ZXJzLmxhY3BSYXRlIG9yICdmYXN0JykpIGlmIG1vZGUgPT0gJzgwMi4zYWQnIGVsc2UgJycpIH4gJyx4bWl0X2hhc2hfcG9saWN5
PScgfiAocGFyYW1ldGVycy50cmFuc21pdEhhc2hQb2xpY3kgb3IgJ2xheWVyMys0JykgJX0KICAtIHt7ICgiaWYgWyAtZiAvZXRj
L05ldHdvcmtNYW5hZ2VyL3N5c3RlbS1jb25uZWN0aW9ucy9jbG91ZC1pbml0LSIgfiBuYW1lIH4gIi5ubWNvbm5lY3Rpb24gXTsg
dGhlbiBubWNsaSBjb25uZWN0aW9uIG1vZGlmeSAnY2xvdWQtaW5pdCAiIH4gbmFtZSB+ICInIGJvbmQub3B0aW9ucyAnIiB+IG9w
dGlvbnMgfiAiJzsgZmkiKSB8IGR1bXAgfCBzYWZlIH19CiAgeyUtIGVuZGlmICV9CnslLSBlbmRmb3IgJX0KCiMgTWV0YWxTb2Z0
J3Mgd2FpdF9mb3JfcG93ZXJfb2ZmIGZpbmlzaGVzIHRoZSBkZXBsb3ltZW50IHdoZW4gdGhlIHNlcnZlciBwb3dlcnMgb2ZmCnBv
d2VyX3N0YXRlOgogIG1vZGU6IHBvd2Vyb2ZmCiAgZGVsYXk6IG5vdwogIG1lc3NhZ2U6IE1ldGFsU29mdCBwcm92aXNpb25pbmcg
Y29tcGxldGUKICB0aW1lb3V0OiAzMDAKICBjb25kaXRpb246IHRydWUK
'@
$WindowsUserData = @'
I3BzMV9zeXNuYXRpdmUKeyMtCiAgRmlyc3QgYm9vdCBvZiB0aGUgZ29sZGVuIGltYWdlLiBDbG91ZGJhc2UtSW5pdCdzIFVzZXJE
YXRhUGx1Z2luIHJ1bnMgdGhpcyBvbmNlLCByZWFkaW5nIGl0IGZyb20gdGhlCiAgQ0lEQVRBIGJvb3QgSVNPLiBIb3N0bmFtZSAo
bWV0YS1kYXRhKSBhbmQgbmV0d29yayAobmV0d29yay1jb25maWcpIGFyZSBhcHBsaWVkIGJ5IENsb3VkYmFzZS1Jbml0IGl0c2Vs
Zi4KLSN9CnslLSBzZXQgc2kgPSBzZXJ2ZXJJbnN0YW5jZSBvciB7fSAlfQp7JS0gc2V0IHBhc3N3b3JkID0gc2kub3NDcmVkZW50
aWFscy5pbml0aWFsUGFzc3dvcmRFbmNyeXB0ZWQgaWYgc2kub3NDcmVkZW50aWFscyBlbHNlICcnICV9CnslLSBzZXQga2V5cyA9
IFtdICV9CnslLSBmb3Iga2V5IGluICh1c2VyU1NIS2V5cyBvciBbXSkgJX17JSBpZiBrZXkgJX17JSBzZXQga2V5cyA9IChrZXlz
LnB1c2goa2V5KSwga2V5cykgJX17JSBlbmRpZiAlfXslIGVuZGZvciAlfQp7JS0gaWYgbWFuYWdlbWVudFNTSEtleSAlfXslIHNl
dCBrZXlzID0gKGtleXMucHVzaChtYW5hZ2VtZW50U1NIS2V5KSwga2V5cykgJX17JSBlbmRpZiAlfQp7JS0gc2V0IG50cCA9IFtd
ICV9CnslLSBmb3Igc2VydmVyIGluICgoc2l0ZUNvbmZpZy5OVFBTZXJ2ZXJzIGlmIHNpdGVDb25maWcgZWxzZSBbXSkgb3IgW10p
ICV9eyUgaWYgc2VydmVyICV9eyUgc2V0IG50cCA9IChudHAucHVzaChzZXJ2ZXIpLCBudHApICV9eyUgZW5kaWYgJX17JSBlbmRm
b3IgJX0KJEVycm9yQWN0aW9uUHJlZmVyZW5jZSA9ICdTdG9wJwoKIyBUaGUgYnVpbHQtaW4gQWRtaW5pc3RyYXRvciBhY2NvdW50
LCBmb3VuZCBieSBpdHMgd2VsbC1rbm93biBTSUQgKGl0cyBuYW1lIGNhbiBiZSBsb2NhbGl6ZWQgb3IgcmVuYW1lZCkKJGFkbWlu
ID0gR2V0LUxvY2FsVXNlciB8IFdoZXJlLU9iamVjdCB7ICRfLlNJRC5WYWx1ZSAtbGlrZSAnUy0xLTUtKi01MDAnIH0KeyUtIGlm
IHBhc3N3b3JkICV9CgojIEFkbWluaXN0cmF0b3IgcGFzc3dvcmQ6IHRoZSBvbmUgTWV0YWxTb2Z0IGdlbmVyYXRlZCBmb3IgdGhp
cyBzZXJ2ZXIKJHBhc3N3b3JkID0gQ29udmVydFRvLVNlY3VyZVN0cmluZyAtU3RyaW5nICd7eyBwYXNzd29yZCB8IHJlcGxhY2Uo
IiciLCAiJyciKSB8IHNhZmUgfX0nIC1Bc1BsYWluVGV4dCAtRm9yY2UKU2V0LUxvY2FsVXNlciAtU0lEICRhZG1pbi5TSUQgLVBh
c3N3b3JkICRwYXNzd29yZCAtUGFzc3dvcmROZXZlckV4cGlyZXMgJHRydWUKUmVtb3ZlLVZhcmlhYmxlIHBhc3N3b3JkCnslLSBl
bmRpZiAlfQpFbmFibGUtTG9jYWxVc2VyIC1TSUQgJGFkbWluLlNJRAp7JS0gaWYga2V5cyB8IGxlbmd0aCAlfQoKIyBTU0gga2V5
cywgb25seSBpZiBPcGVuU1NIIFNlcnZlciBpcyBpbnN0YWxsZWQgaW4gdGhlIGltYWdlCmlmIChHZXQtU2VydmljZSAtTmFtZSBz
c2hkIC1FcnJvckFjdGlvbiBTaWxlbnRseUNvbnRpbnVlKSB7CiAgICAka2V5c0ZpbGUgPSBKb2luLVBhdGggJGVudjpQcm9ncmFt
RGF0YSAnc3NoXGFkbWluaXN0cmF0b3JzX2F1dGhvcml6ZWRfa2V5cycKICAgIE5ldy1JdGVtIC1JdGVtVHlwZSBEaXJlY3Rvcnkg
LUZvcmNlIC1QYXRoIChTcGxpdC1QYXRoICRrZXlzRmlsZSkgfCBPdXQtTnVsbAogICAgJGtleXMgPSBAKAp7JS0gZm9yIGtleSBp
biBrZXlzICV9CiAgICAgICAgJ3t7IGtleSB8IHJlcGxhY2UoIiciLCAiJyciKSB8IHNhZmUgfX0nCnslLSBlbmRmb3IgJX0KICAg
ICkKICAgIFNldC1Db250ZW50IC1QYXRoICRrZXlzRmlsZSAtVmFsdWUgJGtleXMgLUVuY29kaW5nIGFzY2lpCiAgICAjIEFkbWlu
aXN0cmF0b3JzIGFuZCBTWVNURU0gb25seSwgYXMgT3BlblNTSCByZXF1aXJlczsgU0lEcyBzbyBsb2NhbGl6ZWQgZ3JvdXAgbmFt
ZXMgZG9uJ3QgbWF0dGVyCiAgICBpY2FjbHMuZXhlICRrZXlzRmlsZSAvaW5oZXJpdGFuY2U6ciAvZ3JhbnQgJypTLTEtNS0zMi01
NDQ6RicgL2dyYW50ICcqUy0xLTUtMTg6RicgfCBPdXQtTnVsbAogICAgU2V0LVNlcnZpY2UgLU5hbWUgc3NoZCAtU3RhcnR1cFR5
cGUgQXV0b21hdGljCn0KeyUtIGVuZGlmICV9CnslLSBpZiBudHAgfCBsZW5ndGggJX0KCiMgVGltZSBzZXJ2ZXJzClNldC1TZXJ2
aWNlIC1OYW1lIFczMlRpbWUgLVN0YXJ0dXBUeXBlIEF1dG9tYXRpYwpTdGFydC1TZXJ2aWNlIC1OYW1lIFczMlRpbWUKdzMydG0u
ZXhlIC9jb25maWcgL21hbnVhbHBlZXJsaXN0OiJ7eyBudHAgfCBqb2luKCcgJykgfX0iIC9zeW5jZnJvbWZsYWdzOm1hbnVhbCAv
dXBkYXRlIHwgT3V0LU51bGwKeyUtIGVuZGlmICV9CgojIEdyb3cgQzogdG8gdGhlIGVuZCBvZiB0aGUgZGlzay4gRXh0ZW5kVm9s
dW1lc1BsdWdpbiBkb2VzIHRoaXMgdG9vIHdoZW4gaXQncyBlbmFibGVkOyByZXBlYXRpbmcgaXQgaXMgaGFybWxlc3MuCiRjUGFy
dGl0aW9uID0gR2V0LVBhcnRpdGlvbiAtRHJpdmVMZXR0ZXIgQwokY01heCA9IChHZXQtUGFydGl0aW9uU3VwcG9ydGVkU2l6ZSAt
RHJpdmVMZXR0ZXIgQykuU2l6ZU1heAppZiAoJGNNYXggLWd0ICgkY1BhcnRpdGlvbi5TaXplICsgMU1CKSkgewogICAgUmVzaXpl
LVBhcnRpdGlvbiAtRHJpdmVMZXR0ZXIgQyAtU2l6ZSAkY01heAp9CgojIFBvd2VyIG9mZiBvbmNlIENsb3VkYmFzZS1Jbml0IGhh
cyBmaW5pc2hlZCwgc28gTWV0YWxTb2Z0J3Mgd2FpdF9mb3JfcG93ZXJfb2ZmIGNvbXBsZXRlcy4KIyBQcm92aXNpb25pbmcgaXMg
b25lLXNob3Q6IENsb3VkYmFzZS1Jbml0IGlzIGFsc28gc3RvcHBlZCBmcm9tIHJ1bm5pbmcgb24gbGF0ZXIgYm9vdHMuCiRjb25m
ID0gSm9pbi1QYXRoICRlbnY6UHJvZ3JhbUZpbGVzICdDbG91ZGJhc2UgU29sdXRpb25zXENsb3VkYmFzZS1Jbml0XGNvbmZcY2xv
dWRiYXNlLWluaXQuY29uZicKJGNvbmZMaW5lcyA9IEAoaWYgKFRlc3QtUGF0aCAkY29uZikgeyBHZXQtQ29udGVudCAtUGF0aCAk
Y29uZiB9KQokc2NyaXB0c1NldHRpbmcgPSAkY29uZkxpbmVzIHwgU2VsZWN0LVN0cmluZyAtUGF0dGVybiAnXlxzKmxvY2FsX3Nj
cmlwdHNfcGF0aFxzKj1ccyooLis/KVxzKiQnIHwgU2VsZWN0LU9iamVjdCAtRmlyc3QgMQokcGx1Z2luc1NldHRpbmcgPSAkY29u
ZkxpbmVzIHwgU2VsZWN0LVN0cmluZyAtUGF0dGVybiAnXlxzKnBsdWdpbnNccyo9XHMqKC4rPylccyokJyB8IFNlbGVjdC1PYmpl
Y3QgLUZpcnN0IDEKIyBUaGUgZGVmYXVsdCBwbHVnaW4gbGlzdCAobm8gcGx1Z2lucz0gbGluZSkgaW5jbHVkZXMgTG9jYWxTY3Jp
cHRzUGx1Z2luCiRsb2NhbFNjcmlwdHNSdW5zID0gJHNjcmlwdHNTZXR0aW5nIC1hbmQgKCgtbm90ICRwbHVnaW5zU2V0dGluZykg
LW9yCiAgICAoJHBsdWdpbnNTZXR0aW5nLk1hdGNoZXNbMF0uR3JvdXBzWzFdLlZhbHVlIC1tYXRjaCAnTG9jYWxTY3JpcHRzUGx1
Z2luJykpCmlmICgkbG9jYWxTY3JpcHRzUnVucykgewogICAgIyBMb2NhbFNjcmlwdHNQbHVnaW4gcnVucyBhZnRlciBldmVyeSBv
dGhlciBwbHVnaW4sIHNvIGEgc2NyaXB0IGxlZnQgaW4gaXRzIGZvbGRlciBub3cKICAgICMgcG93ZXJzIHRoZSBzZXJ2ZXIgb2Zm
IGF0IHRoZSB2ZXJ5IGVuZCBvZiB0aGlzIGJvb3QKICAgICRsb2NhbFNjcmlwdHMgPSAkc2NyaXB0c1NldHRpbmcuTWF0Y2hlc1sw
XS5Hcm91cHNbMV0uVmFsdWUKICAgIE5ldy1JdGVtIC1JdGVtVHlwZSBEaXJlY3RvcnkgLUZvcmNlIC1QYXRoICRsb2NhbFNjcmlw
dHMgfCBPdXQtTnVsbAogICAgQCcKIyBXcml0dGVuIGJ5IHRoZSBNZXRhbFNvZnQgdXNlci1kYXRhIG9uIGZpcnN0IGJvb3QuCnNj
LmV4ZSBjb25maWcgY2xvdWRiYXNlLWluaXQgc3RhcnQ9IGRpc2FibGVkIHwgT3V0LU51bGwKc2h1dGRvd24uZXhlIC9zIC90IDE1
IC9mIC9kIHA6NDoxIC9jICJNZXRhbFNvZnQgcHJvdmlzaW9uaW5nIGNvbXBsZXRlIgpleGl0IDAKJ0AgfCBTZXQtQ29udGVudCAt
UGF0aCAoSm9pbi1QYXRoICRsb2NhbFNjcmlwdHMgJzk5LW1ldGFsc29mdC1wb3dlcm9mZi5wczEnKSAtRW5jb2RpbmcgYXNjaWkK
fSBlbHNlIHsKICAgICMgTm8gTG9jYWxTY3JpcHRzUGx1Z2luIGluIHRoaXMgaW1hZ2U6IHBvd2VyIG9mZiB0d28gbWludXRlcyBh
ZnRlciB0aGlzIHNjcmlwdCByZXR1cm5zLAogICAgIyB3aGljaCBsZWF2ZXMgQ2xvdWRiYXNlLUluaXQgdGltZSB0byBmaW5pc2gg
aXRzIHJlbWFpbmluZyBwbHVnaW5zIGFuZCBzYXZlIGl0cyBzdGF0ZQogICAgc2MuZXhlIGNvbmZpZyBjbG91ZGJhc2UtaW5pdCBz
dGFydD0gZGlzYWJsZWQgfCBPdXQtTnVsbAogICAgc2h1dGRvd24uZXhlIC9zIC90IDEyMCAvZiAvZCBwOjQ6MSAvYyAiTWV0YWxT
b2Z0IHByb3Zpc2lvbmluZyBjb21wbGV0ZSIKfQoKZXhpdCAwCg==
'@
$MetaData = @'
eyUtIHNldCBzaSA9IHNlcnZlckluc3RhbmNlIG9yIHt9IC0lfQppbnN0YW5jZS1pZDoge3sgKCdtZXRhbHNvZnQtJyB+IChzaS5s
YWJlbCBvciAnaW5zdGFuY2UnKSkgfCBkdW1wIHwgc2FmZSB9fQpsb2NhbC1ob3N0bmFtZToge3sgKHNpLmhvc3RuYW1lIG9yIHNp
LmxhYmVsIG9yICdsb2NhbGhvc3QnKSB8IGR1bXAgfCBzYWZlIH19Cg==
'@
$NetworkConfig = @'
eyMtCiAgTm9DbG91ZCBuZXR3b3JrLWNvbmZpZywgdmVyc2lvbiAyLiBSZWFkIG9uIGZpcnN0IGJvb3QgYnkgY2xvdWQtaW5pdCAo
TGludXgpIGFuZCBieQogIENsb3VkYmFzZS1Jbml0IDEuMS41IG9yIGxhdGVyIChXaW5kb3dzKS4gSW50ZXJmYWNlcyBhcmUgbWF0
Y2hlZCBieSBNQUMgYWRkcmVzcyBhbmQgbmFtZWQKICBwaHk8Tj4sIGJvbmQ8Tj4gYW5kIDxwYXJlbnQ+Ljx2bGFuIGlkPi4KLSN9
CnslLSBzZXQgZG5zID0gW10gJX0KeyUtIGZvciBzZXJ2ZXIgaW4gKChzaXRlQ29uZmlnLkROU1NlcnZlcnMgaWYgc2l0ZUNvbmZp
ZyBlbHNlIFtdKSBvciBbXSkgJX17JSBpZiBzZXJ2ZXIgJX17JSBzZXQgZG5zID0gKGRucy5wdXNoKHNlcnZlciksIGRucykgJX17
JSBlbmRpZiAlfXslIGVuZGZvciAlfQp7JS0gc2V0IHBoeXNpY2FscyA9IFtdICV9CnslLSBzZXQgYm9uZHMgPSBbXSAlfQp7JS0g
c2V0IHZsYW5zID0gW10gJX0KeyUtIGZvciBpbnRlcmZhY2UgaW4gKChuZXR3b3JrLmludGVyZmFjZXMgaWYgbmV0d29yayBlbHNl
IFtdKSBvciBbXSkgJX0KICB7JS0gaWYgaW50ZXJmYWNlLmludGVyZmFjZVR5cGUgPT0gJ3BoeXNpY2FsJyAlfXslIHNldCBwaHlz
aWNhbHMgPSAocGh5c2ljYWxzLnB1c2goaW50ZXJmYWNlKSwgcGh5c2ljYWxzKSAlfQogIHslLSBlbGlmIGludGVyZmFjZS5pbnRl
cmZhY2VUeXBlID09ICdib25kJyAlfXslIHNldCBib25kcyA9IChib25kcy5wdXNoKGludGVyZmFjZSksIGJvbmRzKSAlfQogIHsl
LSBlbGlmIGludGVyZmFjZS5pbnRlcmZhY2VUeXBlID09ICd2bGFuJyBhbmQgaW50ZXJmYWNlLmxpbmtzIGFuZCBpbnRlcmZhY2Uu
bGlua3MgfCBsZW5ndGggJX17JSBzZXQgdmxhbnMgPSAodmxhbnMucHVzaChpbnRlcmZhY2UpLCB2bGFucykgJX0KICB7JS0gZW5k
aWYgJX0KeyUtIGVuZGZvciAlfQoKeyUtIG1hY3JvIGxpbmtOYW1lKGxpbmspIC0lfQp7eyAnYm9uZCcgaWYgbGluay5pbnRlcmZh
Y2VUeXBlID09ICdib25kJyBlbHNlICdwaHknIH19e3sgbGluay5pZCB9fQp7JS0gZW5kbWFjcm8gJX0KCnslLSBtYWNybyBsYXll
cjMoaW50ZXJmYWNlKSAlfQogICAgeyUtIGlmIGludGVyZmFjZS5tdHUgJX0KICAgIG10dToge3sgaW50ZXJmYWNlLm10dSB9fQog
ICAgeyUtIGVuZGlmICV9CiAgICB7JS0gc2V0IGlwdjQgPSBpbnRlcmZhY2UuaXB2NEFkZHJlc3NlcyBvciBbXSAlfQogICAgeyUt
IHNldCBpcHY2ID0gaW50ZXJmYWNlLmlwdjZBZGRyZXNzZXMgb3IgW10gJX0KICAgIHslLSBpZiBpcHY0IHwgbGVuZ3RoIG9yIGlw
djYgfCBsZW5ndGggJX0KICAgIGFkZHJlc3NlczoKICAgICAgeyUtIGZvciBhZGRyZXNzIGluIGlwdjQgJX0KICAgICAgLSB7eyBh
ZGRyZXNzLmNpZHIgfX0KICAgICAgeyUtIGVuZGZvciAlfQogICAgICB7JS0gZm9yIGFkZHJlc3MgaW4gaXB2NiAlfQogICAgICAt
IHt7IGFkZHJlc3MuY2lkciB9fQogICAgICB7JS0gZW5kZm9yICV9CiAgICB7JS0gaWYgaXB2NCB8IGxlbmd0aCBhbmQgZG5zIHwg
bGVuZ3RoICV9CiAgICBuYW1lc2VydmVyczoKICAgICAgYWRkcmVzc2VzOgogICAgICAgIHslLSBmb3Igc2VydmVyIGluIGRucyAl
fQogICAgICAgIC0ge3sgc2VydmVyIH19CiAgICAgICAgeyUtIGVuZGZvciAlfQogICAgeyUtIGVuZGlmICV9CiAgICB7JS0gZWxp
ZiBpbnRlcmZhY2UuZGhjcDQgJX0KICAgIGRoY3A0OiB0cnVlCiAgICB7JS0gZW5kaWYgJX0KICAgIHslLSBpZiBpbnRlcmZhY2Uu
cm91dGVzIGFuZCBpbnRlcmZhY2Uucm91dGVzIHwgbGVuZ3RoICV9CiAgICByb3V0ZXM6CiAgICAgIHslLSBmb3Igcm91dGUgaW4g
aW50ZXJmYWNlLnJvdXRlcyAlfQogICAgICAtIHRvOiB7eyByb3V0ZS50byB9fQogICAgICAgIHZpYToge3sgcm91dGUudmlhIH19
CiAgICAgICAgeyUtIGlmIHJvdXRlLm1ldHJpYyAlfQogICAgICAgIG1ldHJpYzoge3sgcm91dGUubWV0cmljIH19CiAgICAgICAg
eyUtIGVuZGlmICV9CiAgICAgIHslLSBlbmRmb3IgJX0KICAgIHslLSBlbmRpZiAlfQp7JS0gZW5kbWFjcm8gLSV9CnZlcnNpb246
IDIKeyUtIGlmIHBoeXNpY2FscyB8IGxlbmd0aCAlfQpldGhlcm5ldHM6CiAgeyUtIGZvciBpbnRlcmZhY2UgaW4gcGh5c2ljYWxz
ICV9CiAgcGh5e3sgaW50ZXJmYWNlLnR5cGVJbnRlcmZhY2VJZCB9fToKICAgIG1hdGNoOgogICAgICBtYWNhZGRyZXNzOiB7eyAo
aW50ZXJmYWNlLm1hY0FkZHJlc3MgfCBsb3dlcikgfCBkdW1wIHwgc2FmZSB9fQogICAgc2V0LW5hbWU6IHBoeXt7IGludGVyZmFj
ZS50eXBlSW50ZXJmYWNlSWQgfX0KICAgIHt7LSBsYXllcjMoaW50ZXJmYWNlKSB9fQogIHslLSBlbmRmb3IgJX0KeyUtIGVuZGlm
ICV9CnslLSBpZiBib25kcyB8IGxlbmd0aCAlfQpib25kczoKICB7JS0gZm9yIGJvbmQgaW4gYm9uZHMgJX0KICB7JS0gc2V0IHBh
cmFtZXRlcnMgPSBib25kLnBhcmFtZXRlcnMgb3Ige30gJX0KICB7JS0gc2V0IG1vZGUgPSBib25kLmJvbmRNb2RlIG9yIHBhcmFt
ZXRlcnMubW9kZSBvciAnODAyLjNhZCcgJX0KICBib25ke3sgYm9uZC50eXBlSW50ZXJmYWNlSWQgfX06CiAgICBpbnRlcmZhY2Vz
OgogICAgICB7JS0gZm9yIG1lbWJlciBpbiAoYm9uZC5tZW1iZXJzIG9yIFtdKSAlfQogICAgICAtIHt7IGxpbmtOYW1lKG1lbWJl
cikgfX0KICAgICAgeyUtIGVuZGZvciAlfQogICAgcGFyYW1ldGVyczoKICAgICAgbW9kZToge3sgbW9kZSB9fQogICAgICB7JS0g
aWYgbW9kZSA9PSAnODAyLjNhZCcgJX0KICAgICAgbGFjcC1yYXRlOiB7eyBwYXJhbWV0ZXJzLmxhY3BSYXRlIG9yICdmYXN0JyB9
fQogICAgICB7JS0gZW5kaWYgJX0KICAgICAgeyUtIGlmIG1vZGUgPT0gJzgwMi4zYWQnIG9yIG1vZGUgPT0gJ2JhbGFuY2UteG9y
JyAlfQogICAgICB0cmFuc21pdC1oYXNoLXBvbGljeToge3sgcGFyYW1ldGVycy50cmFuc21pdEhhc2hQb2xpY3kgb3IgJ2xheWVy
Mys0JyB9fQogICAgICB7JS0gZW5kaWYgJX0KICAgICAgbWlpLW1vbml0b3ItaW50ZXJ2YWw6IHt7IHBhcmFtZXRlcnMubWlpTW9u
aXRvckludGVydmFsIG9yIDEwMCB9fQogICAge3stIGxheWVyMyhib25kKSB9fQogIHslLSBlbmRmb3IgJX0KeyUtIGVuZGlmICV9
CnslLSBpZiB2bGFucyB8IGxlbmd0aCAlfQp2bGFuczoKICB7JS0gZm9yIHZsYW4gaW4gdmxhbnMgJX0KICB7eyBsaW5rTmFtZSh2
bGFuLmxpbmtzWzBdKSB9fS57eyB2bGFuLnZsYW5JZCB9fToKICAgIGlkOiB7eyB2bGFuLnZsYW5JZCB9fQogICAgbGluazoge3sg
bGlua05hbWUodmxhbi5saW5rc1swXSkgfX0KICAgIHt7LSBsYXllcjModmxhbikgfX0KICB7JS0gZW5kZm9yICV9CnslLSBlbmRp
ZiAlfQo=
'@

Write-TextFile ([IO.Path]::Combine($TDir, 'template.yaml')) ($TemplateYaml -replace "`n`n$", "`n")
if ($OS -eq 'windows') { $UserData = Expand-Example $WindowsUserData } else { $UserData = Expand-Example $LinuxUserData }
$Examples = @{ 'user-data' = $UserData; 'meta-data' = (Expand-Example $MetaData); 'network-config' = (Expand-Example $NetworkConfig) }
foreach ($f in $OwnFiles.Keys) {
    # your own files are written like the examples: UTF-8 without a byte order mark, LF line endings
    if ($OwnFiles[$f]) { $text = [IO.File]::ReadAllText($OwnFiles[$f]) } else { $text = $Examples[$f] }
    Write-TextFile ([IO.Path]::Combine($TDir, $f)) $text
}
Write-Info "template.yaml, and $(Get-FilesDescription)"
Write-Info "image: $ImageUrl"
Write-Info "boot ISO: $BootIsoUrl"

# ---------------------------------------------------------------------------------------------------------
# Steps 5 and 6: check offline, then create
# ---------------------------------------------------------------------------------------------------------

# metalcloud-cli reads every file under --dir and stops at any folder it can't read, so it gets a temporary
# folder holding only this template, whatever else is in the templates folder
$CliDir = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'golden-template-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
$CliTDir = [IO.Path]::Combine($CliDir, 'golden', $OS, $Label)
New-Item -ItemType Directory -Force -Path $CliTDir | Out-Null
Copy-Item -Path ([IO.Path]::Combine($TDir, '*')) -Destination $CliTDir
try {
    Write-Step 'Step 5: checking the template offline'
    $listing = Invoke-Cli @('os-template', 'list-directory', '--dir', $CliDir)
    if ($listing.Code -ne 0) { Write-Host $listing.Output; Exit-WithError "$Cli os-template list-directory failed" }
    if (-not $listing.Output.Contains($Label)) {
        Exit-WithError "metalcloud-cli doesn't list $RelDir as a template; check $([IO.Path]::Combine($TDir, 'template.yaml'))"
    }
    Write-Info "metalcloud-cli parses $RelDir"

    if ($DryRun) {
        Write-Step 'Dry run: not creating the template. To create it:'
        Write-Info "$Cli os-template create-from-directory $RelDir --dir $(Format-Argument $TemplatesDir)"
        Write-Info '(metalcloud-cli reads every file under --dir: give it a folder that holds only template directories)'
        exit 0
    }

    Write-Step 'Step 6: creating the template'
    $created = Invoke-Cli @('os-template', 'create-from-directory', $RelDir, '--dir', $CliDir)
    if ($created.Output) { Write-Host $created.Output }
    if ($created.Code -ne 0) { Exit-WithError "$Cli os-template create-from-directory failed" }
    Write-Info 'The template is created private. Test it on one server (step 7), then publish it (step 8).'
    Write-Info "List its assets: $Cli os-template get-assets <id>"
} finally {
    Remove-Item -Recurse -Force -LiteralPath $CliDir -ErrorAction SilentlyContinue
}
