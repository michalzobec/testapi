<#
.SYNOPSIS
    Opens the PageSpeed Insights report for the pages of a published Mundana
    Reworked site.

.DESCRIPTION
    Reads the repository the script is run from, works out which pages are
    worth measuring and opens the report for each of them in the browser. The
    address and the pages all come from the repository itself, so there is
    nothing to configure and nothing that can fall out of step with the site.

    The measurement itself runs on Google's infrastructure, not on this
    machine, so the result does not depend on how busy the computer is and
    several reports can be open at once without affecting each other.

    Four pages are offered, each chosen because it is the worst case of its
    kind: the home page, the article carrying the most pictures, a category
    archive that runs to more than one page, and a static page. Measuring all
    four says more than measuring the home page four times.

    Returns 0 when the pages were opened, 1 when the repository could not be
    read.

.EXAMPLE
    .\Invoke-PerformanceCheck.ps1

.NOTES
    Copyright (c) 2025-2026 Michal Zobec, ZOBEC Consulting. All Rights Reserved.
    Web: https://www.michalzobec.cz
    Licensed under GNU General Public License 3
#>

#Requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:ProductName   = 'Mundana Reworked'
$Script:ScriptRole    = 'Performance check'
$Script:ScriptVersion = '26.10.28.2229'
$Script:ScriptName    = if ($PSCommandPath) {
    Split-Path -Leaf $PSCommandPath
} else {
    $MyInvocation.MyCommand.Name
}

Write-Host ('{0} | {1} ({2})' -f $Script:ProductName, $Script:ScriptRole, $Script:ScriptName)
Write-Host ('Version {0}' -f $Script:ScriptVersion)
Write-Host 'by Michal ZOBEC | Web: www.michalzobec.cz'
Write-Host 'Copyright (c) 2025-2026 Michal Zobec, ZOBEC Consulting. All Rights Reserved.'
Write-Host 'Licensed under GNU General Public License 3'
# Said out loud for the sake of a report sent on later: what a script does can
# depend on which PowerShell is running it, and the two in use behave
# differently in places.
Write-Host ('Running on PowerShell version: {0}' -f $PSVersionTable.PSVersion)
Write-Host ''

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'SiteFacts.psm1') -Force

# --- the repository --------------------------------------------------------

$root = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path
$configPath = Join-Path -Path $root -ChildPath '_config.yml'

if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Host 'This is not the repository of a site.' -ForegroundColor Red
    Write-Host ('No _config.yml was found at {0}.' -f $configPath)
    Write-Host 'Run the script from the tests folder of the site it belongs to.'
    exit 1
}

$settings = Get-SiteConfig -Path $configPath
$address = Get-AddressFromConfig -Settings $settings

if (-not $address) {
    Write-Host 'The address of the site could not be found.' -ForegroundColor Red
    Write-Host ('There is no url in {0}.' -f $configPath)
    exit 1
}

$address = $address.TrimEnd('/')
$facts = Get-SiteFacts -Root $root

# --- what to measure -------------------------------------------------------
# The same four pages the PageSpeed report measures; the choice is made in
# SiteFacts.psm1 so that the two scripts cannot drift apart.

$targets = Get-MeasuredPages -Facts $facts

if ($targets.Count -eq 0) {
    Write-Host 'There is nothing to measure.' -ForegroundColor Red
    exit 1
}

# --- opening the reports ---------------------------------------------------

function Open-Report {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Opens a read-only report in the browser and changes nothing.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url
    )

    $report = 'https://pagespeed.web.dev/analysis?url={0}' -f [uri]::EscapeDataString($Url)

    try {
        Start-Process -FilePath $report | Out-Null
        return $true
    } catch {
        Write-Host ('  The browser could not be started: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
        Write-Host ('  Open it by hand: {0}' -f $report)
        return $false
    }
}

function Invoke-Measurement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Pages
    )

    foreach ($one in $Pages) {
        $url = $address + $one.Path
        Write-Host ('Opening {0} - {1}' -f $one.Name, $url)
        Open-Report -Url $url | Out-Null
    }

    Write-Host ''
    Write-Host 'Each report measures the mobile and the desktop view; the tabs are at the'
    Write-Host 'top of the page. A measurement takes about half a minute.'
    Write-Host ''
}

# --- the menu --------------------------------------------------------------

Write-Host ('Site: {0}' -f $address)
Write-Host ('Read from the repository at {0}' -f $root)
Write-Host ''

while ($true) {
    Write-Host 'What should be measured?'
    Write-Host ''
    for ($i = 0; $i -lt $targets.Count; $i++) {
        Write-Host ('  {0}. {1,-32} {2}' -f ($i + 1), $targets[$i].Name, $targets[$i].Path)
    }
    Write-Host '  A. All of them at once'
    Write-Host '  Q. Quit'
    Write-Host ''

    $answer = (Read-Host 'Choice').Trim()

    if ($answer -match '^[Qq]$' -or $answer -eq '') { break }

    if ($answer -match '^[Aa]$') {
        Invoke-Measurement -Pages $targets
        continue
    }

    $number = 0
    if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $targets.Count) {
        Invoke-Measurement -Pages @($targets[$number - 1])
        continue
    }

    Write-Host 'That is not one of the choices.' -ForegroundColor Yellow
    Write-Host ''
}

exit 0
