<#
.SYNOPSIS
    Measures the pages of a published Mundana Reworked site with PageSpeed
    Insights and writes what did not pass to a report.

.DESCRIPTION
    Reads the repository the script is run from, takes the same four pages the
    performance check offers and measures each of them through the PageSpeed
    Insights API, on a phone and on a desktop, in all four categories:
    performance, accessibility, best practices and SEO.

    The scores and the list of what did not pass are written to the console,
    and the whole result to two files in tests/results, one folder per run:
    report.md to be read and report.json to be processed. Both hold the same
    findings. The raw answer of the API is not kept; it runs to most of a
    megabyte and is mostly pictures.

    A finding is an audit scored below 0.9, the point under which the web
    report stops showing it green, including those that do not count towards
    the score. Audits the accessibility category marks as informative are
    findings as well when they name elements, because those are the ones it
    asks a person to look at. Informative audits elsewhere are diagnostics
    and are left out, and so are audits that do not apply or that can only
    be checked by hand.

    The API needs a key. It is kept in tests/pagespeed.config.json together
    with the language the texts of the audits come in. The file is asked for
    on the first run, is listed in .gitignore and is never shown on screen.

    The version of the theme the site runs is read from the page itself. When
    it is not the version in the repository the report says so, since a
    finding may then be fixed already or not deployed yet.

    Returns 0 when the menu is left, 1 when the repository or the key cannot
    be read.

.EXAMPLE
    .\Invoke-PageSpeedReport.ps1

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
$Script:ScriptRole    = 'PageSpeed report'
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
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'SiteProbe.psm1') -Force

# --- settings that are not worth a file --------------------------------------

$Script:ApiAddress = 'https://www.googleapis.com/pagespeedonline/v5/runPagespeed'
$Script:Devices    = @('mobile', 'desktop')
$Script:Categories = @('performance', 'accessibility', 'best-practices', 'seo')

# The API answers with everything Lighthouse knows, a full screenshot of the
# page among it. Asking for these parts alone brings the answer down by about
# a third, which leaves room to spare for Windows PowerShell; how it copes
# with an answer of a megabyte has not been tried.
$Script:ApiFields = 'analysisUTCTimestamp,lighthouseResult(lighthouseVersion,finalUrl,' +
    'fetchTime,configSettings/locale,categories,categoryGroups,audits)'

# A measurement runs Lighthouse on Google's side; half a minute is usual, and
# a slow page takes longer.
$Script:TimeoutSec = 180

# How much of each finding goes into the report. The rest is counted, so the
# reader knows it is there.
$Script:MaxItems    = 10
$Script:MaxSubItems = 5

$Script:Czech = [Globalization.CultureInfo]::GetCultureInfo('cs-CZ')
$Script:Utf8  = New-Object System.Text.UTF8Encoding($false)

# --- small helpers -------------------------------------------------------------

function Get-Field {
    <#
    .SYNOPSIS
        A property of an object, or nothing when the object does not have it.

    .DESCRIPTION
        The answer of the API leaves out what does not apply, and under
        Set-StrictMode asking for a property that is not there throws rather
        than answering nothing. Every optional part is read through this.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-Members {
    <#
    .SYNOPSIS
        The names of the properties of an object, in the order the API gave.
    #>
    [CmdletBinding()]
    param([AllowNull()]$Object)

    if ($null -eq $Object) { return ,@() }
    return ,@($Object.PSObject.Properties | ForEach-Object { $_.Name })
}

function Hide-Key {
    <#
    .SYNOPSIS
        A text with the API key taken out, for anything that reaches the screen.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][AllowNull()][string]$Text,
        [AllowEmptyString()][AllowNull()][string]$Key
    )

    if (-not $Text) { return '' }
    if (-not $Key) { return $Text }
    return $Text.Replace($Key, '***')
}

function Format-Score {
    <#
    .SYNOPSIS
        A score of the API, 0 to 1, as the whole number the web report shows.
    #>
    [CmdletBinding()]
    param([AllowNull()]$Score)

    if ($null -eq $Score) { return $null }
    return [int][math]::Round([double]$Score * 100)
}

function Get-ScoreColour {
    <#
    .SYNOPSIS
        The colour the web report gives a score: green, orange or red.
    #>
    [CmdletBinding()]
    param([AllowNull()]$Score)

    if ($null -eq $Score) { return 'DarkGray' }
    if ($Score -ge 90) { return 'Green' }
    if ($Score -ge 50) { return 'Yellow' }
    return 'Red'
}

function Format-Number {
    <#
    .SYNOPSIS
        A number written the Czech way, with a unit when one is given.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Value,
        [string]$Unit = '',
        [int]$Decimals = 0
    )

    $number = [double]$Value
    $text = $number.ToString(('N{0}' -f $Decimals), $Script:Czech)
    if ($Unit) { return ('{0} {1}' -f $text, $Unit) }
    return $text
}

function Format-Duration {
    <#
    .SYNOPSIS
        A length of time in the unit the web report would use for it.

    .DESCRIPTION
        The same column carries a few milliseconds of work on the page and the
        hours a file may stay in a cache, and 14 400 000 ms says nothing that
        4 h does not say better.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Milliseconds)

    $ms = [double]$Milliseconds
    if ($ms -lt 1000) { return (Format-Number -Value $ms -Unit 'ms') }
    if ($ms -lt 60000) { return (Format-Number -Value ($ms / 1000) -Unit 's' -Decimals 1) }
    if ($ms -lt 3600000) { return (Format-Number -Value ($ms / 60000) -Unit 'min') }
    if ($ms -lt 86400000) { return (Format-Number -Value ($ms / 3600000) -Unit 'h' -Decimals 1) }
    return (Format-Number -Value ($ms / 86400000) -Unit 'd' -Decimals 1)
}

# --- the key -------------------------------------------------------------------

function Read-ApiSettings {
    <#
    .SYNOPSIS
        The key and the language from the settings file, asking for them on
        the first run.

    .DESCRIPTION
        The file holds a secret, so it is listed in .gitignore and its key is
        never written to the screen. When it is missing the key is asked for
        without echoing it and the file is written. When it is there but
        unusable the script says why and how to put it right, rather than
        overwriting what someone may have written by hand.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        try {
            $text = [IO.File]::ReadAllText($Path, $Script:Utf8)
            $stored = $text | ConvertFrom-Json
        } catch {
            Write-Host ('The settings file cannot be read: {0}' -f $Path) -ForegroundColor Red
            Write-Host 'It is not valid JSON. Correct it, or delete it and run the script again'
            Write-Host 'to be asked for the key.'
            return $null
        }

        $key = [string](Get-Field -Object $stored -Name 'ApiKey')
        if (-not $key.Trim()) {
            Write-Host ('There is no ApiKey in {0}.' -f $Path) -ForegroundColor Red
            Write-Host 'Add it, or delete the file and run the script again to be asked for it.'
            return $null
        }

        $locale = [string](Get-Field -Object $stored -Name 'Locale')
        if (-not $locale.Trim()) { $locale = 'cs' }

        return [pscustomobject]@{ ApiKey = $key.Trim(); Locale = $locale.Trim() }
    }

    Write-Host 'The PageSpeed Insights API needs a key, and there is none yet.'
    Write-Host 'It is created in the Google Cloud Console, restricted to the PageSpeed'
    Write-Host 'Insights API. See the README for the steps.'
    Write-Host ''
    Write-Host ('It will be kept in {0},' -f $Path)
    Write-Host 'which .gitignore keeps out of the repository.'
    Write-Host ''

    $secure = Read-Host -Prompt 'API key (not shown, Enter alone to quit)' -AsSecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }

    if (-not $key -or -not $key.Trim()) {
        Write-Host 'No key was given.' -ForegroundColor Yellow
        return $null
    }

    $settings = [ordered]@{ ApiKey = $key.Trim(); Locale = 'cs' }
    $json = $settings | ConvertTo-Json
    [IO.File]::WriteAllText($Path, $json, $Script:Utf8)

    Write-Host 'The key was saved. The texts of the audits come in Czech; change Locale'
    Write-Host 'in the file to have them in another language, en for English.'
    Write-Host ''

    return [pscustomobject]@{ ApiKey = $settings.ApiKey; Locale = $settings.Locale }
}

# --- reading an audit ------------------------------------------------------------

function Format-Value {
    <#
    .SYNOPSIS
        One cell of an audit table as a line of text.

    .DESCRIPTION
        Lighthouse says how each column is to be read, and a value can carry a
        type of its own besides. Anything not recognised is written out as it
        came rather than left out, so nothing goes missing without a trace.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]$Value,
        [AllowNull()][string]$ValueType,
        [switch]$Brief
    )

    if ($null -eq $Value) { return '' }

    $ownType = Get-Field -Object $Value -Name 'type'
    if ($ownType -and $Value -isnot [string]) { $ValueType = [string]$ownType }

    switch ($ValueType) {
        'node' {
            $parts = New-Object System.Collections.Generic.List[string]
            $selector = Get-Field -Object $Value -Name 'selector'
            $label = Get-Field -Object $Value -Name 'nodeLabel'
            $snippet = Get-Field -Object $Value -Name 'snippet'
            $explanation = Get-Field -Object $Value -Name 'explanation'
            if ($selector) { $parts.Add(('`{0}`' -f $selector)) }
            if ($label -and $label -ne $selector) { $parts.Add(('"{0}"' -f ($label -replace '\s+', ' '))) }
            # Under a row the element is named, not quoted. What it is matters
            # there; its markup would repeat itself on every row.
            if ($Brief) { return ($parts.ToArray() -join ' - ') }
            if ($explanation) {
                # The first line of an explanation only says which rules
                # follow; the reason is in the lines under it.
                $lines = @($explanation -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                if ($lines.Count -gt 1) { $lines = $lines[1..($lines.Count - 1)] }
                $parts.Add(($lines -join ' '))
            }
            if ($snippet) { $parts.Add(('`{0}`' -f $snippet)) }
            return ($parts.ToArray() -join ' - ')
            break
        }
        'source-location' {
            $url = Get-Field -Object $Value -Name 'url'
            $line = Get-Field -Object $Value -Name 'line'
            $column = Get-Field -Object $Value -Name 'column'
            if ($null -ne $line -and $null -ne $column) {
                # Lines are counted from zero in the data and from one on screen.
                return ('{0}:{1}:{2}' -f $url, ([int]$line + 1), $column)
            }
            return [string]$url
            break
        }
        'link' {
            $text = Get-Field -Object $Value -Name 'text'
            $url = Get-Field -Object $Value -Name 'url'
            return ('{0} ({1})' -f $text, $url)
            break
        }
        'url' { return [string]$Value; break }
        'bytes' { return (Format-Number -Value ([double]$Value / 1024) -Unit 'KiB' -Decimals 1); break }
        'ms' { return (Format-Duration -Milliseconds $Value); break }
        'timespanMs' { return (Format-Duration -Milliseconds $Value); break }
        'numeric' { return (Format-Number -Value $Value -Decimals 2); break }
        'text' { return [string]$Value; break }
        'code' {
            $code = Get-Field -Object $Value -Name 'value'
            if ($null -eq $code) { $code = $Value }
            return ('`{0}`' -f $code)
            break
        }
        default {
            if ($Value -is [string] -or $Value -is [ValueType]) { return [string]$Value }
            return ($Value | ConvertTo-Json -Depth 6 -Compress)
        }
    }
}

function Get-ItemLines {
    <#
    .SYNOPSIS
        The rows of an audit as lines of text, the way the web report lays
        them out.

    .DESCRIPTION
        A table names its columns in its headings; a row can carry rows of its
        own under it, and a list holds whole tables. Each of those is followed
        here as far as it goes. A kind of detail that cannot be laid out as
        rows is said by name rather than dropped.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]$Details,
        [int]$Depth = 0
    )

    $lines = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Details) { return ,$lines.ToArray() }

    $type = [string](Get-Field -Object $Details -Name 'type')
    $indent = '  ' * $Depth

    switch ($type) {
        { $_ -in @('table', 'opportunity') } {
            $headings = @(Get-Field -Object $Details -Name 'headings')
            $items = @(Get-Field -Object $Details -Name 'items')

            foreach ($item in $items) {
                $cells = New-Object System.Collections.Generic.List[string]
                foreach ($heading in $headings) {
                    if ($null -eq $heading) { continue }
                    $key = Get-Field -Object $heading -Name 'key'
                    if (-not $key) { continue }
                    $cell = Format-Value -Value (Get-Field -Object $item -Name $key) `
                                         -ValueType ([string](Get-Field -Object $heading -Name 'valueType'))
                    if ($cell) { $cells.Add($cell) }
                }
                $lines.Add(('{0}- {1}' -f $indent, ($cells.ToArray() -join ' | ')))

                $subItems = @(Get-Field -Object (Get-Field -Object $item -Name 'subItems') -Name 'items')
                $shown = 0
                foreach ($sub in $subItems) {
                    if ($null -eq $sub) { continue }
                    if ($shown -ge $Script:MaxSubItems) { break }
                    $subCells = New-Object System.Collections.Generic.List[string]
                    foreach ($heading in $headings) {
                        if ($null -eq $heading) { continue }
                        $subHeading = Get-Field -Object $heading -Name 'subItemsHeading'
                        if ($null -eq $subHeading) { continue }
                        $subKey = Get-Field -Object $subHeading -Name 'key'
                        if (-not $subKey) { continue }
                        $subType = [string](Get-Field -Object $subHeading -Name 'valueType')
                        if (-not $subType) { $subType = [string](Get-Field -Object $heading -Name 'valueType') }
                        $cell = Format-Value -Value (Get-Field -Object $sub -Name $subKey) -ValueType $subType -Brief
                        if ($cell) { $subCells.Add($cell) }
                    }
                    if ($subCells.Count) {
                        $lines.Add(('{0}    - {1}' -f $indent, ($subCells.ToArray() -join ' | ')))
                        $shown++
                    }
                }
                $rest = @($subItems | Where-Object { $null -ne $_ }).Count - $shown
                if ($rest -gt 0) { $lines.Add(('{0}    - and {1} more' -f $indent, $rest)) }
            }
            break
        }
        'list' {
            foreach ($part in @(Get-Field -Object $Details -Name 'items')) {
                if ($null -eq $part) { continue }
                $partType = [string](Get-Field -Object $part -Name 'type')
                if ($partType -eq 'node') {
                    $lines.Add(('{0}- {1}' -f $indent, (Format-Value -Value $part -ValueType 'node')))
                } else {
                    foreach ($line in (Get-ItemLines -Details $part -Depth $Depth)) { $lines.Add($line) }
                }
            }
            break
        }
        'checklist' {
            $checks = Get-Field -Object $Details -Name 'items'
            foreach ($name in (Get-Members -Object $checks)) {
                $check = Get-Field -Object $checks -Name $name
                $passed = [bool](Get-Field -Object $check -Name 'value')
                $mark = if ($passed) { 'yes' } else { 'no' }
                $lines.Add(('{0}- {1}: {2}' -f $indent, (Get-Field -Object $check -Name 'label'), $mark))
            }
            break
        }
        default {
            if ($type) {
                $lines.Add(('{0}- (details of the kind "{1}" are not laid out here; see the web report)' -f $indent, $type))
            }
        }
    }

    return ,$lines.ToArray()
}

function Get-Findings {
    <#
    .SYNOPSIS
        What did not pass in one measurement, in a fixed order.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Lighthouse)

    $findings = New-Object System.Collections.Generic.List[object]
    $audits = Get-Field -Object $Lighthouse -Name 'audits'
    $categories = Get-Field -Object $Lighthouse -Name 'categories'
    $groups = Get-Field -Object $Lighthouse -Name 'categoryGroups'

    foreach ($categoryId in $Script:Categories) {
        $category = Get-Field -Object $categories -Name $categoryId
        if ($null -eq $category) { continue }

        foreach ($ref in @(Get-Field -Object $category -Name 'auditRefs')) {
            $group = [string](Get-Field -Object $ref -Name 'group')
            # Lighthouse files its own bookkeeping under a group called
            # hidden: lists of requests, timings, thumbnails. They are not
            # findings and the web report does not show them either.
            if ($group -eq 'hidden') { continue }

            $id = [string](Get-Field -Object $ref -Name 'id')
            $audit = Get-Field -Object $audits -Name $id
            if ($null -eq $audit) { continue }

            $mode = [string](Get-Field -Object $audit -Name 'scoreDisplayMode')
            $score = Get-Field -Object $audit -Name 'score'
            $details = Get-Field -Object $audit -Name 'details'
            $rows = @(Get-Field -Object $details -Name 'items' | Where-Object { $null -ne $_ })

            $failed = ($mode -in @('binary', 'numeric', 'metricSavings')) -and
                      ($null -ne $score) -and ([double]$score -lt 0.9)
            $review = ($categoryId -eq 'accessibility') -and ($mode -eq 'informative') -and ($rows.Count -gt 0)
            if (-not ($failed -or $review)) { continue }

            # Get-ItemLines hands back an array with the comma in front of it;
            # wrapping the call in @() as well would make an array of one array.
            $lines = Get-ItemLines -Details $details
            $more = 0
            if ($lines.Count -gt $Script:MaxItems) {
                # Rows of the top level are counted, not the lines under them.
                $topLevel = @($lines | Where-Object { $_ -match '^- ' }).Count
                $kept = New-Object System.Collections.Generic.List[string]
                $seen = 0
                foreach ($line in $lines) {
                    if ($line -match '^- ') { $seen++ }
                    if ($seen -gt $Script:MaxItems) { break }
                    $kept.Add($line)
                }
                $more = $topLevel - $Script:MaxItems
                $lines = $kept.ToArray()
            }

            $weight = [double](Get-Field -Object $ref -Name 'weight')
            $groupTitle = [string](Get-Field -Object (Get-Field -Object $groups -Name $group) -Name 'title')

            $findings.Add([pscustomobject][ordered]@{
                category          = $categoryId
                categoryTitle     = [string](Get-Field -Object $category -Name 'title')
                group             = $groupTitle
                id                = $id
                title             = [string](Get-Field -Object $audit -Name 'title')
                description       = [string](Get-Field -Object $audit -Name 'description')
                displayValue      = [string](Get-Field -Object $audit -Name 'displayValue')
                score             = Format-Score -Score $score
                scoreDisplayMode  = $mode
                weight            = $weight
                countsTowardScore = ($weight -gt 0)
                items             = $lines
                moreItems         = [math]::Max(0, $more)
            })
        }
    }

    return ,$findings.ToArray()
}

# --- one measurement -------------------------------------------------------------

function Invoke-Measurement {
    <#
    .SYNOPSIS
        Measures one page on one device and returns what came of it.

    .DESCRIPTION
        A refusal of the API is not a failure of the script: it is written
        into the result with the reason the API gave, and the run goes on with
        the next page.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$Device,
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)]$Settings
    )

    $pageUrl = $Address + $Target.Path
    $query = @(
        ('url={0}' -f [uri]::EscapeDataString($pageUrl))
        ('strategy={0}' -f $Device)
        ($Script:Categories | ForEach-Object { 'category={0}' -f $_ })
        ('locale={0}' -f [uri]::EscapeDataString($Settings.Locale))
        ('fields={0}' -f [uri]::EscapeDataString($Script:ApiFields))
        ('key={0}' -f [uri]::EscapeDataString($Settings.ApiKey))
    ) -join '&'
    $request = '{0}?{1}' -f $Script:ApiAddress, $query

    $result = [ordered]@{
        page        = $Target.Name
        path        = $Target.Path
        url         = $pageUrl
        device      = $Device
        status      = 'failed'
        error       = $null
        measuredAt  = $null
        lighthouse  = $null
        scores      = [ordered]@{}
        findings    = @()
        assetVersion = $null
    }

    try {
        $response = Get-SiteResponse -Url $request -TimeoutSec $Script:TimeoutSec
    } catch {
        $result.error = Hide-Key -Text $_.Exception.Message -Key $Settings.ApiKey
        return [pscustomobject]$result
    }

    $answer = $null
    if ($response.Content) {
        try { $answer = $response.Content | ConvertFrom-Json } catch { $answer = $null }
    }

    if ($response.StatusCode -ne 200 -or $null -eq $answer) {
        $message = [string](Get-Field -Object (Get-Field -Object $answer -Name 'error') -Name 'message')
        if (-not $message) { $message = 'The API answered with nothing it could be read from.' }
        $result.error = Hide-Key -Text ('HTTP {0}: {1}' -f $response.StatusCode, $message) -Key $Settings.ApiKey
        return [pscustomobject]$result
    }

    $lighthouse = Get-Field -Object $answer -Name 'lighthouseResult'
    if ($null -eq $lighthouse) {
        $result.error = 'The answer carries no Lighthouse result.'
        return [pscustomobject]$result
    }

    $categories = Get-Field -Object $lighthouse -Name 'categories'
    foreach ($categoryId in $Script:Categories) {
        $result.scores[$categoryId] = Format-Score -Score (Get-Field -Object (Get-Field -Object $categories -Name $categoryId) -Name 'score')
    }

    $result.status = 'ok'
    $result.measuredAt = [string](Get-Field -Object $answer -Name 'analysisUTCTimestamp')
    $result.lighthouse = [string](Get-Field -Object $lighthouse -Name 'lighthouseVersion')
    $result.findings = Get-Findings -Lighthouse $lighthouse

    # The theme puts its version on the address of every stylesheet and
    # script. That is how the version of the site can still be told when the
    # page itself could not be fetched.
    try {
        $requests = Get-Field -Object (Get-Field -Object (Get-Field -Object (Get-Field -Object $lighthouse -Name 'audits') -Name 'network-requests') -Name 'details') -Name 'items'
        foreach ($one in @($requests)) {
            $match = [regex]::Match([string](Get-Field -Object $one -Name 'url'), '[?&]v=(\d{2}\.\d{2}\.\d{2}\.\d{4})')
            if ($match.Success) { $result.assetVersion = $match.Groups[1].Value; break }
        }
    } catch {
        $result.assetVersion = $null
    }

    return [pscustomobject]$result
}

# --- the report ---------------------------------------------------------------------

function Get-DeployedVersion {
    <#
    .SYNOPSIS
        The version of the theme the site runs, and where it was read from.

    .DESCRIPTION
        The generator meta on the home page says it outright. When the page
        cannot be fetched the addresses of the stylesheets in the measurement
        say the same, and when neither is there the version is unknown. None
        of this may stop the report; it only describes it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Address,
        [object[]]$Measurements = @()
    )

    try {
        $page = Get-SiteResponse -Url ($Address + '/')
        if ($page.StatusCode -eq 200) {
            $version = Get-GeneratorVersion -Html $page.Content
            if ($version) { return [pscustomobject]@{ Version = $version; Source = 'the generator meta of the home page' } }
        }
    } catch {
        Write-Host ('  The home page could not be fetched to read its version: {0}' -f $_.Exception.Message) -ForegroundColor DarkGray
    }

    foreach ($one in $Measurements) {
        if ($one.assetVersion) {
            return [pscustomobject]@{ Version = $one.assetVersion; Source = 'the addresses of the stylesheets' }
        }
    }

    return [pscustomobject]@{ Version = $null; Source = 'nowhere' }
}

function Get-ReportText {
    <#
    .SYNOPSIS
        The Markdown report of a run.

    .DESCRIPTION
        A finding that turns up on several pages is written once, with the
        pages it was found on. Its rows are listed per page and device, and a
        set of rows already listed for another page is referred to rather
        than repeated: the navigation is the same on every page, and four
        copies of it say nothing four does not.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run)

    $out = New-Object System.Text.StringBuilder
    $add = { param($line) [void]$out.AppendLine($line) }

    & $add '# PageSpeed report'
    & $add ''
    & $add ('- Site: {0}' -f $Run.site)
    & $add ('- Measured: {0}' -f $Run.measuredLocal)
    & $add ('- Theme version on the site: {0} (read from {1})' -f $(if ($Run.deployedVersion) { $Run.deployedVersion } else { 'unknown' }), $Run.deployedVersionSource)
    & $add ('- Theme version in the repository: {0}' -f $Run.repositoryVersion)
    & $add ('- Script version: {0}' -f $Run.scriptVersion)
    & $add ('- Lighthouse {0}, texts of the audits in "{1}"' -f $Run.lighthouseVersion, $Run.locale)
    if ($Run.versionWarning) {
        & $add ''
        & $add ('> {0}' -f $Run.versionWarning)
    }
    & $add ''

    & $add '## Scores'
    & $add ''
    & $add '| Page | Path | Device | Performance | Accessibility | Best practices | SEO |'
    & $add '|---|---|---|---:|---:|---:|---:|'
    foreach ($m in $Run.measurements) {
        if ($m.status -ne 'ok') {
            & $add ('| {0} | `{1}` | {2} | failed: {3} | | | |' -f $m.page, $m.path, $m.device, $m.error)
            continue
        }
        # Read one by one rather than collected in a loop, where a score that is
        # missing would drop out and shift the columns after it.
        & $add ('| {0} | `{1}` | {2} | {3} | {4} | {5} | {6} |' -f $m.page, $m.path, $m.device,
            $m.scores['performance'], $m.scores['accessibility'], $m.scores['best-practices'], $m.scores['seo'])
    }
    & $add ''

    $byAudit = [ordered]@{}
    foreach ($m in $Run.measurements) {
        foreach ($f in $m.findings) {
            $key = '{0}|{1}' -f $f.category, $f.id
            if (-not $byAudit.Contains($key)) {
                $byAudit[$key] = [pscustomobject]@{ Finding = $f; Places = New-Object System.Collections.Generic.List[object] }
            }
            $byAudit[$key].Places.Add([pscustomobject]@{ Measurement = $m; Finding = $f })
        }
    }

    $ordered = @($byAudit.Values | Sort-Object -Property @(
        @{ Expression = { [array]::IndexOf($Script:Categories, $_.Finding.category) } },
        @{ Expression = { $_.Finding.id } }
    ))

    # What lowers the score comes first, across every category, and the
    # diagnostics that do not count follow under a heading of their own. They
    # are often the longest part of the report and the least urgent.
    $sections = @(
        @{ Title = 'Findings that count towards the score'; Counts = $true;
           Empty = 'Nothing that counts towards the score fell below 0.9.' },
        @{ Title = 'Findings that do not count towards the score'; Counts = $false;
           Empty = 'Nothing here.' }
    )

    foreach ($section in $sections) {
        & $add ('## {0}' -f $section.Title)
        & $add ''

        $entries = @($ordered | Where-Object { $_.Finding.countsTowardScore -eq $section.Counts })
        if ($entries.Count -eq 0) {
            & $add $section.Empty
            & $add ''
            continue
        }

        foreach ($entry in $entries) {
            $f = $entry.Finding
            & $add ('### {0}: {1}' -f $f.categoryTitle, $f.title)
            & $add ''
            $facts = @(('`{0}`' -f $f.id))
            if ($null -ne $f.score) { $facts += ('score {0}' -f $f.score) }
            if ($f.displayValue) { $facts += $f.displayValue }
            if ($f.group) { $facts += ('group: {0}' -f $f.group) }
            & $add ('- {0}' -f ($facts -join ' - '))
            $where = $entry.Places | ForEach-Object { '{0} ({1})' -f $_.Measurement.page, $_.Measurement.device }
            & $add ('- Found on: {0}' -f ($where -join ', '))
            if ($f.description) { & $add ('- {0}' -f ($f.description -replace '\s+', ' ')) }
            & $add ''

            $listed = @{}
            foreach ($place in $entry.Places) {
                $rows = @($place.Finding.items)
                if ($rows.Count -eq 0) { continue }
                $signature = ($rows -join "`n")
                $label = '{0}, {1}' -f $place.Measurement.page, $place.Measurement.device
                & $add ('#### {0}' -f $label)
                & $add ''
                if ($listed.ContainsKey($signature)) {
                    & $add ('The same as {0}.' -f $listed[$signature])
                    & $add ''
                    continue
                }
                $listed[$signature] = $label
                foreach ($row in $rows) { & $add $row }
                if ($place.Finding.moreItems -gt 0) { & $add ('- and {0} more' -f $place.Finding.moreItems) }
                & $add ''
            }
        }
    }

    return $out.ToString()
}

function Save-Report {
    <#
    .SYNOPSIS
        Writes report.md and report.json into a folder of their own.

    .DESCRIPTION
        The two belong together, so both are written aside first and only
        then given their names; when the second cannot be named the first is
        taken back, and no folder is left holding half a report.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)][string]$Folder
    )

    [void](New-Item -ItemType Directory -Path $Folder -Force)

    $markdown = Get-ReportText -Run $Run
    $json = $Run | ConvertTo-Json -Depth 12

    $mdFinal = Join-Path -Path $Folder -ChildPath 'report.md'
    $jsonFinal = Join-Path -Path $Folder -ChildPath 'report.json'
    $mdTemp = $mdFinal + '.tmp'
    $jsonTemp = $jsonFinal + '.tmp'

    [IO.File]::WriteAllText($mdTemp, $markdown, $Script:Utf8)
    [IO.File]::WriteAllText($jsonTemp, $json, $Script:Utf8)

    if ((Get-Item -LiteralPath $mdTemp).Length -eq 0 -or (Get-Item -LiteralPath $jsonTemp).Length -eq 0) {
        throw 'The report came out empty and was not saved.'
    }

    Move-Item -LiteralPath $jsonTemp -Destination $jsonFinal -Force
    try {
        Move-Item -LiteralPath $mdTemp -Destination $mdFinal -Force
    } catch {
        Remove-Item -LiteralPath $jsonFinal -Force -ErrorAction SilentlyContinue
        throw
    }

    return $mdFinal
}

# --- a run -------------------------------------------------------------------------

function Invoke-Run {
    <#
    .SYNOPSIS
        Measures the chosen pages on both devices and writes the report.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Pages,
        [Parameter(Mandatory)]$Settings
    )

    $measurements = New-Object System.Collections.Generic.List[object]
    $total = $Pages.Count * $Script:Devices.Count
    $done = 0

    foreach ($target in $Pages) {
        foreach ($device in $Script:Devices) {
            $done++
            Write-Host ('Measuring {0} on {1} ({2}/{3}) ... ' -f $target.Name, $device, $done, $total) -NoNewline
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $measurement = Invoke-Measurement -Target $target -Device $device -Address $address -Settings $Settings
            $clock.Stop()
            if ($measurement.status -eq 'ok') {
                Write-Host ('done in {0} s' -f [math]::Round($clock.Elapsed.TotalSeconds)) -ForegroundColor Green
            } else {
                Write-Host 'failed' -ForegroundColor Red
                Write-Host ('  {0}' -f $measurement.error) -ForegroundColor Red
            }
            $measurements.Add($measurement)
        }
    }

    $list = $measurements.ToArray()
    $deployed = Get-DeployedVersion -Address $address -Measurements $list

    $warning = $null
    if ($deployed.Version -and $repositoryVersion -and $deployed.Version -ne $repositoryVersion) {
        $warning = ('The site runs {0} and the repository is at {1}. A finding may already be fixed in ' +
                    'the repository, or a fix may not be on the site yet.') -f $deployed.Version, $repositoryVersion
    }

    $lighthouse = @($list | Where-Object { $_.lighthouse } | ForEach-Object { $_.lighthouse } | Select-Object -First 1)
    $now = Get-Date

    $run = [pscustomobject][ordered]@{
        schema                = 1
        site                  = $address
        measuredAt            = $now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        measuredLocal         = $now.ToString('d. M. yyyy H:mm', $Script:Czech)
        scriptVersion         = $Script:ScriptVersion
        repositoryVersion     = $repositoryVersion
        deployedVersion       = $deployed.Version
        deployedVersionSource = $deployed.Source
        versionWarning        = $warning
        lighthouseVersion     = $(if ($lighthouse.Count) { $lighthouse[0] } else { $null })
        locale                = $Settings.Locale
        measurements          = $list
    }

    # --- the console ---
    Write-Host ''
    Write-Host ('Theme version on the site: {0}' -f $(if ($deployed.Version) { $deployed.Version } else { 'unknown' }))
    if ($warning) { Write-Host $warning -ForegroundColor Yellow }
    Write-Host ''
    Write-Host ('{0,-32} {1,-8} {2,5} {3,5} {4,5} {5,5}' -f 'Page', 'Device', 'Perf', 'A11y', 'Best', 'SEO')
    foreach ($m in $list) {
        Write-Host ('{0,-32} {1,-8}' -f $m.page, $m.device) -NoNewline
        if ($m.status -ne 'ok') { Write-Host '  failed' -ForegroundColor Red; continue }
        foreach ($c in $Script:Categories) {
            $s = $m.scores[$c]
            Write-Host (' {0,5}' -f $s) -NoNewline -ForegroundColor (Get-ScoreColour -Score $s)
        }
        Write-Host ''
    }

    $seen = [ordered]@{}
    foreach ($m in $list) {
        foreach ($f in $m.findings) {
            $key = '{0}|{1}' -f $f.category, $f.id
            if (-not $seen.Contains($key)) { $seen[$key] = [pscustomobject]@{ Finding = $f; Count = 0 } }
            $seen[$key].Count++
        }
    }

    Write-Host ''
    if ($seen.Count -eq 0) {
        Write-Host 'Nothing fell below 0.9.' -ForegroundColor Green
    } else {
        Write-Host 'Did not pass (measurements it turned up in):'
        $sorted = @($seen.Values | Sort-Object -Property @(
            @{ Expression = { -not $_.Finding.countsTowardScore } },
            @{ Expression = { [array]::IndexOf($Script:Categories, $_.Finding.category) } },
            @{ Expression = { $_.Finding.id } }
        ))
        foreach ($entry in $sorted) {
            $f = $entry.Finding
            $colour = if ($f.countsTowardScore) { 'Yellow' } else { 'DarkGray' }
            $note = if ($f.countsTowardScore) { '' } else { ', does not count' }
            Write-Host ('  [{0}] {1} ({2}{3})' -f $f.categoryTitle, $f.title, $entry.Count, $note) -ForegroundColor $colour
        }
    }

    $folder = Join-Path -Path $resultsRoot -ChildPath ($now.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture))
    try {
        $saved = Save-Report -Run $run -Folder $folder
        Write-Host ''
        Write-Host ('The report is in {0}' -f $saved) -ForegroundColor Green
        Write-Host 'report.json beside it holds the same findings for a program to read.'
    } catch {
        Write-Host ''
        Write-Host ('The report could not be saved: {0}' -f $_.Exception.Message) -ForegroundColor Red
    }
    Write-Host ''
}

# --- the repository -------------------------------------------------------------

$root = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path
$configPath = Join-Path -Path $root -ChildPath '_config.yml'

if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Host 'This is not the repository of a site.' -ForegroundColor Red
    Write-Host ('No _config.yml was found at {0}.' -f $configPath)
    Write-Host 'Run the script from the tests folder of the site it belongs to.'
    exit 1
}

$siteSettings = Get-SiteConfig -Path $configPath
$address = Get-AddressFromConfig -Settings $siteSettings

if (-not $address) {
    Write-Host 'The address of the site could not be found.' -ForegroundColor Red
    Write-Host ('There is no url in {0}.' -f $configPath)
    exit 1
}

$address = $address.TrimEnd('/')
$facts = Get-SiteFacts -Root $root
$targets = Get-MeasuredPages -Facts $facts
$repositoryVersion = Get-ChangelogVersion -Path (Join-Path -Path $root -ChildPath 'CHANGELOG.md')
$resultsRoot = Join-Path -Path $PSScriptRoot -ChildPath 'results'

if ($targets.Count -eq 0) {
    Write-Host 'There is nothing to measure.' -ForegroundColor Red
    exit 1
}

$apiSettings = Read-ApiSettings -Path (Join-Path -Path $PSScriptRoot -ChildPath 'pagespeed.config.json')
if ($null -eq $apiSettings) { exit 1 }

# --- the menu ----------------------------------------------------------------------

Write-Host ('Site: {0}' -f $address)
Write-Host ('Read from the repository at {0}' -f $root)
Write-Host ''

while ($true) {
    Write-Host 'What should be measured? Every page is measured on a phone and on a desktop.'
    Write-Host ''
    for ($i = 0; $i -lt $targets.Count; $i++) {
        Write-Host ('  {0}. {1,-32} {2}' -f ($i + 1), $targets[$i].Name, $targets[$i].Path)
    }
    Write-Host '  A. All of them'
    Write-Host '  Q. Quit'
    Write-Host ''

    $answer = (Read-Host 'Choice').Trim()

    if ($answer -match '^[Qq]$' -or $answer -eq '') { break }

    if ($answer -match '^[Aa]$') {
        Invoke-Run -Pages $targets -Settings $apiSettings
        continue
    }

    $number = 0
    if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $targets.Count) {
        Invoke-Run -Pages @($targets[$number - 1]) -Settings $apiSettings
        continue
    }

    Write-Host 'That is not one of the choices.' -ForegroundColor Yellow
    Write-Host ''
}

exit 0
