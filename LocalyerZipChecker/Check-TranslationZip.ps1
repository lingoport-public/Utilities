#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies a Lingoport return-translation zip file (One Zip per Locale).
    Spec: https://wiki.lingoport.com/Zip_Files_For_Prep_and_Import

.PARAMETER ZipPath
    Path to the zip file to validate.

.PARAMETER ExpectedFiles
    Optional filenames that must exist inside the archive.

.EXAMPLE
    .\Check-TranslationZip.ps1 -ZipPath Queens.Champions.1.fr_fr.zip

.EXAMPLE
    .\Check-TranslationZip.ps1 -ZipPath Queens.Champions.1.fr_fr.zip \
        -ExpectedFiles resources_en.properties,messages.resx,errors.json

.NOTES
    Requires PowerShell 5.1+ on Windows. No third-party tools needed.
    Exit 0 = all checks passed.  Exit 1 = one or more checks failed.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true,  Position = 0)]
    [string]$ZipPath,

    [Parameter(Mandatory = $false, Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$ExpectedFiles = @()
)

Add-Type -AssemblyName System.IO.Compression.FileSystem

# -------------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------------
$script:ErrorCount = 0

function Write-Pass   ([string]$Msg) { Write-Host "  [PASS]  $Msg" -ForegroundColor Green  }
function Write-Fail   ([string]$Msg) { Write-Host "  [FAIL]  $Msg" -ForegroundColor Red; $script:ErrorCount++ }
function Write-Info   ([string]$Msg) { Write-Host "  [INFO]  $Msg" -ForegroundColor Cyan   }
function Write-Warn   ([string]$Msg) { Write-Host "  [WARN]  $Msg" -ForegroundColor Yellow }
function Write-Section([string]$Msg) { Write-Host "`n--- $Msg ---" -ForegroundColor White   }

# Return the top-level folder name from a zip entry path.
# Handles both forward-slash and backslash separators.
function Get-TopLevel {
    param([string]$EntryPath)
    $normalized = $EntryPath.Replace([char]92, [char]47)  # backslash -> forward-slash
    $idx = $normalized.IndexOf([char]47)                  # find first forward-slash
    if ($idx -le 0) { return $normalized }                # no slash: root-level file
    return $normalized.Substring(0, $idx)
}

# Return the bare filename from a zip entry path (part after last slash).
function Get-EntryName {
    param([string]$EntryPath)
    $normalized = $EntryPath.Replace([char]92, [char]47)
    $idx = $normalized.LastIndexOf([char]47)
    if ($idx -lt 0) { return $normalized }
    return $normalized.Substring($idx + 1)
}

# Normalize separators only (returns plain string).
function Normalize-Path {
    param([string]$EntryPath)
    return $EntryPath.Replace([char]92, [char]47)
}

# -------------------------------------------------------------------------
# Banner
# -------------------------------------------------------------------------
Write-Host ('=' * 56) -ForegroundColor White
Write-Host ' Lingoport Return-Translation Zip Checker' -ForegroundColor White
Write-Host " File : $ZipPath"                          -ForegroundColor White
Write-Host ('=' * 56) -ForegroundColor White

# =========================================================================
# CHECK 1 - File exists and is readable
# =========================================================================
Write-Section 'CHECK 1: File existence'

if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
    Write-Fail "File not found: $ZipPath"
    exit 1
}
Write-Pass "File exists: $ZipPath"

# =========================================================================
# CHECK 2 - File is a valid zip archive
# =========================================================================
Write-Section 'CHECK 2: Valid zip archive'

$zip = $null
try {
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $ZipPath).Path)
    Write-Pass 'Archive opened successfully (valid zip)'
}
catch {
    Write-Fail "File is not a valid zip archive: $_"
    exit 1
}

# Build a plain ArrayList of normalized entry paths (guaranteed [string]).
$allEntries = New-Object System.Collections.ArrayList
foreach ($entry in $zip.Entries) {
    $raw  = $entry.FullName          # property returns System.String
    $norm = Normalize-Path $raw      # backslash -> forward-slash
    [void]$allEntries.Add($norm)
}
$zip.Dispose()

Write-Info "First entry (normalized): $($allEntries[0])"

# =========================================================================
# CHECK 3 - Filename convention: group.project.version.locale.zip
#           version must be numeric; locale must use underscore not hyphen
# =========================================================================
Write-Section 'CHECK 3: Zip filename convention'

$basename = Split-Path $ZipPath -Leaf
$stem     = [System.IO.Path]::GetFileNameWithoutExtension($basename)
$ext      = [System.IO.Path]::GetExtension($basename)

if ($ext -cne '.zip') {
    Write-Fail "Filename does not end with '.zip' (case-sensitive): $basename"
} else {
    Write-Pass "Extension is '.zip'"
}

$parts = $stem.Split('.')

if ($parts.Count -lt 4) {
    Write-Fail "Filename needs at least 4 dot-separated segments (group.project.version.locale): $stem"
} else {
    $group   = $parts[0]
    $project = $parts[1]
    $version = $parts[2]
    $locale  = [string]::Join('.', $parts[3..($parts.Count - 1)])

    Write-Info "Parsed  group=$group  project=$project  version=$version  locale=$locale"

    if ($group)   { Write-Pass "group-name present: $group"     } else { Write-Fail 'group-name segment is empty'   }
    if ($project) { Write-Pass "project-name present: $project" } else { Write-Fail 'project-name segment is empty' }

    if ($version -match '^[0-9]+$') {
        Write-Pass "kit-version is numeric: $version"
    } else {
        Write-Fail "kit-version should be numeric, got: '$version'"
    }

    if ($locale) {
        Write-Pass "locale segment present: $locale"
    } else {
        Write-Fail 'locale segment is empty'
    }

    if ($locale.IndexOf('-') -ge 0) {
        Write-Fail "locale uses hyphen instead of underscore: '$locale' (spec requires underscore)"
    } else {
        Write-Pass "locale uses underscore separator (or is single-segment): $locale"
    }
}

# =========================================================================
# CHECK 4 - Exactly one top-level directory, named identically to the stem
# =========================================================================
Write-Section 'CHECK 4: Single top-level directory'

Write-Info "Total entries in archive: $($allEntries.Count)"

$topHash = @{}
foreach ($e in $allEntries) {
    $tl = Get-TopLevel $e
    $topHash[$tl] = 1
}

$actualTld = ''

if ($topHash.Count -eq 0) {
    Write-Fail 'Could not determine any top-level directory in the archive'
} elseif ($topHash.Count -gt 1) {
    $names = ($topHash.Keys | Sort-Object) -join ', '
    Write-Fail "Archive has $($topHash.Count) top-level entries; expected 1. Found: $names"
} else {
    $actualTld = [string]($topHash.Keys | Select-Object -First 1)
    Write-Pass "Exactly one top-level directory: $actualTld"

    if ($stem -and ($actualTld -ceq $stem)) {
        Write-Pass "Top-level directory name matches zip stem: $stem"
    } else {
        Write-Fail "Top-level directory '$actualTld' does not match expected '$stem'"
    }
}

# =========================================================================
# CHECK 5 - No loose files at the archive root
# =========================================================================
Write-Section 'CHECK 5: No loose files at archive root'

$rootFiles = New-Object System.Collections.ArrayList
foreach ($e in $allEntries) {
    if ($e.IndexOf([char]47) -lt 0) {   # no forward-slash means root-level
        [void]$rootFiles.Add($e)
    }
}

if ($rootFiles.Count -gt 0) {
    Write-Fail "Found $($rootFiles.Count) file(s) at the archive root:"
    foreach ($f in $rootFiles) { Write-Host "        $f" -ForegroundColor Red }
} else {
    Write-Pass 'No loose files at archive root'
}

# =========================================================================
# CHECK 6 - All entries are under the single top-level directory
# =========================================================================
Write-Section 'CHECK 6: Files reside inside top-level directory'

if ($actualTld) {
    $prefix  = $actualTld + '/'
    $outside = New-Object System.Collections.ArrayList
    foreach ($e in $allEntries) {
        if ($e -ne $prefix -and $e -ne $actualTld -and -not $e.StartsWith($prefix)) {
            [void]$outside.Add($e)
        }
    }
    if ($outside.Count -gt 0) {
        Write-Fail "Found $($outside.Count) entry/entries outside the top-level directory:"
        foreach ($f in $outside) { Write-Host "        $f" -ForegroundColor Red }
    } else {
        Write-Pass "All entries are under '$prefix'"
    }
} else {
    Write-Warn 'Skipped (top-level directory could not be determined)'
}

# =========================================================================
# CHECK 7 - Archive contains at least one file
# =========================================================================
Write-Section 'CHECK 7: Archive is non-empty (contains files)'

$payloadFiles = New-Object System.Collections.ArrayList
foreach ($e in $allEntries) {
    if (-not $e.EndsWith('/')) {
        [void]$payloadFiles.Add($e)
    }
}

if ($payloadFiles.Count -eq 0) {
    Write-Fail 'Archive contains no files (only directories or is empty)'
} else {
    Write-Pass "Archive contains $($payloadFiles.Count) file(s)"
    foreach ($f in $payloadFiles) { Write-Info "  $f" }
}

# =========================================================================
# CHECK 8 - Expected files present (only when caller supplied a list)
# =========================================================================
if ($ExpectedFiles.Count -gt 0) {
    Write-Section 'CHECK 8: Expected files present'
    foreach ($expected in $ExpectedFiles) {
        $found = $false
        foreach ($f in $payloadFiles) {
            if ((Get-EntryName $f) -eq $expected) {
                $found = $true
                break
            }
        }
        if ($found) {
            Write-Pass "Found expected file: $expected"
        } else {
            Write-Fail "Missing expected file: $expected"
        }
    }
} else {
    Write-Info 'No expected-files list supplied; skipping CHECK 8'
}

# =========================================================================
# Summary
# =========================================================================
Write-Host "`n$('=' * 56)" -ForegroundColor White
if ($script:ErrorCount -eq 0) {
    Write-Host ' RESULT: ALL CHECKS PASSED' -ForegroundColor Green
} else {
    Write-Host " RESULT: $($script:ErrorCount) CHECK(S) FAILED" -ForegroundColor Red
}
Write-Host ('=' * 56) -ForegroundColor White
Write-Host ''

exit $(if ($script:ErrorCount -gt 0) { 1 } else { 0 })
