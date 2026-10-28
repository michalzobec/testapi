<#
.SYNOPSIS
    Checks the repository of a Mundana Reworked site before it is committed.

.DESCRIPTION
    Five checks, none of which needs a running site or a build:

      - the templates: every Liquid block is closed and every include names a
        file that is there;
      - the language files: all of them carry the same keys, and every key a
        template asks for is in each of them;
      - the version: README, the top of CHANGELOG and every script in tests
        say the same one;
      - the tests: no -Skip and no -ForEach asks a variable that does not
        exist yet when Pester reads the file;
      - the front matter: a key no layout and no plugin reads is reported, as
        a warning, since a typo there does nothing and says nothing.
      - the scripts themselves, with PSScriptAnalyzer, which is installed and
        kept up to date by the check itself.
      - the two configurations: _config.yml and _config-adv.yml hold the
        same keys, so the one with everything switched on does not fall
        behind the one the site is built from.

    Run it before a commit and the workflow runs it before the build, so the
    same check guards both. Nothing here replaces the smoke tests, which walk
    the published site; these look only at what is in the repository.

    Returns 0 when everything passed, 1 when something failed, and 2 when
    everything passed but something was worth a warning. On a build machine
    the 2 becomes a 0: a step there fails on any code that is not zero, and a
    warning is not a reason to stop a build.

.EXAMPLE
    .\Invoke-RepositoryCheck.ps1

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
$Script:ScriptRole    = 'Repository check'
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

$root = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path

if (-not (Test-Path -LiteralPath (Join-Path -Path $root -ChildPath '_config.yml'))) {
    Write-Host 'This is not the repository of a site.' -ForegroundColor Red
    Write-Host 'Run the check from the tests folder of the site it belongs to.'
    exit 1
}

$Script:Errors = [System.Collections.ArrayList]::new()
$Script:Warnings = [System.Collections.ArrayList]::new()

function Add-Finding {
    param(
        [Parameter(Mandatory)][string]$Message,
        [switch]$Warning
    )

    if ($Warning) { $Script:Warnings.Add($Message) | Out-Null }
    else { $Script:Errors.Add($Message) | Out-Null }
}

function Get-RelativePath {
    param([Parameter(Mandatory)][string]$Path)
    $Path.Substring($root.Length).TrimStart('\', '/')
}

# The files holding Liquid: the templates, the pages and the few files in the
# root that are built rather than copied.
function Get-TemplateFiles {
    $paths = @()

    foreach ($folder in '_layouts', '_includes', '_pages') {
        $full = Join-Path -Path $root -ChildPath $folder
        if (Test-Path -LiteralPath $full) {
            $paths += (Get-ChildItem -LiteralPath $full -File -Recurse).FullName
        }
    }

    foreach ($file in 'index.html', 'search-index.json', 'robots.txt') {
        $full = Join-Path -Path $root -ChildPath $file
        if (Test-Path -LiteralPath $full) { $paths += $full }
    }

    return $paths
}

# --- the templates ---------------------------------------------------------
# Liquid has to be read, not guessed at: a block left open stops the build
# with a message pointing at the end of the file rather than at the mistake,
# and an include naming a file that is not there stops it as well.
function Test-Templates {
    $blocks = @{
        'if' = 'endif'; 'unless' = 'endunless'; 'case' = 'endcase'
        'for' = 'endfor'; 'tablerow' = 'endtablerow'; 'capture' = 'endcapture'
        'comment' = 'endcomment'; 'raw' = 'endraw'
    }

    $checked = 0

    foreach ($path in (Get-TemplateFiles)) {
        $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrEmpty($text)) { continue }
        if ($text -notmatch '\{%') { continue }

        $checked++
        $name = Get-RelativePath -Path $path
        $stack = [System.Collections.ArrayList]::new()

        foreach ($match in [regex]::Matches($text, '\{%-?\s*(\w+)')) {
            $tag = $match.Groups[1].Value

            if ($blocks.ContainsKey($tag)) {
                $stack.Add($tag) | Out-Null
                continue
            }

            if ($tag -notlike 'end*') { continue }

            $opened = $tag.Substring(3)

            if ($stack.Count -eq 0) {
                Add-Finding "$name : {% $tag %} with nothing open."
            } elseif ($stack[$stack.Count - 1] -ne $opened) {
                Add-Finding "$name : {% $tag %} closes {% $($stack[$stack.Count - 1]) %}."
            } else {
                $stack.RemoveAt($stack.Count - 1)
            }
        }

        if ($stack.Count -gt 0) {
            Add-Finding "$name : {% $($stack -join ' %}, {% ') %} left open."
        }

        foreach ($match in [regex]::Matches($text, '\{%-?\s*include\s+([^\s%]+)')) {
            $include = $match.Groups[1].Value
            if ($include -match '[{}]') { continue }

            $target = Join-Path -Path $root -ChildPath (Join-Path -Path '_includes' -ChildPath $include)
            if (-not (Test-Path -LiteralPath $target)) {
                Add-Finding "$name : includes $include, which is not in _includes."
            }
        }
    }

    Write-Host ('Templates: {0} read' -f $checked)
}

# --- the language files ----------------------------------------------------
# A key missing from one of them renders as nothing at all, and nothing says
# so. The scripts in the templates are cut out first: a JavaScript variable
# named t makes t.src and t.innerHTML look exactly like a key.
function Test-LanguageFiles {
    $folder = Join-Path -Path $root -ChildPath '_data/lang'
    if (-not (Test-Path -LiteralPath $folder)) {
        Add-Finding '_data/lang is not there.'
        return
    }

    $languages = @{}

    foreach ($file in (Get-ChildItem -LiteralPath $folder -Filter '*.yml' -File)) {
        $keys = [System.Collections.Generic.HashSet[string]]::new()

        foreach ($line in (Get-Content -LiteralPath $file.FullName -Encoding UTF8)) {
            if ($line -match '^([a-z0-9_]+)\s*:') { $keys.Add($Matches[1]) | Out-Null }
        }

        $languages[$file.BaseName] = $keys
    }

    if ($languages.Count -lt 2) {
        Write-Host ('Language files: {0}, nothing to compare' -f $languages.Count)
    } else {
        $names = @($languages.Keys | Sort-Object)
        $first = $names[0]

        foreach ($name in $names) {
            if ($name -eq $first) { continue }

            foreach ($key in $languages[$first]) {
                if (-not $languages[$name].Contains($key)) {
                    Add-Finding "_data/lang/$name.yml : $key is in $first.yml and not here."
                }
            }

            foreach ($key in $languages[$name]) {
                if (-not $languages[$first].Contains($key)) {
                    Add-Finding "_data/lang/$first.yml : $key is in $name.yml and not here."
                }
            }
        }
    }

    $used = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($path in (Get-TemplateFiles)) {
        $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrEmpty($text)) { continue }

        $prose = [regex]::Replace($text, '(?is)<script.*?</script>', '')

        foreach ($match in [regex]::Matches($prose, '\bt\.([a-z0-9_]+)')) {
            $used.Add($match.Groups[1].Value) | Out-Null
        }
    }

    foreach ($key in ($used | Sort-Object)) {
        foreach ($name in ($languages.Keys | Sort-Object)) {
            if (-not $languages[$name].Contains($key)) {
                Add-Finding "_data/lang/$name.yml : the templates ask for $key, which is not there."
            }
        }
    }

    Write-Host ('Language files: {0}, {1} keys asked for by the templates' -f $languages.Count, $used.Count)
}

# --- the version -----------------------------------------------------------
# Bumped by hand in several files, so one of them is left behind sooner or
# later and nothing reports it.
function Test-Version {
    $found = @{}

    $readme = Join-Path -Path $root -ChildPath 'README.md'
    if (Test-Path -LiteralPath $readme) {
        $match = [regex]::Match((Get-Content -LiteralPath $readme -Raw -Encoding UTF8), '(?m)^Version\s+(\d{2}\.\d{2}\.\d{2}\.\d{4})\b')
        if ($match.Success) { $found['README.md'] = $match.Groups[1].Value }
        else { Add-Finding 'README.md : no version on a line of its own.' }
    }

    $changelog = Join-Path -Path $root -ChildPath 'CHANGELOG.md'
    $published = @()
    if (Test-Path -LiteralPath $changelog) {
        $published = @([regex]::Matches((Get-Content -LiteralPath $changelog -Raw -Encoding UTF8), '(?m)^##\s+(\d{2}\.\d{2}\.\d{2}\.\d{4})\s*$') |
            ForEach-Object { $_.Groups[1].Value })
        if ($published.Count -gt 0) { $found['CHANGELOG.md'] = $published[0] }
        else { Add-Finding 'CHANGELOG.md : no version at the top.' }
    }

    foreach ($file in (Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object { $_.Extension -in '.ps1', '.psm1' })) {
        $match = [regex]::Match((Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8), "ScriptVersion\s*=\s*'(\d{2}\.\d{2}\.\d{2}\.\d{4})'")
        if ($match.Success) { $found["tests/$($file.Name)"] = $match.Groups[1].Value }
        else { Add-Finding "tests/$($file.Name) : no ScriptVersion." }
    }

    $versions = @($found.Values | Sort-Object -Unique)

    if ($versions.Count -gt 1) {
        Add-Finding ('The version is not the same everywhere: {0}' -f (($found.Keys | Sort-Object | ForEach-Object { "$_ $($found[$_])" }) -join ', '))
    } elseif ($versions.Count -eq 1) {
        Write-Host ('Version: {0} in {1} files' -f $versions[0], $found.Count)
    }

    # The internal changelog lives only in the private repository, so it is
    # checked when it is there and passed over without a word when it is not.
    # It holds a subset of the versions on purpose: a revision with nothing
    # internal about it writes no entry here at all. What must hold is that
    # every version named here was also published, and that none of them is
    # newer than the version the repository currently carries.
    $internal = Join-Path -Path $root -ChildPath 'CHANGELOG-INTERNAL.md'
    if (Test-Path -LiteralPath $internal) {
        $listed = @([regex]::Matches((Get-Content -LiteralPath $internal -Raw -Encoding UTF8), '(?m)^##\s+(\d{2}\.\d{2}\.\d{2}\.\d{4})\s*$') |
            ForEach-Object { $_.Groups[1].Value })
        $current = if ($versions.Count -eq 1) { $versions[0] } else { '' }

        if ($listed.Count -eq 0) {
            Add-Finding 'CHANGELOG-INTERNAL.md : no version headings.' -Warning
        } else {
            foreach ($one in $listed) {
                if ($published -notcontains $one) {
                    Add-Finding ('CHANGELOG-INTERNAL.md : version {0} is not in CHANGELOG.md.' -f $one)
                }
                if ($current -and [string]::CompareOrdinal($one, $current) -gt 0) {
                    Add-Finding ('CHANGELOG-INTERNAL.md : version {0} is newer than {1}, the version of the repository.' -f $one, $current)
                }
            }
            Write-Host ('Internal changelog: {0} versions' -f $listed.Count)
        }
    }
}

# --- the tests -------------------------------------------------------------
# Pester reads a test file twice and decides -Skip and -ForEach during the
# first pass, when nothing from BeforeAll exists yet. Asking one of those
# variables there reads nothing, and under Set-StrictMode the whole file fails
# to be read. A variable set at the beginning of a line is set during that
# first pass and is therefore fair game; an indented one is inside a block and
# is not.
function Test-TestFiles {
    $files = Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File
    $checked = 0

    foreach ($file in $files) {
        $checked++
        $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8

        $atDiscovery = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($match in [regex]::Matches($text, '(?m)^\$Script:(\w+)\s*=')) {
            $atDiscovery.Add($match.Groups[1].Value) | Out-Null
        }

        foreach ($match in [regex]::Matches($text, '(?m)^.*?-(?:Skip|ForEach)\b[^\r\n]*$')) {
            foreach ($used in [regex]::Matches($match.Value, '\$Script:(\w+)')) {
                $name = $used.Groups[1].Value
                if ($atDiscovery.Contains($name)) { continue }

                Add-Finding "tests/$($file.Name) : -Skip or -ForEach asks `$Script:$name, which is set inside a block and does not exist when Pester reads the file."
            }
        }
    }

    Write-Host ('Test files: {0} read' -f $checked)
}

# --- the front matter ------------------------------------------------------
# A key nothing reads does nothing and says nothing, so sticky written as
# stickty is a switch that never switches. A warning rather than an error: a
# site may carry a key of its own that this list has never heard of.
function Test-FrontMatter {
    $known = @(
        'author', 'avatar', 'categories', 'category', 'commercial', 'ctablock',
        'date', 'description', 'featured', 'image', 'image_caption', 'imagegrid',
        'imageviewer', 'last_modified_at', 'layout', 'meta_robots', 'permalink',
        'redirect_from', 'relatedblock', 'series', 'seriespart', 'sitemap',
        'sticky', 'title', 'tocblock', 'translation'
    )

    $checked = 0

    foreach ($folder in '_posts', '_drafts', '_pages') {
        $full = Join-Path -Path $root -ChildPath $folder
        if (-not (Test-Path -LiteralPath $full)) { continue }

        foreach ($file in (Get-ChildItem -LiteralPath $full -File)) {
            $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
            $match = [regex]::Match($text, "(?s)\A---\s*\r?\n(.*?)\r?\n---\s*\r?\n")
            if (-not $match.Success) { continue }

            $checked++

            foreach ($line in ($match.Groups[1].Value -split "`r?`n")) {
                if ($line -notmatch '^([A-Za-z0-9_]+)\s*:') { continue }

                $key = $Matches[1]
                if ($known -contains $key) { continue }

                Add-Finding "$folder/$($file.Name) : $key is a key nothing reads." -Warning
            }
        }
    }

    Write-Host ('Front matter: {0} files read' -f $checked)
}

# --- the scripts themselves ------------------------------------------------
# PSScriptAnalyzer reads the PowerShell of this folder. It is a tool of the
# machine the check is run on, not anything the site loads, so it costs the
# site nothing.
#
# The check installs it when it is not there and updates it when the gallery
# holds a newer one, for the current user alone, so nothing needs to be
# administered. Three things are deliberate:
#
#   - on a build machine nothing is installed. The workflow runs this same
#     script, and installing a module on every build would cost a minute for
#     a finding the author has already seen at home. There the step is
#     skipped instead.
#   - neither the install nor the look for a newer version is allowed to stop
#     the check. Without a network, or with the gallery blocked, the step
#     carries on with whatever is already there and says what happened.
#   - three rules are left out. Write-Host is how these scripts talk to
#     whoever runs them, a plural noun is right for a function returning a
#     list of files, and a variable read only inside a Pester block looks
#     unused from the outside while it is the whole point of the file.
function Install-Analyzer {
    $installed = Get-Module -ListAvailable -Name PSScriptAnalyzer |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1

    if ($env:GITHUB_ACTIONS -or $env:CI) {
        if (-not $installed) {
            Write-Host 'Scripts: PSScriptAnalyzer is not on this machine and nothing is installed on a build machine'
            return $null
        }

        return $installed
    }

    if (-not $installed) {
        Write-Host 'Scripts: installing PSScriptAnalyzer, which takes a moment the first time'

        try {
            Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            $installed = Get-Module -ListAvailable -Name PSScriptAnalyzer |
                Sort-Object -Property Version -Descending |
                Select-Object -First 1
        } catch {
            Write-Host ('Scripts: PSScriptAnalyzer could not be installed ({0})' -f $_.Exception.Message) -ForegroundColor Yellow
            return $null
        }

        return $installed
    }

    try {
        $newest = Find-Module -Name PSScriptAnalyzer -ErrorAction Stop

        if ([version]$newest.Version -gt $installed.Version) {
            Write-Host ('Scripts: updating PSScriptAnalyzer from {0} to {1}' -f $installed.Version, $newest.Version)
            Update-Module -Name PSScriptAnalyzer -Force -ErrorAction Stop

            $installed = Get-Module -ListAvailable -Name PSScriptAnalyzer |
                Sort-Object -Property Version -Descending |
                Select-Object -First 1
        }
    } catch {
        Write-Host 'Scripts: the gallery could not be asked for a newer PSScriptAnalyzer, carrying on with the one that is here' -ForegroundColor Yellow
    }

    return $installed
}

function Test-ScriptQuality {
    $module = Install-Analyzer
    if (-not $module) { return }

    Import-Module PSScriptAnalyzer -ErrorAction Stop

    $excluded = @(
        'PSAvoidUsingWriteHost'
        'PSUseSingularNouns'
        'PSUseDeclaredVarsMoreThanAssignments'
    )

    $findings = @(Invoke-ScriptAnalyzer -Path $PSScriptRoot -Recurse -ExcludeRule $excluded -Severity Error, Warning)

    foreach ($finding in $findings) {
        $where = 'tests/{0}:{1}' -f (Split-Path -Leaf $finding.ScriptPath), $finding.Line
        $message = '{0} : {1} ({2})' -f $where, $finding.Message, $finding.RuleName

        if ($finding.Severity -eq 'Error') { Add-Finding $message }
        else { Add-Finding $message -Warning }
    }

    Write-Host ('Scripts: read by PSScriptAnalyzer {0}, {1} findings' -f $module.Version, $findings.Count)
}

# --- the two configurations ------------------------------------------------
# _config-adv.yml is the same configuration with the switches set the way an
# advanced test needs them, and it is copied over _config.yml on a test site.
# Two files of five hundred lines drift apart the moment a key is added to one
# of them, so what is compared is the keys, never the values: the values are
# the whole point of having two.
function Test-Configurations {
    $plain = Join-Path -Path $root -ChildPath '_config.yml'
    $advanced = Join-Path -Path $root -ChildPath '_config-adv.yml'

    if (-not (Test-Path -LiteralPath $advanced)) {
        Write-Host 'Configurations: there is no _config-adv.yml, nothing to compare'
        return
    }

    function Get-ConfigKeys {
        param([Parameter(Mandatory)][string]$Path)

        $keys = [System.Collections.Generic.HashSet[string]]::new()
        $parent = $null

        foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
            if ($line -match '^\s*#') { continue }

            if ($line -match '^([a-z0-9_-]+)\s*:\s*(.*)$') {
                $parent = $Matches[1]
                $keys.Add($parent) | Out-Null
                continue
            }

            # One level in, and only a key, so that a list of mappings such as
            # defaults is left alone.
            if ($parent -and $line -match '^  ([a-z0-9_-]+)\s*:') {
                $keys.Add(('{0}.{1}' -f $parent, $Matches[1])) | Out-Null
            }
        }

        return $keys
    }

    $here = Get-ConfigKeys -Path $plain
    $there = Get-ConfigKeys -Path $advanced

    foreach ($key in $here) {
        if (-not $there.Contains($key)) {
            Add-Finding "_config-adv.yml : $key is in _config.yml and not here."
        }
    }

    foreach ($key in $there) {
        if (-not $here.Contains($key)) {
            Add-Finding "_config.yml : $key is in _config-adv.yml and not here."
        }
    }

    Write-Host ('Configurations: {0} keys in _config.yml, {1} in _config-adv.yml' -f $here.Count, $there.Count)
}

Test-Templates
Test-Configurations
Test-LanguageFiles
Test-Version
Test-TestFiles
Test-FrontMatter
Test-ScriptQuality

Write-Host ''

if ($Script:Warnings.Count -gt 0) {
    Write-Host 'Worth a look:' -ForegroundColor Yellow
    foreach ($warning in $Script:Warnings) { Write-Host ('  {0}' -f $warning) -ForegroundColor Yellow }
    Write-Host ''
}

if ($Script:Errors.Count -gt 0) {
    Write-Host 'REPOSITORY CHECK FAILED' -ForegroundColor Red
    Write-Host '-----------------------' -ForegroundColor Red
    foreach ($finding in $Script:Errors) { Write-Host ('  {0}' -f $finding) -ForegroundColor Red }
    Write-Host ''
    exit 1
}

if ($Script:Warnings.Count -gt 0) {
    Write-Host 'Nothing is broken, but something above is worth a look.' -ForegroundColor Yellow

    # A build machine fails a step on any code that is not zero, and a warning
    # is not a reason to stop a build. It has been said above and that is
    # enough there.
    if ($env:GITHUB_ACTIONS -or $env:CI) { exit 0 }

    exit 2
}

Write-Host 'The repository holds together.' -ForegroundColor Green
exit 0
