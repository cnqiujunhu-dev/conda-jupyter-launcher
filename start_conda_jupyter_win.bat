@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "LAUNCHER_SELF=%~f0"

set "REQUESTED_ENV="
set "DRY_RUN=0"

:parse_args
if "%~1"=="" goto run_launcher

if /I "%~1"=="-EnvName" (
    if "%~2"=="" (
        echo Missing value after -EnvName.
        pause
        exit /b 1
    )
    set "REQUESTED_ENV=%~2"
    shift
    shift
    goto parse_args
)

if /I "%~1"=="-DryRun" (
    set "DRY_RUN=1"
    shift
    goto parse_args
)

shift
goto parse_args

:run_launcher
set "CODEX_JUPYTER_SELF=%LAUNCHER_SELF%"
set "CODEX_JUPYTER_SCRIPT_DIR=%SCRIPT_DIR%"
set "CODEX_JUPYTER_REQUESTED_ENV=%REQUESTED_ENV%"
set "CODEX_JUPYTER_DRY_RUN=%DRY_RUN%"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
  "$self = $env:CODEX_JUPYTER_SELF;" ^
  "$scriptDir = $env:CODEX_JUPYTER_SCRIPT_DIR;" ^
  "$requestedEnv = $env:CODEX_JUPYTER_REQUESTED_ENV;" ^
  "$dryRun = ($env:CODEX_JUPYTER_DRY_RUN -eq '1');" ^
  "$marker = ':__PWSH__';" ^
  "$lines = Get-Content -LiteralPath $self;" ^
  "$start = [Array]::IndexOf($lines, $marker);" ^
  "if ($start -lt 0) { throw 'Embedded PowerShell marker not found.' }" ^
  "$embedded = ($lines[($start + 1)..($lines.Length - 1)] -join [Environment]::NewLine);" ^
  "& ([scriptblock]::Create($embedded)) -ScriptDirectory $scriptDir -EnvName $requestedEnv -DryRun:$dryRun"
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
    echo.
    echo Failed to start Jupyter Notebook.
    pause
)

endlocal
exit /b %EXIT_CODE%

:__PWSH__
param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptDirectory,

    [string]$EnvName,

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Get-JsonPropertyValue {
    param(
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Write-Rule {
    param(
        [int]$Width = 68,

        [ConsoleColor]$Color = [ConsoleColor]::DarkGray,

        [char]$Character = '-'
    )

    Write-Host (($Character.ToString()) * $Width) -ForegroundColor $Color
}

function Write-SectionTitle {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    Write-Host ""
    Write-Host ("[{0}]" -f $Title.ToUpperInvariant()) -ForegroundColor Cyan
    Write-Rule -Width 68 -Color DarkGray
}

function Write-StatusLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Kind,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $normalizedKind = $Kind.ToUpperInvariant()
    $color = switch ($normalizedKind) {
        "OK" { "Green" }
        "WARN" { "Yellow" }
        "ERROR" { "Red" }
        "STEP" { "Cyan" }
        default { "White" }
    }

    Write-Host ("[{0}] {1}" -f $normalizedKind, $Message) -ForegroundColor $color
}

function Write-InfoLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    Write-Host ("{0,-12}: " -f $Label) -NoNewline -ForegroundColor DarkGray
    Write-Host $Value -ForegroundColor White
}

function Show-LauncherHeader {
    try {
        $Host.UI.RawUI.WindowTitle = "Conda Jupyter Launcher"
    }
    catch {
    }

    Write-Host ""
    Write-Rule -Width 68 -Color DarkCyan -Character '='
    $title = "CONDA JUPYTER LAUNCHER"
    $leftPadding = [Math]::Max(0, [int]((68 - $title.Length) / 2))
    Write-Host ((" " * $leftPadding) + $title) -ForegroundColor Cyan
    Write-Rule -Width 68 -Color DarkCyan -Character '='
    Write-InfoLine -Label "Version" -Value "2026.04.19.16"
    Write-InfoLine -Label "Auto Env" -Value "torch_env (Python 3.10)"
}

function Initialize-CondaRuntimeSettings {
    $env:CONDA_NOTIFY_OUTDATED_CONDA = "false"
}

function Normalize-PathValue {
    param(
        [string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $null
    }

    try {
        return ([System.IO.Path]::GetFullPath($PathValue)).TrimEnd("\")
    }
    catch {
        return $PathValue.Trim().TrimEnd("\")
    }
}

function Resolve-CondaCliPaths {
    param(
        [string]$CondaRoot
    )

    return @(
        (Join-Path $CondaRoot "condabin\conda.bat"),
        (Join-Path $CondaRoot "Scripts\conda.bat"),
        (Join-Path $CondaRoot "Scripts\conda.exe"),
        (Join-Path $CondaRoot "_conda.exe")
    ) | Where-Object {
        Test-Path -LiteralPath $_
    } | Select-Object -Unique
}

function Resolve-CondaCliPath {
    param(
        [string]$CondaRoot
    )

    return Resolve-CondaCliPaths -CondaRoot $CondaRoot | Select-Object -First 1
}

function Invoke-CondaJsonCommand {
    param(
        [string]$CondaCommandPath
    )

    if ([string]::IsNullOrWhiteSpace($CondaCommandPath)) {
        return $null
    }

    foreach ($argumentSet in @(
        @("info", "--envs", "--json"),
        @("info", "--json"),
        @("env", "list", "--json")
    )) {
        try {
            $jsonText = & $CondaCommandPath @argumentSet 2>$null | Out-String
        }
        catch {
            continue
        }

        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($jsonText)) {
            continue
        }

        try {
            $json = $jsonText | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            continue
        }

        return [PSCustomObject]@{
            Arguments = $argumentSet
            Text      = $jsonText
            Json      = $json
        }
    }

    return $null
}

function Test-CondaCommand {
    param(
        [string]$CondaCommandPath
    )

    return [bool](Invoke-CondaJsonCommand -CondaCommandPath $CondaCommandPath)
}

function Resolve-CondaActivationPath {
    param(
        [string]$CondaRoot
    )

    foreach ($candidate in @(
        (Join-Path $CondaRoot "Scripts\activate.bat"),
        (Join-Path $CondaRoot "condabin\conda.bat"),
        (Join-Path $CondaRoot "Scripts\conda.bat"),
        (Join-Path $CondaRoot "activate.bat")
    )) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-CondaEnvironmentDetailPath {
    param(
        [object]$Detail
    )

    foreach ($propertyName in @("location", "prefix", "path")) {
        $value = Normalize-PathValue -PathValue (Get-JsonPropertyValue -Object $Detail -Name $propertyName)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    return $null
}

function Get-CondaEnvironmentDetail {
    param(
        [object]$EnvsDetails,

        [string]$EnvironmentPath
    )

    $normalizedPath = Normalize-PathValue -PathValue $EnvironmentPath
    if ([string]::IsNullOrWhiteSpace($normalizedPath) -or $null -eq $EnvsDetails) {
        return $null
    }

    foreach ($lookupPath in @($EnvironmentPath, $normalizedPath)) {
        if ([string]::IsNullOrWhiteSpace($lookupPath)) {
            continue
        }

        $detail = Get-JsonPropertyValue -Object $EnvsDetails -Name $lookupPath
        if ($detail) {
            return $detail
        }
    }

    foreach ($property in @($EnvsDetails.PSObject.Properties)) {
        if ($null -eq $property) {
            continue
        }

        $propertyPath = Normalize-PathValue -PathValue $property.Name
        if ($propertyPath -and ($propertyPath -ieq $normalizedPath)) {
            return $property.Value
        }

        $detailPath = Get-CondaEnvironmentDetailPath -Detail $property.Value
        if ($detailPath -and ($detailPath -ieq $normalizedPath)) {
            return $property.Value
        }
    }

    if ($EnvsDetails -is [System.Collections.IEnumerable] -and -not ($EnvsDetails -is [string])) {
        foreach ($detail in @($EnvsDetails)) {
            $detailPath = Get-CondaEnvironmentDetailPath -Detail $detail
            if ($detailPath -and ($detailPath -ieq $normalizedPath)) {
                return $detail
            }
        }
    }

    return $null
}

function Get-DiscoveredCondaEnvironmentPaths {
    param(
        [object]$Json,

        [string]$CondaRoot
    )

    $candidatePaths = [System.Collections.Generic.List[string]]::new()

    foreach ($propertyName in @("envs", "root_prefix", "default_prefix", "active_prefix")) {
        $value = Get-JsonPropertyValue -Object $Json -Name $propertyName
        if ($null -eq $value) {
            continue
        }

        if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
            foreach ($item in @($value)) {
                if (-not [string]::IsNullOrWhiteSpace($item)) {
                    $candidatePaths.Add([string]$item)
                }
            }

            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $candidatePaths.Add([string]$value)
        }
    }

    $envsDetails = Get-JsonPropertyValue -Object $Json -Name "envs_details"
    if ($null -ne $envsDetails) {
        foreach ($property in @($envsDetails.PSObject.Properties)) {
            if ($null -eq $property) {
                continue
            }

            if (-not [string]::IsNullOrWhiteSpace($property.Name)) {
                $candidatePaths.Add($property.Name)
            }

            $detailPath = Get-CondaEnvironmentDetailPath -Detail $property.Value
            if (-not [string]::IsNullOrWhiteSpace($detailPath)) {
                $candidatePaths.Add($detailPath)
            }
        }

        if ($envsDetails -is [System.Collections.IEnumerable] -and -not ($envsDetails -is [string])) {
            foreach ($detail in @($envsDetails)) {
                $detailPath = Get-CondaEnvironmentDetailPath -Detail $detail
                if (-not [string]::IsNullOrWhiteSpace($detailPath)) {
                    $candidatePaths.Add($detailPath)
                }
            }
        }
    }

    $normalizedCondaRoot = Normalize-PathValue -PathValue $CondaRoot
    if (-not [string]::IsNullOrWhiteSpace($normalizedCondaRoot)) {
        $candidatePaths.Add($normalizedCondaRoot)

        $envsDirectory = Join-Path $normalizedCondaRoot "envs"
        if (Test-Path -LiteralPath $envsDirectory) {
            foreach ($directory in @(Get-ChildItem -LiteralPath $envsDirectory -Directory -ErrorAction SilentlyContinue)) {
                if ($directory -and -not [string]::IsNullOrWhiteSpace($directory.FullName)) {
                    $candidatePaths.Add($directory.FullName)
                }
            }
        }
    }

    return @(
        $candidatePaths |
            ForEach-Object { Normalize-PathValue -PathValue $_ } |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_) -and
                (Resolve-EnvironmentPythonPath -EnvironmentPath $_)
            } |
            Select-Object -Unique
    )
}

function Test-CondaRootLayout {
    param(
        [string]$CondaRoot
    )

    return [bool](
        (Resolve-CondaCliPath -CondaRoot $CondaRoot) -and
        (Resolve-CondaActivationPath -CondaRoot $CondaRoot)
    )
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PathTokenFromText {
    param(
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $quotedMatch = [regex]::Match($Text, '"([^"]+)"')
    if ($quotedMatch.Success) {
        return $quotedMatch.Groups[1].Value
    }

    $pathMatch = [regex]::Match($Text, '([A-Za-z]:\\[^<>|?*"]+)')
    if ($pathMatch.Success) {
        return $pathMatch.Groups[1].Value.Trim()
    }

    return $Text.Trim()
}

function Convert-ToCondaRoot {
    param(
        [string]$Candidate
    )

    $pathValue = Get-PathTokenFromText -Text $Candidate
    if ([string]::IsNullOrWhiteSpace($pathValue)) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $pathValue)) {
        return $null
    }

    $item = Get-Item -LiteralPath $pathValue -ErrorAction SilentlyContinue
    if (-not $item) {
        return $null
    }

    $root = $null

    if ($item.PSIsContainer) {
        $root = $item.FullName
    }
    else {
        $parent = Split-Path -Parent $item.FullName
        $leafName = $item.Name.ToLowerInvariant()
        $parentLeaf = (Split-Path -Leaf $parent).ToLowerInvariant()

        if ($leafName -eq "conda.exe" -and $parentLeaf -eq "scripts") {
            $root = Split-Path -Parent $parent
        }
        elseif ($leafName -eq "_conda.exe") {
            if ($parentLeaf -eq "scripts") {
                $root = Split-Path -Parent $parent
            }
            else {
                $root = $parent
            }
        }
        elseif ($leafName -eq "conda.bat" -and $parentLeaf -in @("condabin", "scripts")) {
            $root = Split-Path -Parent $parent
        }
        elseif ($leafName -eq "activate.bat" -and $parentLeaf -eq "scripts") {
            $root = Split-Path -Parent $parent
        }
        elseif ($leafName -like "uninstall-*.exe") {
            $root = $parent
        }
        elseif (Test-CondaRootLayout -CondaRoot $parent) {
            $root = $parent
        }
    }

    if (-not $root) {
        return $null
    }

    $normalizedRoot = Normalize-PathValue -PathValue $root
    if (Test-CondaRootLayout -CondaRoot $normalizedRoot) {
        return $normalizedRoot
    }

    return $null
}

function Test-CondaInstallation {
    param(
        [string]$CondaRoot
    )

    $normalizedRoot = Convert-ToCondaRoot -Candidate $CondaRoot
    if (-not $normalizedRoot) {
        return $null
    }

    $condaCliCandidates = @(Resolve-CondaCliPaths -CondaRoot $normalizedRoot)
    $condaBatPath = Resolve-CondaActivationPath -CondaRoot $normalizedRoot

    if ($condaCliCandidates.Count -eq 0 -or -not $condaBatPath) {
        return $null
    }

    $verified = $false
    $condaExePath = $null
    foreach ($candidate in $condaCliCandidates) {
        if (Test-CondaCommand -CondaCommandPath $candidate) {
            $condaExePath = $candidate
            $verified = $true
            break
        }
    }

    if (-not $condaExePath) {
        $condaExePath = $condaCliCandidates[0]
    }

    return [PSCustomObject]@{
        Root           = $normalizedRoot
        Exe            = $condaExePath
        Bat            = $condaBatPath
        Verified       = $verified
        ActivationMode = if ((Split-Path -Leaf $condaBatPath).ToLowerInvariant() -eq "conda.bat") { "conda" } else { "activate" }
    }
}

function Resolve-CondaFromPath {
    foreach ($commandName in @("conda.exe", "conda.bat", "conda")) {
        $condaCommand = Get-Command $commandName -ErrorAction SilentlyContinue
        if (-not $condaCommand) {
            continue
        }

        $conda = Test-CondaInstallation -CondaRoot $condaCommand.Source
        if ($conda) {
            return $conda
        }
    }

    return $null
}

function Get-RegistryCondaRoots {
    $roots = [System.Collections.Generic.List[string]]::new()
    $registryPaths = @(
        "Registry::HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall",
        "Registry::HKEY_LOCAL_MACHINE\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall"
    )

    foreach ($registryPath in $registryPaths) {
        if (-not (Test-Path -LiteralPath $registryPath)) {
            continue
        }

        foreach ($subKey in Get-ChildItem -LiteralPath $registryPath -ErrorAction SilentlyContinue) {
            try {
                $item = Get-ItemProperty -LiteralPath $subKey.PSPath -ErrorAction Stop
            }
            catch {
                continue
            }

            $signature = @($item.DisplayName, $item.Publisher) -join " "
            if ($signature -notmatch "Anaconda|Miniconda|Miniforge|Mambaforge|Conda") {
                continue
            }

            foreach ($candidate in @($item.InstallLocation, $item.DisplayIcon, $item.UninstallString, $item.QuietUninstallString)) {
                $root = Convert-ToCondaRoot -Candidate $candidate
                if ($root) {
                    $roots.Add($root)
                }
            }
        }
    }

    return $roots | Select-Object -Unique
}

function Get-CommonCondaRoots {
    $knownDirectoryNames = @(
        "Anaconda",
        "Anaconda3",
        "anaconda",
        "anaconda3",
        "Miniconda",
        "Miniconda3",
        "miniconda",
        "miniconda3",
        "Miniforge",
        "Miniforge3",
        "miniforge",
        "miniforge3",
        "Mambaforge",
        "mambaforge"
    )

    $candidates = @(
        $env:CONDA_EXE,
        $env:CONDA_PREFIX,
        $env:CONDA_PYTHON_EXE,
        (Join-Path $env:USERPROFILE "Anaconda"),
        (Join-Path $env:USERPROFILE "Anaconda3"),
        (Join-Path $env:USERPROFILE "Miniconda"),
        (Join-Path $env:USERPROFILE "Miniconda3"),
        (Join-Path $env:USERPROFILE "miniconda"),
        (Join-Path $env:USERPROFILE "miniforge3"),
        (Join-Path $env:USERPROFILE "mambaforge"),
        (Join-Path $env:LOCALAPPDATA "anaconda"),
        (Join-Path $env:LOCALAPPDATA "anaconda3"),
        (Join-Path $env:LOCALAPPDATA "miniconda"),
        (Join-Path $env:LOCALAPPDATA "miniconda3"),
        (Join-Path $env:LOCALAPPDATA "miniforge3"),
        (Join-Path $env:LOCALAPPDATA "mambaforge"),
        (Join-Path $env:ProgramData "Anaconda"),
        (Join-Path $env:ProgramData "Anaconda3"),
        (Join-Path $env:ProgramData "Miniconda"),
        (Join-Path $env:ProgramData "Miniconda3"),
        (Join-Path $env:ProgramData "miniconda"),
        (Join-Path $env:ProgramData "miniforge3"),
        (Join-Path $env:ProgramData "mambaforge"),
        (Join-Path $env:ProgramFiles "Anaconda"),
        (Join-Path $env:ProgramFiles "Anaconda3"),
        (Join-Path $env:ProgramFiles "Miniconda"),
        (Join-Path $env:ProgramFiles "Miniconda3"),
        (Join-Path $env:ProgramFiles "miniconda"),
        (Join-Path $env:ProgramFiles "miniforge3"),
        (Join-Path $env:ProgramFiles "mambaforge"),
        (Join-Path $env:SystemDrive "Anaconda"),
        (Join-Path $env:SystemDrive "Anaconda3"),
        (Join-Path $env:SystemDrive "Miniconda"),
        (Join-Path $env:SystemDrive "Miniconda3"),
        (Join-Path $env:SystemDrive "miniconda"),
        (Join-Path $env:SystemDrive "miniforge3"),
        (Join-Path $env:SystemDrive "mambaforge")
    ) | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    }

    foreach ($driveRoot in Get-LocalFileSystemDriveRoots) {
        foreach ($directoryName in $knownDirectoryNames) {
            $candidates += Join-Path $driveRoot $directoryName
        }
    }

    $roots = foreach ($candidate in $candidates) {
        Convert-ToCondaRoot -Candidate $candidate
    }

    return $roots | Where-Object { $_ } | Select-Object -Unique
}

function Get-LocalFileSystemDriveRoots {
    $roots = [System.Collections.Generic.List[string]]::new()

    foreach ($letter in [char[]](65..90)) {
        $root = ("{0}:\" -f $letter)
        if (Test-Path -LiteralPath $root) {
            $roots.Add($root.ToUpperInvariant())
        }
    }

    try {
        foreach ($disk in Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop) {
            if ($disk.DriveType -notin @(2, 3)) {
                continue
            }

            $deviceId = [string]$disk.DeviceID
            if ([string]::IsNullOrWhiteSpace($deviceId)) {
                continue
            }

            if ($deviceId -match "^[A-Za-z]:$") {
                $roots.Add(("{0}\" -f $deviceId.ToUpperInvariant()))
            }
        }
    }
    catch {
    }

    foreach ($drive in Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue) {
        if ($drive.Root -match "^[A-Za-z]:\\$") {
            $roots.Add($drive.Root.ToUpperInvariant())
        }
    }

    return $roots | Select-Object -Unique
}

function Add-CondaRootCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Roots,

        [string]$Candidate
    )

    $root = Convert-ToCondaRoot -Candidate $Candidate
    if ($root) {
        $Roots.Add($root)
    }
}

function Add-CondaCandidatesFromContainer {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Roots,

        [Parameter(Mandatory = $true)]
        [string]$ContainerPath,

        [Parameter(Mandatory = $true)]
        [string[]]$DirectoryNames,

        [Parameter(Mandatory = $true)]
        [string[]]$RelativeFileCandidates
    )

    Add-CondaRootCandidate -Roots $Roots -Candidate $ContainerPath

    foreach ($directoryName in $DirectoryNames) {
        $candidateRoot = Join-Path $ContainerPath $directoryName
        Add-CondaRootCandidate -Roots $Roots -Candidate $candidateRoot

        foreach ($relativePath in $RelativeFileCandidates) {
            Add-CondaRootCandidate -Roots $Roots -Candidate (Join-Path $candidateRoot $relativePath)
        }
    }
}

function Add-CondaArtifactsFromInstallationFolder {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Roots,

        [string]$InstallationFolder
    )

    if ([string]::IsNullOrWhiteSpace($InstallationFolder) -or -not (Test-Path -LiteralPath $InstallationFolder -PathType Container)) {
        return
    }

    foreach ($artifactName in @("conda.bat", "activate.bat", "conda.exe", "_conda.exe")) {
        foreach ($file in Get-ChildItem -LiteralPath $InstallationFolder -File -Recurse -Depth 4 -Filter $artifactName -ErrorAction SilentlyContinue) {
            Add-CondaRootCandidate -Roots $Roots -Candidate $file.FullName
        }
    }
}

function Get-DriveScanCondaRoots {
    $roots = [System.Collections.Generic.List[string]]::new()
    $directoryNames = @(
        "Anaconda",
        "Anaconda3",
        "anaconda",
        "anaconda3",
        "Miniconda",
        "Miniconda3",
        "miniconda",
        "miniconda3",
        "Miniforge",
        "Miniforge3",
        "miniforge",
        "miniforge3",
        "Mambaforge",
        "mambaforge"
    )
    $namePattern = "anaconda|miniconda|miniforge|mambaforge"
    $relativeFileCandidates = @(
        "Scripts\conda.bat",
        "Scripts\conda.exe",
        "_conda.exe",
        "condabin\conda.bat",
        "Scripts\activate.bat",
        "activate.bat"
    )

    foreach ($driveRoot in Get-LocalFileSystemDriveRoots) {
        Add-CondaCandidatesFromContainer -Roots $roots -ContainerPath $driveRoot -DirectoryNames $directoryNames -RelativeFileCandidates $relativeFileCandidates

        foreach ($directory in Get-ChildItem -LiteralPath $driveRoot -Directory -ErrorAction SilentlyContinue) {
            Add-CondaCandidatesFromContainer -Roots $roots -ContainerPath $directory.FullName -DirectoryNames $directoryNames -RelativeFileCandidates $relativeFileCandidates

            if ($directory.Name -match $namePattern) {
                Add-CondaRootCandidate -Roots $roots -Candidate $directory.FullName

                foreach ($relativePath in $relativeFileCandidates) {
                    Add-CondaRootCandidate -Roots $roots -Candidate (Join-Path $directory.FullName $relativePath)
                }

                Add-CondaArtifactsFromInstallationFolder -Roots $roots -InstallationFolder $directory.FullName
            }

            foreach ($directoryName in $directoryNames) {
                Add-CondaArtifactsFromInstallationFolder -Roots $roots -InstallationFolder (Join-Path $directory.FullName $directoryName)
            }
        }
    }

    return $roots | Select-Object -Unique
}

function Find-LocalCondaInstallation {
    $candidateRoots = [System.Collections.Generic.List[string]]::new()

    foreach ($root in Get-RegistryCondaRoots) {
        $candidateRoots.Add($root)
    }

    foreach ($root in Get-CommonCondaRoots) {
        $candidateRoots.Add($root)
    }

    foreach ($candidateRoot in ($candidateRoots | Select-Object -Unique)) {
        $conda = Test-CondaInstallation -CondaRoot $candidateRoot
        if ($conda) {
            return $conda
        }
    }

    Write-Host "Checking local drive roots for Anaconda and Miniconda folders..." -ForegroundColor DarkGray
    foreach ($root in Get-DriveScanCondaRoots) {
        $candidateRoots.Add($root)
    }

    foreach ($candidateRoot in ($candidateRoots | Select-Object -Unique)) {
        $conda = Test-CondaInstallation -CondaRoot $candidateRoot
        if ($conda) {
            return $conda
        }
    }

    return $null
}

function Get-CondaPathEntries {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CondaRoot
    )

    return @(
        $CondaRoot,
        (Join-Path $CondaRoot "Scripts"),
        (Join-Path $CondaRoot "Library\bin"),
        (Join-Path $CondaRoot "condabin")
    ) | Where-Object {
        Test-Path -LiteralPath $_
    }
}

function Add-PathEntries {
    param(
        [string]$BasePath,

        [string[]]$EntriesToAdd
    )

    $segments = @()
    if (-not [string]::IsNullOrWhiteSpace($BasePath)) {
        $segments = $BasePath -split ";" | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }
    }

    $known = @{}
    foreach ($segment in $segments) {
        $normalizedSegment = (Normalize-PathValue -PathValue $segment).ToLowerInvariant()
        if (-not $known.ContainsKey($normalizedSegment)) {
            $known[$normalizedSegment] = $segment
        }
    }

    $added = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $EntriesToAdd) {
        $normalizedEntry = (Normalize-PathValue -PathValue $entry).ToLowerInvariant()
        if ($known.ContainsKey($normalizedEntry)) {
            continue
        }

        $segments += $entry
        $known[$normalizedEntry] = $entry
        $added.Add($entry)
    }

    return [PSCustomObject]@{
        Path  = $segments -join ";"
        Added = @($added)
    }
}

function Update-SessionPath {
    param(
        [string[]]$EntriesToAdd
    )

    $sessionUpdate = Add-PathEntries -BasePath $env:Path -EntriesToAdd $EntriesToAdd
    $env:Path = $sessionUpdate.Path
    return $sessionUpdate
}

function Notify-EnvironmentChange {
    if (-not ("Codex.NativeMethods" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace Codex {
    public static class NativeMethods {
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd,
            uint Msg,
            IntPtr wParam,
            string lParam,
            uint fuFlags,
            uint uTimeout,
            out IntPtr lpdwResult
        );
    }
}
"@ | Out-Null
    }

    $result = [IntPtr]::Zero
    [void][Codex.NativeMethods]::SendMessageTimeout(
        [IntPtr]0xffff,
        0x001A,
        [IntPtr]::Zero,
        "Environment",
        0x0002,
        5000,
        [ref]$result
    )
}

function Ensure-CondaAvailable {
    $conda = Resolve-CondaFromPath
    if ($conda) {
        return $conda
    }

    Write-SectionTitle -Title "Conda Setup"
    Write-StatusLine -Kind "Warn" -Message "Conda is not available in PATH. Trying to locate a local installation."

    $conda = Find-LocalCondaInstallation
    if (-not $conda) {
        throw "No local Conda installation was found. Please install Anaconda or Miniconda first."
    }

    Write-StatusLine -Kind "OK" -Message ("Found local Conda installation: {0}" -f $conda.Root)

    $pathEntries = Get-CondaPathEntries -CondaRoot $conda.Root
    [void](Update-SessionPath -EntriesToAdd $pathEntries)

    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $machineUpdate = Add-PathEntries -BasePath $machinePath -EntriesToAdd $pathEntries

    if ($machineUpdate.Added.Count -eq 0) {
        Write-StatusLine -Kind "OK" -Message "Conda is already registered in the machine PATH."
        return $conda
    }

    if ($DryRun) {
        Write-StatusLine -Kind "Warn" -Message ("Dry run: would append these entries to the machine PATH: {0}" -f ($machineUpdate.Added -join "; "))
        return $conda
    }

    if (Test-IsAdministrator) {
        [Environment]::SetEnvironmentVariable("Path", $machineUpdate.Path, "Machine")
        Notify-EnvironmentChange
        Write-StatusLine -Kind "OK" -Message "Conda has been added to the machine PATH."
    }
    else {
        Write-StatusLine -Kind "Warn" -Message "Conda was found locally, but machine PATH can only be updated when this launcher is run as Administrator."
        Write-StatusLine -Kind "Warn" -Message "Continuing with a temporary PATH for this run."
    }

    return $conda
}

function Get-CondaEnvironments {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CondaExePath,

        [Parameter(Mandatory = $true)]
        [string]$CondaRoot,

        [switch]$PreviewOnly
    )

    $jsonResult = Invoke-CondaJsonCommand -CondaCommandPath $CondaExePath
    if (-not $jsonResult) {
        throw "Failed to read the conda environment list."
    }

    $json = $jsonResult.Json
    $condaRoot = Normalize-PathValue -PathValue $CondaRoot
    $activePrefix = Normalize-PathValue -PathValue $env:CONDA_PREFIX
    $envsDetails = Get-JsonPropertyValue -Object $json -Name "envs_details"
    $envPaths = @(Get-DiscoveredCondaEnvironmentPaths -Json $json -CondaRoot $condaRoot)

    if ($envPaths.Count -eq 0) {
        $rootPythonPath = Resolve-EnvironmentPythonPath -EnvironmentPath $condaRoot
        if ($rootPythonPath) {
            Write-Host "No conda environments were listed. Using the Conda root as base." -ForegroundColor Yellow
            return ,([PSCustomObject]@{
                Name   = "base"
                Path   = $condaRoot
                Active = [bool]($activePrefix -and ($condaRoot -ieq $activePrefix))
                Base   = $true
            })
        }

        $fallbackBasePath = Normalize-PathValue -PathValue (Join-Path $condaRoot "envs\base")
        if ($PreviewOnly) {
            Write-Host "Dry run: would create a base environment because no conda environments were found." -ForegroundColor Yellow
            return ,([PSCustomObject]@{
                Name   = "base"
                Path   = $fallbackBasePath
                Active = $false
                Base   = $true
            })
        }

        Write-Host "No conda environments were found. Creating a base environment..." -ForegroundColor Yellow
        & $CondaExePath create --yes --name base python
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create a base environment."
        }

        if (Resolve-EnvironmentPythonPath -EnvironmentPath $fallbackBasePath) {
            return ,([PSCustomObject]@{
                Name   = "base"
                Path   = $fallbackBasePath
                Active = $false
                Base   = $true
            })
        }

        throw "No conda environments were found."
    }

    $environments = foreach ($path in $envPaths) {
        $normalizedPath = Normalize-PathValue -PathValue $path
        if ([string]::IsNullOrWhiteSpace($normalizedPath)) {
            continue
        }

        $detail = Get-CondaEnvironmentDetail -EnvsDetails $envsDetails -EnvironmentPath $normalizedPath
        $isBase = [bool](
            ($detail -and $detail.base) -or
            ($normalizedPath -and $condaRoot -and ($normalizedPath -ieq $condaRoot)) -or
            ($normalizedPath -and ($normalizedPath -ieq (Normalize-PathValue -PathValue (Join-Path $condaRoot "envs\base"))))
        )
        $isActive = [bool](($detail -and $detail.active) -or ($normalizedPath -and $activePrefix -and ($normalizedPath -ieq $activePrefix)))
        $environmentName = if ($detail -and $detail.name) {
            $detail.name
        }
        elseif ($isBase) {
            "base"
        }
        else {
            Split-Path -Leaf $normalizedPath
        }

        [PSCustomObject]@{
            Name   = $environmentName
            Path   = $normalizedPath
            Active = $isActive
            Base   = $isBase
        }
    }

    $environments = @(Repair-CondaEnvironmentList -Environments $environments -CondaRoot $condaRoot -AllowMissingPython:$PreviewOnly)

    if (-not $environments) {
        throw "No conda environments were found."
    }

    return ,$environments
}

function Ensure-TorchEnvironmentExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CondaExePath,

        [Parameter(Mandatory = $true)]
        [string]$CondaRoot,

        [Parameter(Mandatory = $true)]
        [array]$Environments,

        [switch]$PreviewOnly
    )

    $Environments = @(Repair-CondaEnvironmentList -Environments $Environments -CondaRoot $CondaRoot -AllowMissingPython:$PreviewOnly)

    $torchEnvironment = $Environments | Where-Object {
        $_.Name -ieq "torch_env" -or (Normalize-PathValue -PathValue $_.Path) -ieq (Normalize-PathValue -PathValue (Join-Path $CondaRoot "envs\torch_env"))
    } | Select-Object -First 1

    if ($torchEnvironment) {
        return ,$Environments
    }

    $torchEnvironmentPath = Normalize-PathValue -PathValue (Join-Path $CondaRoot "envs\torch_env")

    if ($PreviewOnly) {
        Write-StatusLine -Kind "Warn" -Message "Dry run: would ask whether to create environment 'torch_env' with Python 3.10."
        return ,$Environments
    }

    Write-SectionTitle -Title "Environment Setup"
    Write-StatusLine -Kind "Warn" -Message "Environment 'torch_env' was not found."
    while ($true) {
        $createChoice = Read-Host "Create torch_env now? (y/n)"

        if ($createChoice -match "^[Yy]$") {
            break
        }

        if ($createChoice -match "^[Nn]$") {
            Write-StatusLine -Kind "Warn" -Message "Skipped creating 'torch_env'."
            return ,$Environments
        }

        Write-StatusLine -Kind "Warn" -Message "Invalid selection. Please enter y or n."
    }

    Write-StatusLine -Kind "Step" -Message "Creating environment 'torch_env' with Python 3.10."
    Write-Host "Please wait. Conda may need a few minutes to solve packages." -ForegroundColor DarkGray
    $createResult = Invoke-ProcessWithProgress -FilePath $CondaExePath -Arguments @("create", "--yes", "--name", "torch_env", "python=3.10") -Activity "Creating torch_env" -CurrentOperation "Solving environment"
    if ($createResult.ExitCode -ne 0) {
        throw "Failed to create environment 'torch_env'."
    }

    $refreshedEnvironments = @($Environments) + @(Get-CondaEnvironments -CondaExePath $CondaExePath -CondaRoot $CondaRoot -PreviewOnly:$PreviewOnly)
    $refreshedEnvironments = @(Repair-CondaEnvironmentList -Environments $refreshedEnvironments -CondaRoot $CondaRoot -AllowMissingPython:$PreviewOnly)
    $torchEnvironment = $refreshedEnvironments | Where-Object {
        $_.Name -ieq "torch_env" -or (Normalize-PathValue -PathValue $_.Path) -ieq $torchEnvironmentPath
    } | Select-Object -First 1

    if (-not $torchEnvironment -and (Resolve-EnvironmentPythonPath -EnvironmentPath $torchEnvironmentPath)) {
        $refreshedEnvironments += [PSCustomObject]@{
            Name   = "torch_env"
            Path   = $torchEnvironmentPath
            Active = $false
            Base   = $false
        }
    }

    $refreshedEnvironments = @(Repair-CondaEnvironmentList -Environments $refreshedEnvironments -CondaRoot $CondaRoot -AllowMissingPython:$PreviewOnly)
    if (-not $refreshedEnvironments) {
        throw "No valid conda environments were found after creating 'torch_env'."
    }

    return ,$refreshedEnvironments
}

function Select-CondaEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Environments,

        [string]$RequestedName
    )

    $Environments = @($Environments | Where-Object {
        $null -ne $_ -and -not [string]::IsNullOrWhiteSpace((Normalize-PathValue -PathValue $_.Path))
    })

    if (-not $Environments) {
        throw "No valid conda environments are available to select."
    }

    if ($RequestedName) {
        $selected = $Environments | Where-Object {
            $_.Name -ieq $RequestedName -or $_.Path -ieq $RequestedName
        } | Select-Object -First 1

        if (-not $selected) {
            throw "Environment '$RequestedName' was not found."
        }

        return $selected
    }

    Write-SectionTitle -Title "Environments"
    Write-Host "Please enter a number to select the corresponding environment" -ForegroundColor White

    $maxNameLength = ($Environments | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_.Name)) {
            0
        }
        else {
            $_.Name.Length
        }
    } | Measure-Object -Maximum).Maximum
    if (-not $maxNameLength) {
        $maxNameLength = 0
    }

    for ($i = 0; $i -lt $Environments.Count; $i++) {
        $environment = $Environments[$i]
        $displayName = if ([string]::IsNullOrWhiteSpace($environment.Name)) {
            $fallbackName = if ([string]::IsNullOrWhiteSpace($environment.Path)) {
                $null
            }
            else {
                Split-Path -Leaf $environment.Path
            }
            if ([string]::IsNullOrWhiteSpace($fallbackName)) {
                "unknown"
            }
            else {
                $fallbackName
            }
        }
        else {
            $environment.Name
        }
        $marker = if ($environment.Active) { ">" } else { " " }
        $statusBadge = if ($environment.Active) { " [ACTIVE]" } elseif ($environment.Base) { " [BASE]" } else { "" }
        $statusColor = if ($environment.Active) { "Green" } elseif ($environment.Base) { "DarkYellow" } else { "DarkGray" }

        Write-Host " $marker " -NoNewline -ForegroundColor DarkGray
        Write-Host ("[{0}]" -f ($i + 1).ToString().PadLeft(2, " ")) -NoNewline -ForegroundColor Cyan
        Write-Host " " -NoNewline
        Write-Host (" {0} " -f $displayName.PadRight($maxNameLength, " ")) -NoNewline -ForegroundColor Black -BackgroundColor DarkCyan
        if ($statusBadge) {
            Write-Host $statusBadge -NoNewline -ForegroundColor $statusColor
        }
        Write-Host ""
        Write-Host ("      {0}" -f $environment.Path) -ForegroundColor DarkGray
        Write-Host ""
    }

    $defaultIndex = -1
    for ($i = 0; $i -lt $Environments.Count; $i++) {
        if ($Environments[$i].Active) {
            $defaultIndex = $i
            break
        }
    }

    $prompt = if ($defaultIndex -ge 0) {
        "Select a number (Enter = {0}, q = quit)" -f ($defaultIndex + 1)
    } else {
        "Select a number (q = quit)"
    }

    while ($true) {
        $inputValue = Read-Host $prompt

        if ([string]::IsNullOrWhiteSpace($inputValue)) {
            if ($defaultIndex -ge 0) {
                return $Environments[$defaultIndex]
            }
        }

        if ($inputValue -match "^[Qq]$") {
            exit 0
        }

        $choice = 0
        if ([int]::TryParse($inputValue, [ref]$choice) -and $choice -ge 1 -and $choice -le $Environments.Count) {
            return $Environments[$choice - 1]
        }

        Write-Host "Invalid selection. Try again." -ForegroundColor Yellow
    }
}

function Resolve-EnvironmentPythonPath {
    param(
        [string]$EnvironmentPath
    )

    $normalizedPath = Normalize-PathValue -PathValue $EnvironmentPath
    if ([string]::IsNullOrWhiteSpace($normalizedPath)) {
        return $null
    }

    foreach ($candidate in @(
        (Join-Path $normalizedPath "python.exe"),
        (Join-Path $normalizedPath "python")
    )) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Repair-CondaEnvironmentList {
    param(
        [array]$Environments,

        [string]$CondaRoot,

        [switch]$AllowMissingPython
    )

    $normalizedCondaRoot = Normalize-PathValue -PathValue $CondaRoot
    $normalizedFallbackBasePath = if ($normalizedCondaRoot) {
        Normalize-PathValue -PathValue (Join-Path $normalizedCondaRoot "envs\base")
    }
    else {
        $null
    }

    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $repairedEnvironments = [System.Collections.Generic.List[object]]::new()

    foreach ($environment in @($Environments)) {
        if ($null -eq $environment) {
            continue
        }

        $path = Normalize-PathValue -PathValue $environment.Path
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }

        if (-not $AllowMissingPython -and -not (Resolve-EnvironmentPythonPath -EnvironmentPath $path)) {
            continue
        }

        if (-not $seenPaths.Add($path)) {
            continue
        }

        $isBase = [bool](
            $environment.Base -or
            ($normalizedCondaRoot -and ($path -ieq $normalizedCondaRoot)) -or
            ($normalizedFallbackBasePath -and ($path -ieq $normalizedFallbackBasePath))
        )
        $name = $environment.Name
        if ([string]::IsNullOrWhiteSpace($name)) {
            if ($isBase) {
                $name = "base"
            }
            else {
                $name = Split-Path -Leaf $path
            }
        }

        $repairedEnvironments.Add([PSCustomObject]@{
            Name   = $name
            Path   = $path
            Active = [bool]$environment.Active
            Base   = $isBase
        })
    }

    return @($repairedEnvironments)
}

function Get-ProcessArgumentLiteral {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return '""'
    }

    if ($Value -match '^[A-Za-z0-9_:\\\./=-]+$') {
        return $Value
    }

    return '"' + ($Value -replace '"', '""') + '"'
}

function Invoke-ProcessWithProgress {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$Arguments = @(),

        [Parameter(Mandatory = $true)]
        [string]$Activity,

        [Parameter(Mandatory = $true)]
        [string]$CurrentOperation,

        [switch]$Quiet
    )

    $resolvedFilePath = Normalize-PathValue -PathValue $FilePath
    $startFile = $resolvedFilePath
    $argumentLine = (($Arguments | ForEach-Object { Get-ProcessArgumentLiteral -Value $_ }) -join " ").Trim()

    if ($resolvedFilePath -match '\.(bat|cmd)$') {
        $startFile = $env:ComSpec
        $commandLine = "call {0}" -f (Get-ProcessArgumentLiteral -Value $resolvedFilePath)
        if (-not [string]::IsNullOrWhiteSpace($argumentLine)) {
            $commandLine = "{0} {1}" -f $commandLine, $argumentLine
        }

        $argumentLine = "/d /c {0}" -f $commandLine
    }

    $process = Start-Process -FilePath $startFile -ArgumentList $argumentLine -PassThru -NoNewWindow -Wait

    $script:LASTEXITCODE = $process.ExitCode

    return [PSCustomObject]@{
        ExitCode = $process.ExitCode
        StdOut   = ""
        StdErr   = ""
    }
}

function Invoke-CondaInstall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CondaExePath,

        [Parameter(Mandatory = $true)]
        [string]$EnvironmentPath,

        [Parameter(Mandatory = $true)]
        [string[]]$Packages,

        [string[]]$Channels = @("pytorch", "conda-forge", "defaults"),

        [switch]$Quiet
    )

    if (-not $Packages -or $Packages.Count -eq 0) {
        return $true
    }

    $arguments = @("install", "--yes", "--prefix", $EnvironmentPath)
    foreach ($channel in $Channels) {
        if (-not [string]::IsNullOrWhiteSpace($channel)) {
            $arguments += @("-c", $channel)
        }
    }
    $arguments += $Packages

    if ($Quiet) {
        & $CondaExePath @arguments *> $null
        return ($LASTEXITCODE -eq 0)
    }

    $result = Invoke-ProcessWithProgress -FilePath $CondaExePath -Arguments $arguments -Activity "Installing packages with Conda" -CurrentOperation "Downloading packages"
    return ($result.ExitCode -eq 0)
}

function Install-PipWithBootstrap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PythonPath
    )

    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("get-pip-{0}.py" -f [guid]::NewGuid().ToString("N"))

    try {
        Invoke-WebRequest -Uri "https://bootstrap.pypa.io/get-pip.py" -OutFile $tempFile -UseBasicParsing
        & $PythonPath $tempFile
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
    finally {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
}

function Ensure-PipAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CondaExePath,

        [Parameter(Mandatory = $true)]
        [string]$EnvironmentPath
    )

    $pythonPath = Resolve-EnvironmentPythonPath -EnvironmentPath $EnvironmentPath
    if (-not $pythonPath) {
        return $false
    }

    & $pythonPath -m pip --version *> $null
    if ($LASTEXITCODE -eq 0) {
        return $true
    }

    if (Invoke-CondaInstall -CondaExePath $CondaExePath -EnvironmentPath $EnvironmentPath -Packages @("pip") -Channels @("conda-forge", "defaults") -Quiet) {
        & $pythonPath -m pip --version *> $null
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
    }

    & $pythonPath -m ensurepip --upgrade *> $null
    if ($LASTEXITCODE -eq 0) {
        & $pythonPath -m pip --version *> $null
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
    }

    if (Install-PipWithBootstrap -PythonPath $pythonPath) {
        & $pythonPath -m pip --version *> $null
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
    }

    return $false
}

function Test-PythonModuleInEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CondaExePath,

        [Parameter(Mandatory = $true)]
        [string]$EnvironmentName,

        [Parameter(Mandatory = $true)]
        [string]$EnvironmentPath,

        [Parameter(Mandatory = $true)]
        [string]$ModuleName
    )

    $pythonCode = "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('$ModuleName') else 1)"
    $pythonPath = Resolve-EnvironmentPythonPath -EnvironmentPath $EnvironmentPath
    $previousErrorActionPreference = $ErrorActionPreference
    $restoreNativePreference = $false

    if (-not $pythonPath) {
        return $false
    }

    if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
        $previousNativePreference = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
        $restoreNativePreference = $true
    }

    $ErrorActionPreference = "Continue"

    try {
        & $pythonPath -c $pythonCode *> $null
        return ($LASTEXITCODE -eq 0)
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference

        if ($restoreNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $previousNativePreference
        }
    }
}

function Ensure-RequiredPythonPackages {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CondaExePath,

        [Parameter(Mandatory = $true)]
        [string]$EnvironmentName,

        [Parameter(Mandatory = $true)]
        [string]$EnvironmentPath,

        [switch]$PreviewOnly
    )

    $requirements = @(
        [PSCustomObject]@{
            Label        = "pandas"
            Module       = "pandas"
            CondaPackage = "pandas"
            PipPackage   = "pandas"
        },
        [PSCustomObject]@{
            Label        = "scikit-learn"
            Module       = "sklearn"
            CondaPackage = "scikit-learn"
            PipPackage   = "scikit-learn"
        },
        [PSCustomObject]@{
            Label        = "jupyter notebook"
            Module       = "notebook"
            CondaPackage = "notebook"
            PipPackage   = "notebook"
        },
        [PSCustomObject]@{
            Label        = "torch"
            Module       = "torch"
            CondaPackage = "pytorch"
            PipPackage   = "torch"
        },
        [PSCustomObject]@{
            Label        = "torchvision"
            Module       = "torchvision"
            CondaPackage = "torchvision"
            PipPackage   = "torchvision"
        },
        [PSCustomObject]@{
            Label        = "torchaudio"
            Module       = "torchaudio"
            CondaPackage = "torchaudio"
            PipPackage   = "torchaudio"
        }
    )

    $missingRequirements = [System.Collections.Generic.List[object]]::new()

    Write-SectionTitle -Title "Dependencies"
    Write-InfoLine -Label "Environment" -Value $EnvironmentName

    foreach ($requirement in $requirements) {
        Write-StatusLine -Kind "Step" -Message ("Checking package: {0}" -f $requirement.Label)

        if (Test-PythonModuleInEnvironment -CondaExePath $CondaExePath -EnvironmentName $EnvironmentName -EnvironmentPath $EnvironmentPath -ModuleName $requirement.Module) {
            Write-StatusLine -Kind "OK" -Message ("Detected package: {0}" -f $requirement.Label)
            continue
        }

        Write-StatusLine -Kind "Warn" -Message ("Package not found: {0}" -f $requirement.Label)
        $missingRequirements.Add($requirement)
    }

    if ($missingRequirements.Count -eq 0) {
        return
    }

    $missingCondaPackages = @($missingRequirements | ForEach-Object { $_.CondaPackage })
    $missingPipPackages = @($missingRequirements | ForEach-Object { $_.PipPackage })
    $missingLabels = @($missingRequirements | ForEach-Object { $_.Label })

    if ($PreviewOnly) {
        Write-StatusLine -Kind "Warn" -Message ("Dry run: would ask whether to install missing packages: {0}" -f ($missingLabels -join ", "))
        return
    }

    while ($true) {
        $installChoice = Read-Host ("Install missing packages now? (y/n) [{0}]" -f ($missingLabels -join ", "))

        if ($installChoice -match "^[Yy]$") {
            break
        }

        if ($installChoice -match "^[Nn]$") {
            Write-StatusLine -Kind "Warn" -Message "Skipped installing missing packages."
            return
        }

        Write-StatusLine -Kind "Warn" -Message "Invalid selection. Please enter y or n."
    }

    Write-StatusLine -Kind "Step" -Message ("Downloading and installing missing packages with conda: {0}" -f ($missingCondaPackages -join ", "))
    if (-not (Invoke-CondaInstall -CondaExePath $CondaExePath -EnvironmentPath $EnvironmentPath -Packages $missingCondaPackages)) {
        $pythonPath = Resolve-EnvironmentPythonPath -EnvironmentPath $EnvironmentPath
        if (-not $pythonPath) {
            throw "Python was not found in environment '$EnvironmentName'."
        }

        Write-StatusLine -Kind "Warn" -Message "Conda install failed. Downloading and installing with pip instead."
        if (-not (Ensure-PipAvailable -CondaExePath $CondaExePath -EnvironmentPath $EnvironmentPath)) {
            throw "Failed to prepare pip in environment '$EnvironmentName'."
        }
        $pipResult = Invoke-ProcessWithProgress -FilePath $pythonPath -Arguments (@("-m", "pip", "install") + $missingPipPackages) -Activity "Installing packages with pip" -CurrentOperation "Downloading packages"

        if ($pipResult.ExitCode -ne 0) {
            throw "Failed to install required packages: $($missingPipPackages -join ', ')"
        }
    }

    foreach ($requirement in $missingRequirements) {
        if (Test-PythonModuleInEnvironment -CondaExePath $CondaExePath -EnvironmentName $EnvironmentName -EnvironmentPath $EnvironmentPath -ModuleName $requirement.Module) {
            Write-StatusLine -Kind "OK" -Message ("Detected package: {0}" -f $requirement.Label)
            continue
        }

        throw "Package verification failed after installation: $($requirement.Label)"
    }
}

function Start-CondaJupyterNotebook {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CondaBatPath,

        [Parameter(Mandatory = $true)]
        [string]$ActivationMode,

        [Parameter(Mandatory = $true)]
        [string]$EnvironmentName,

        [Parameter(Mandatory = $true)]
        [string]$EnvironmentPath,

        [Parameter(Mandatory = $true)]
        [string]$ProjectDirectory,

        [switch]$PreviewOnly
    )

    $activationTarget = if ([string]::IsNullOrWhiteSpace($EnvironmentPath)) { $EnvironmentName } else { $EnvironmentPath }
    $activationCommand = if ($ActivationMode -eq "activate") {
        "call `"{2}`" `"{1}`" && "
    }
    else {
        "call `"{2}`" activate `"{1}`" && "
    }

    $commandChain = (
        "title Jupyter Notebook - {0} && " +
        $activationCommand +
        "cd /d `"{3}`" && " +
        "python -m notebook || jupyter notebook || " +
        "(echo. & echo Failed to start Jupyter Notebook in `"{0}`". & echo Install notebook or jupyter in that environment and try again. & pause)"
    ) -f $EnvironmentName, $activationTarget, $CondaBatPath, $ProjectDirectory

    if ($PreviewOnly) {
        Write-SectionTitle -Title "Launch"
        Write-InfoLine -Label "Environment" -Value $EnvironmentName
        Write-InfoLine -Label "Directory" -Value $ProjectDirectory
        Write-StatusLine -Kind "Step" -Message "Waiting for Jupyter Notebook to open."
        Write-Host ("Preview command: cmd.exe /k {0}" -f $commandChain) -ForegroundColor DarkGray
        return
    }

    Write-SectionTitle -Title "Launch"
    Write-InfoLine -Label "Environment" -Value $EnvironmentName
    Write-InfoLine -Label "Directory" -Value $ProjectDirectory
    Write-StatusLine -Kind "Step" -Message "Waiting for Jupyter Notebook to open."
    Write-Rule -Width 68 -Color DarkGray

    & cmd.exe /k $commandChain
}

try {
    Initialize-CondaRuntimeSettings
    Show-LauncherHeader
    $conda = Ensure-CondaAvailable
    $environments = Get-CondaEnvironments -CondaExePath $conda.Exe -CondaRoot $conda.Root -PreviewOnly:$DryRun
    $environments = Ensure-TorchEnvironmentExists -CondaExePath $conda.Exe -CondaRoot $conda.Root -Environments $environments -PreviewOnly:$DryRun
    $selectedEnvironment = Select-CondaEnvironment -Environments $environments -RequestedName $EnvName
    Ensure-RequiredPythonPackages -CondaExePath $conda.Exe -EnvironmentName $selectedEnvironment.Name -EnvironmentPath $selectedEnvironment.Path -PreviewOnly:$DryRun

    Write-StatusLine -Kind "OK" -Message ("Launching Jupyter Notebook with conda environment: {0}" -f $selectedEnvironment.Name)

    Start-CondaJupyterNotebook -CondaBatPath $conda.Bat -ActivationMode $conda.ActivationMode -EnvironmentName $selectedEnvironment.Name -EnvironmentPath $selectedEnvironment.Path -ProjectDirectory $ScriptDirectory -PreviewOnly:$DryRun
}
catch {
    Write-Host ""
    Write-StatusLine -Kind "Error" -Message $_.Exception.Message
    exit 1
}
