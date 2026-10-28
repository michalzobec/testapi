<#
.SYNOPSIS
    Runs the smoke tests against a published Mundana Reworked site.

.DESCRIPTION
    Reads the repository the tests are run from, works out what the site
    should look like and hands that to Pester. The address, the switches, the
    articles, the categories, the authors and the series all come from the
    repository itself, so there is nothing to configure and nothing that can
    fall out of step with the site. The script therefore takes no parameters.

    Everything goes over HTTP; no browser is started, so nothing that only
    happens in the reader's browser is covered. What is and is not covered is
    written out in README.md.

    Returns 0 when everything passed, 1 when something failed or the tests
    could not be run at all, and 2 when everything passed but something was
    skipped.

.EXAMPLE
    .\Invoke-SmokeTest.ps1

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
$Script:ScriptRole    = 'Smoke tests'
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

# The repository the tests are run from is the site they are run against.
# Everything they expect is read out of it: the address, the switches, the
# articles, the categories, the authors and the series. There is nothing to
# choose and nothing to keep in step, which is why this script takes no
# parameters at all.
$root = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path
$configPath = Join-Path -Path $root -ChildPath '_config.yml'

if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Host 'This is not the repository of a site.' -ForegroundColor Red
    Write-Host ('No _config.yml was found at {0}.' -f $configPath)
    Write-Host 'Run the tests from the tests folder of the site they belong to.'
    exit 1
}

$settings = Get-SiteConfig -Path $configPath
$address = Get-AddressFromConfig -Settings $settings

if (-not $address) {
    Write-Host 'The address of the site could not be found.' -ForegroundColor Red
    Write-Host ('There is no url in {0}.' -f $configPath)
    exit 1
}

$expectations = Get-SiteFacts -Root $root
$expectations['BaseUrl'] = $address.TrimEnd('/')

# Pester 5 took a different shape from 4 and the tests are written for 5, so a
# 4 that happens to be installed is not good enough.
$pester = Get-Module -ListAvailable -Name Pester |
    Where-Object { $_.Version.Major -ge 5 } |
    Sort-Object -Property Version -Descending |
    Select-Object -First 1

if (-not $pester) {
    Write-Host 'Pester 5 or newer is needed and was not found.' -ForegroundColor Red
    Write-Host 'Install it with:'
    Write-Host '  Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck'
    exit 1
}

Import-Module -ModuleInfo $pester -Force

$testsPath = Join-Path -Path $PSScriptRoot -ChildPath 'Site.Smoke.Tests.ps1'

# Which version of the theme is being tested. The tests are written for the
# release they came with, so a site built from another one can fail a test
# that is right about the version and wrong about the site. It is said here
# rather than left to be worked out from a failure further down.
$repositoryVersion = Get-ChangelogVersion -Path (Join-Path -Path $root -ChildPath 'CHANGELOG.md')
$siteVersion = $null

try {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'SiteProbe.psm1') -Force
    $homePage = Get-SiteResponse -Url $expectations['BaseUrl']
    if ($homePage.StatusCode -eq 200) { $siteVersion = Get-GeneratorVersion -Html $homePage.Content }
} catch {
    $siteVersion = $null
}

$unknown = 'unknown'

Write-Host ('Testing {0}' -f $expectations['BaseUrl'])
Write-Host ('Read from the repository at {0}' -f $root)
Write-Host ('Theme: tests {0}, repository {1}, site {2}' -f `
    $Script:ScriptVersion,
    $(if ($repositoryVersion) { $repositoryVersion } else { $unknown }),
    $(if ($siteVersion) { $siteVersion } else { $unknown }))

if ($repositoryVersion -and $siteVersion -and $repositoryVersion -ne $siteVersion) {
    Write-Host 'The site was built from another version of the theme than the one in the repository.' -ForegroundColor Yellow
    Write-Host 'A test that fails may be saying that, and not that the site is wrong.' -ForegroundColor Yellow
}

if ($repositoryVersion -and $repositoryVersion -ne $Script:ScriptVersion) {
    Write-Host 'The tests come from another release of the theme than the repository they are in.' -ForegroundColor Yellow
}

if (-not $siteVersion) {
    Write-Host 'The version the site was built from could not be read.' -ForegroundColor Yellow
}

Write-Host ('{0} switches, {1} categories, {2} authors, {3} series, {4} parts of the longest one' -f `
    $settings.Count, $expectations['Categories'].Count, $expectations['Authors'].Count,
    $expectations['Series'].Count, $expectations['SeriesPartUrls'].Count)
Write-Host ('Pester {0}' -f $pester.Version)
Write-Host ''

$configuration = New-PesterConfiguration
$configuration.Run.Container = New-PesterContainer -Path $testsPath -Data @{
    Config   = $expectations
    Settings = $settings
}
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Detailed'
$configuration.Should.ErrorAction = 'Continue'

$result = $null
try {
    $result = Invoke-Pester -Configuration $configuration
} catch {
    Write-Host ('The tests could not be run: {0}' -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}

if ($null -eq $result) {
    Write-Host 'The tests produced no result.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host ('Passed {0}, failed {1}, skipped {2}, in {3:N1} s' -f `
    $result.PassedCount, $result.FailedCount, $result.SkippedCount, $result.Duration.TotalSeconds)

if ($result.FailedCount -gt 0) {
    Write-Host 'The site is not in the shape it should be.' -ForegroundColor Red
    exit 1
}

if ($result.SkippedCount -gt 0) {
    Write-Host 'Everything that ran passed, but something was skipped.' -ForegroundColor Yellow
    exit 2
}

Write-Host 'The site stands.' -ForegroundColor Green
exit 0
