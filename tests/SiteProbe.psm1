<#
.SYNOPSIS
    Helpers for asking a published site a question over HTTP.

.DESCRIPTION
    One place for the two things every check needs: fetching an address
    without the call throwing on a status that is itself the answer, and
    pulling the addresses out of the returned HTML.

    Windows PowerShell 5.1 and PowerShell 7 disagree about what
    Invoke-WebRequest does with a status outside the 200 range and about the
    shape of the headers it returns. Both are dealt with here so that no check
    has to know which one it is running on.

.NOTES
    Copyright (c) 2025-2026 Michal Zobec, ZOBEC Consulting. All Rights Reserved.
    Web: https://www.michalzobec.cz
    Licensed under GNU General Public License 3
#>

#Requires -Version 5.1

Set-StrictMode -Version Latest

$Script:ScriptVersion = '26.10.28.2229'

# Windows PowerShell runs on the .NET Framework, which still offers TLS 1.0
# first unless it is told otherwise. Anything behind Cloudflare refuses that,
# and the request fails before it ever reaches the site, with a message about
# a secure channel that reads like a broken server. PowerShell 7 runs on
# .NET Core, where 1.2 and 1.3 are the default and nothing has to be set.
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

function Get-SiteProbeVersion {
    <#
    .SYNOPSIS
        The version of this file, for the banner of the runner.
    #>
    [CmdletBinding()]
    param()

    $Script:ScriptVersion
}

function Get-SiteResponse {
    <#
    .SYNOPSIS
        Fetches an address and returns its status, body and Location header.

    .DESCRIPTION
        Never throws on an HTTP status. A 404 is an answer to be asserted on,
        not a failure of the call, and so is a 301. The body comes back with
        an error status too, since an API explains a refusal there. A request that does not
        reach the server at all does throw, because that is a different thing
        and must not be mistaken for a status.

    .PARAMETER Url
        The absolute address to fetch.

    .PARAMETER NoRedirect
        Return the redirect itself instead of following it.

    .PARAMETER TimeoutSec
        How long to wait for the answer. Thirty seconds is plenty for a page
        of the site; a measurement by PageSpeed Insights takes longer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [switch]$NoRedirect,
        [ValidateRange(1, 600)][int]$TimeoutSec = 30
    )

    $parameters = @{
        Uri             = $Url
        Method          = 'Get'
        UseBasicParsing = $true
        TimeoutSec      = $TimeoutSec
        ErrorAction     = 'Stop'
    }

    if ($NoRedirect) { $parameters['MaximumRedirection'] = 0 }

    # SkipHttpErrorCheck on PowerShell 7 would save the catch below, but it
    # cannot be used: together with MaximumRedirection 0 the redirect is
    # reported as a plain InvalidOperationException carrying no response at
    # all, so the address it pointed at is lost. Letting the call throw and
    # reading the response out of the exception is the one way that works the
    # same on 5.1 and on 7.
    try {
        $response = Invoke-WebRequest @parameters
        return (New-ProbeResult -StatusCode ([int]$response.StatusCode) `
                                -Content (ConvertTo-PageText -Response $response) `
                                -Response $response)
    } catch {
        # Under Set-StrictMode a property that is not there throws rather than
        # answering nothing, so it is asked for by name.
        $exception = $_.Exception
        $carries = $exception.PSObject.Properties['Response']
        if ($null -eq $carries -or $null -eq $carries.Value) { throw }

        $failed = $carries.Value

        $status = 0
        try { $status = [int]$failed.StatusCode } catch { $status = 0 }

        # The body of an error is kept as well. A page of the site that is not
        # there has nothing worth reading in it, but an API says in its body
        # why it refused, and the status alone does not tell a key that is
        # wrong from a quota that is spent. Both editions of PowerShell put
        # that body into ErrorDetails.
        $body = ''
        if ($null -ne $_.ErrorDetails -and $_.ErrorDetails.Message) {
            $body = [string]$_.ErrorDetails.Message
        }

        return (New-ProbeResult -StatusCode $status -Content $body -Response $failed)
    }
}

function ConvertTo-PageText {
    <#
    .SYNOPSIS
        The body of a response, read as UTF-8.

    .DESCRIPTION
        Jekyll writes every file of the site as UTF-8. Whether the string
        Invoke-WebRequest hands back says the same depends on the Content-Type
        the host puts on the file: with a type it does not know as text it
        decodes the bytes as Latin-1 instead, and every Czech letter becomes
        two. Measured on a local server: application/xml, text/xml,
        application/atom+xml and application/rss+xml all come back right,
        application/octet-stream does not, and some hosts serve a feed as
        exactly that.

        The bytes are therefore read back and decoded as UTF-8, unless the
        response names a charset of its own that is not UTF-8.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Response)

    $declared = ''
    try {
        $header = $Response.Headers['Content-Type']
        if ($header) { $declared = ($header -join ' ') }
    } catch { $declared = '' }

    if ($declared -match 'charset\s*=\s*"?([^";\s]+)') {
        if ($Matches[1] -notmatch '^(?i)utf-?8$') { return [string]$Response.Content }
    }

    $stream = $null
    try { $stream = $Response.RawContentStream } catch { return [string]$Response.Content }
    if ($null -eq $stream) { return [string]$Response.Content }

    try {
        $stream.Position = 0
        $bytes = New-Object byte[] $stream.Length
        $read = $stream.Read($bytes, 0, $bytes.Length)
        $stream.Position = 0
        if ($read -le 0) { return [string]$Response.Content }

        $text = [Text.Encoding]::UTF8.GetString($bytes, 0, $read)
        return $text.TrimStart([char]0xFEFF)
    } catch {
        return [string]$Response.Content
    }
}

function New-ProbeResult {
    # New- is a verb PSScriptAnalyzer reads as changing the state of the
    # machine, and asks for ShouldProcess on anything carrying it. This one
    # builds a hashtable in memory and changes nothing at all, so the rule is
    # turned off here rather than everywhere.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an object in memory and changes nothing.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$StatusCode,
        [string]$Content = '',
        $Response = $null
    )

    [pscustomobject]@{
        StatusCode = $StatusCode
        Content    = $Content
        Location   = Get-LocationHeader -Response $Response
    }
}

function Get-LocationHeader {
    <#
    .SYNOPSIS
        The address a redirect points at, whatever kind of response carries it.

    .DESCRIPTION
        Three shapes turn up and none of them answers to the same thing. On
        PowerShell 7 a failed call hands back an HttpResponseMessage, whose
        headers have Location as a property of their own; a call that
        succeeded hands back headers that are a dictionary of arrays; on 5.1
        they are a collection answering to a name. A response with no Location
        is not an error, and the answer is then nothing.
    #>
    [CmdletBinding()]
    param($Response)

    if ($null -eq $Response) { return $null }

    $headers = $null
    $carries = $Response.PSObject.Properties['Headers']
    if ($null -ne $carries) { $headers = $carries.Value }
    if ($null -eq $headers) { return $null }

    # PowerShell 7, HttpResponseHeaders: Location is a Uri of its own.
    $named = $headers.PSObject.Properties['Location']
    if ($null -ne $named -and $null -ne $named.Value) {
        return [string]$named.Value
    }

    # Everything else answers to the name, either with a string or with an
    # array of them.
    $value = $null
    try { $value = $headers['Location'] } catch { $value = $null }
    if ($null -eq $value) { return $null }
    if ($value -is [string]) { return $value }

    $first = $value | Select-Object -First 1
    if ($null -eq $first) { return $null }

    [string]$first
}

function Get-LinkAddress {
    <#
    .SYNOPSIS
        The addresses of every link in a piece of HTML.

    .PARAMETER Html
        The body of the page.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Html
    )

    $found = New-Object System.Collections.Generic.List[string]

    foreach ($match in [regex]::Matches($Html, '<a\b[^>]*?\shref\s*=\s*(["''])(.*?)\1', 'IgnoreCase')) {
        $found.Add($match.Groups[2].Value)
    }

    # The comma keeps a single address from arriving at the caller as a bare
    # string instead of an array. The caller must not wrap this in @().
    return ,$found.ToArray()
}

function Get-LinkTag {
    <#
    .SYNOPSIS
        The whole opening tag of every link in a piece of HTML.

    .DESCRIPTION
        Get-LinkAddress answers where a link goes. This answers what the link
        itself says, which is what a check about an attribute needs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Html
    )

    $found = New-Object System.Collections.Generic.List[string]

    foreach ($match in [regex]::Matches($Html, '<a\b[^>]*>', 'IgnoreCase')) {
        $found.Add($match.Value)
    }

    # See Get-LinkAddress on the comma. The caller must not wrap this in @().
    return ,$found.ToArray()
}

function Test-LinkPresent {
    <#
    .SYNOPSIS
        Whether the HTML links to the given address.

    .DESCRIPTION
        The comparison ignores an absolute prefix, so that a link written as
        the whole address and one written from the root both count.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Html,
        [Parameter(Mandatory)][string]$Path
    )

    $addresses = Get-LinkAddress -Html $Html
    $wanted = $Path.TrimEnd('/')

    foreach ($address in $addresses) {
        $trimmed = $address.TrimEnd('/')
        if ($trimmed -eq $wanted) { return $true }
        if ($trimmed.EndsWith($wanted) -and $trimmed -match '^https?://') { return $true }
    }

    $false
}

Export-ModuleMember -Function Get-SiteProbeVersion, Get-SiteResponse, Get-LinkAddress, Get-LinkTag, Test-LinkPresent
