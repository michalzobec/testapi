<#
    Mundana Reworked | Facts about the site, read from its repository

    by Michal ZOBEC | Web: www.michalzobec.cz
    Copyright (c) 2025-2026 Michal Zobec, ZOBEC Consulting. All Rights Reserved.
    Licensed under GNU General Public License 3
#>

#Requires -Version 5.1

Set-StrictMode -Version Latest

$Script:ScriptVersion = '26.10.28.2229'

function Get-SiteFactsVersion { $Script:ScriptVersion }

function ConvertTo-Slug {
    <#
    .SYNOPSIS
        A name turned into the address Jekyll builds from it.

    .DESCRIPTION
        The same thing slugify: 'latin' does: the marks come off the letters,
        what is left goes to lower case and anything that is not a letter or a
        digit becomes a hyphen.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)

    $plain = ($Name.Normalize([Text.NormalizationForm]::FormD).ToCharArray() |
        Where-Object {
            [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne
            [Globalization.UnicodeCategory]::NonSpacingMark
        }) -join ''

    ($plain.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
}

function Get-FrontMatter {
    <#
    .SYNOPSIS
        The front matter of one article, as a hashtable.

    .DESCRIPTION
        Only the shapes the articles of this theme actually use are read: a
        scalar, a list written in brackets on one line, and a list written
        under the key with a hyphen on each line. That is enough and it saves
        the tests a YAML parser they would otherwise have to carry.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $front = @{}
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $match = [regex]::Match($text, "(?s)\A---\s*\r?\n(.*?)\r?\n---\s*\r?\n")
    if (-not $match.Success) { return $front }

    $key = $null
    $list = $null

    foreach ($line in ($match.Groups[1].Value -split "`r?`n")) {
        if ($line -match '^\s*#') { continue }

        if ($null -ne $list -and $line -match '^\s+-\s*(.+?)\s*$') {
            $list.Add(($Matches[1].Trim('"').Trim("'"))) | Out-Null
            continue
        }

        if ($null -ne $list) {
            $front[$key] = $list.ToArray()
            $list = $null
        }

        if ($line -notmatch '^([A-Za-z0-9_]+)\s*:\s*(.*)$') { continue }

        $key = $Matches[1]
        $raw = $Matches[2].Trim()

        if ($raw -eq '') {
            $list = [System.Collections.ArrayList]::new()
            $front[$key] = @()
            continue
        }

        if ($raw -match '^\[(.*)\]$') {
            $front[$key] = @($Matches[1] -split ',' |
                ForEach-Object { $_.Trim().Trim('"').Trim("'") } |
                Where-Object { $_ -ne '' })
            continue
        }

        $value = $raw.Trim('"').Trim("'")
        $front[$key] = switch -Regex ($value) {
            '^(?i)true$'  { $true; break }
            '^(?i)false$' { $false; break }
            default       { $value }
        }
    }

    if ($null -ne $list) { $front[$key] = $list.ToArray() }

    return $front
}

function Get-DataKeys {
    <#
    .SYNOPSIS
        The keys at the top level of one file in _data.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $keys = @()
    if (-not (Test-Path -LiteralPath $Path)) { return $keys }

    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ($line -match '^\s' -or $line -match '^\s*#') { continue }
        if ($line -match '^(?:"([^"]+)"|''([^'']+)''|([^:#]+?))\s*:\s*$') {
            $keys += @($Matches[1], $Matches[2], $Matches[3] | Where-Object { $_ })[0]
        }
    }

    return $keys
}

function Get-LanguageStrings {
    <#
    .SYNOPSIS
        The strings of one language file, as a hashtable.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $strings = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $strings }

    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ($line -match '^([a-z0-9_]+)\s*:\s*(.+?)\s*$') {
            $strings[$Matches[1]] = $Matches[2].Trim('"').Trim("'")
        }
    }

    return $strings
}

function Get-SiteConfig {
    <#
    .SYNOPSIS
        The settings of the site, read out of its _config.yml.

    .DESCRIPTION
        Only keys standing at the beginning of a line are read, which is where
        a top level key stands, plus the keys nested under analytics, social,
        organization and contact, which come back as analytics_<key> and so
        on. true and false come back as booleans, an empty value as $null.
        That is enough here and it saves the tests a YAML parser they would
        otherwise carry.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $settings = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $settings }

    # The blocks whose nested keys are worth having. Anything else nested is
    # skipped, the way it always was.
    $nested = @('analytics', 'social', 'organization', 'contact')
    $parent = $null

    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $key = $null
        $raw = $null

        if ($line -match '^([a-z0-9_]+)\s*:\s*(.*)$') {
            if ($nested -contains $Matches[1] -and $Matches[2].Trim() -eq '') {
                $parent = $Matches[1]
                continue
            }

            $parent = $null
            $key = $Matches[1]
            $raw = $Matches[2]
        } elseif ($parent -and $line -match '^\s+([a-z0-9_]+)\s*:\s*(.*)$') {
            $key = $parent + '_' + $Matches[1]
            $raw = $Matches[2]
        } elseif ($line.Trim() -ne '' -and $line -notmatch '^\s') {
            $parent = $null
        }

        if ($null -eq $key -or $settings.ContainsKey($key)) { continue }

        # Anything after a hash is a comment, unless it stands inside the
        # quotes around the value.
        if ($raw -notmatch '^\s*["'']') { $raw = ($raw -split '#')[0] }
        $value = $raw.Trim().Trim('"').Trim("'").Trim()

        $settings[$key] = switch -Regex ($value) {
            '^$'          { $null; break }
            '^(?i)true$'  { $true; break }
            '^(?i)false$' { $false; break }
            default       { $value }
        }
    }

    return $settings
}

function Get-AddressFromConfig {
    <#
    .SYNOPSIS
        The address of the site, made of url and baseurl.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Settings)

    $url = $Settings['url']
    if ([string]::IsNullOrWhiteSpace($url)) { return $null }

    $base = $Settings['baseurl']
    if ([string]::IsNullOrWhiteSpace($base)) { $base = '' }

    ($url.TrimEnd('/') + '/' + $base.Trim('/')).TrimEnd('/')
}

function Get-ChangelogVersion {
    <#
    .SYNOPSIS
        The version at the top of CHANGELOG.md, or nothing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $match = [regex]::Match($text, '(?m)^##\s+(\d{2}\.\d{2}\.\d{2}\.\d{4})\s*$')

    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

function Get-GeneratorVersion {
    <#
    .SYNOPSIS
        The version a built page says it was made with, or nothing.

    .DESCRIPTION
        Every page carries it in the generator meta, which is where the theme
        writes the version it was built from.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Html)

    $match = [regex]::Match($Html, 'name=["'']generator["''][^>]*version\s+(\d{2}\.\d{2}\.\d{2}\.\d{4})')

    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

function Get-SiteFacts {
    <#
    .SYNOPSIS
        Everything the tests need to know about one site, read from its own
        repository.

    .DESCRIPTION
        Nothing here is written down by hand. The articles, the categories,
        the authors and the series are counted out of the repository the tests
        are run from, so publishing an article or adding a category changes
        what is tested without anybody having to remember to say so.

        The one thing that cannot be read is the list of sites that do not
        count as leading away: the build downloads it and it is not in the
        repository. The article with an outside link is therefore the first
        one linking to a host other than the site itself, which on a site that
        links only to its own publisher could pick a link that is not marked.
        The test then says which link it was, which is enough to see it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $settings = Get-SiteConfig -Path (Join-Path -Path $Root -ChildPath '_config.yml')

    $lang = if ($settings.ContainsKey('lang_ui') -and $settings['lang_ui']) { $settings['lang_ui'] } else { 'cs' }
    $strings = Get-LanguageStrings -Path (Join-Path -Path $Root -ChildPath ('_data/lang/{0}.yml' -f $lang))

    $perPage = 8
    if ($settings.ContainsKey('archivepaginate') -and $settings['archivepaginate']) {
        $perPage = [int]$settings['archivepaginate']
    }

    $ownHost = ''
    if ($settings.ContainsKey('url') -and $settings['url']) {
        $ownHost = ([uri]$settings['url']).Host
    }

    # --- the articles -------------------------------------------------------
    $posts = @()
    $postsDir = Join-Path -Path $Root -ChildPath '_posts'

    foreach ($file in (Get-ChildItem -LiteralPath $postsDir -File | Sort-Object -Property Name)) {
        $front = Get-FrontMatter -Path $file.FullName
        if ($front.Count -eq 0) { continue }

        $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        $body = [regex]::Replace($text, "(?s)\A---\s*\r?\n.*?\r?\n---\s*\r?\n", '')

        # An article about Markdown shows images and addresses as examples
        # inside code. Those are not images of the article and not links out
        # of it, so the code goes first.
        $prose = [regex]::Replace($body, '(?ms)^ *(```|~~~).*?^ *\1[^\n]*$', '')
        $prose = [regex]::Replace($prose, '`[^`\n]*`', '')

        $slug = $file.BaseName -replace '^\d{4}-\d{2}-\d{2}-', ''
        $url = if ($front.ContainsKey('permalink')) { $front['permalink'] } else { '/' + $slug + '/' }

        $categories = @()
        if ($front.ContainsKey('categories')) { $categories = @($front['categories']) }
        elseif ($front.ContainsKey('category')) { $categories = @($front['category']) }

        $posts += [pscustomobject]@{
            Url          = $url
            Name         = $file.Name
            Categories   = @($categories | ForEach-Object { ConvertTo-Slug -Name $_ })
            Author       = if ($front.ContainsKey('author')) { [string]$front['author'] } else { '' }
            Series       = if ($front.ContainsKey('series')) { [string]$front['series'] } else { '' }
            SeriesPart   = if ($front.ContainsKey('seriespart')) { [int]$front['seriespart'] } else { 0 }
            Commercial   = ($front.ContainsKey('commercial') -and $front['commercial'] -eq $true)
            RedirectFrom = if ($front.ContainsKey('redirect_from')) { @($front['redirect_from']) } else { @() }
            Headings     = ([regex]::Matches($prose, '(?m)^##\s')).Count
            Images       = ([regex]::Matches($prose, '!\[')).Count
            Prose        = $prose
        }
    }

    $newest = @($posts | Sort-Object -Property Name -Descending)

    # --- the categories, the authors and the series -------------------------
    $categoryKeys = Get-DataKeys -Path (Join-Path -Path $Root -ChildPath '_data/categories.yml')
    $categories = @($categoryKeys | ForEach-Object { ConvertTo-Slug -Name $_ })
    $authors = @(Get-DataKeys -Path (Join-Path -Path $Root -ChildPath '_data/authors.yml'))
    $series = @(Get-DataKeys -Path (Join-Path -Path $Root -ChildPath '_data/series.yml'))

    $inCategory = @{}
    foreach ($category in $categories) {
        $inCategory[$category] = @($posts | Where-Object { $_.Categories -contains $category }).Count
    }

    $byAuthor = @{}
    foreach ($author in $authors) {
        $byAuthor[$author] = @($posts | Where-Object { $_.Author -eq $author }).Count
    }

    $paged = @($categories | Where-Object { $inCategory[$_] -gt $perPage } | Sort-Object { -$inCategory[$_] })
    $single = @($categories | Where-Object { $inCategory[$_] -gt 0 -and $inCategory[$_] -le $perPage })
    $thin = @($categories | Where-Object { $inCategory[$_] -lt 3 })
    $indexed = @($categories | Where-Object { $inCategory[$_] -ge 3 })

    # --- the longest series and the part in the middle of it ----------------
    $bestSeries = ''
    $bestCount = 0
    foreach ($one in $series) {
        $count = @($posts | Where-Object { $_.Series -eq $one }).Count
        if ($count -gt $bestCount) { $bestCount = $count; $bestSeries = $one }
    }

    $partUrls = @($posts |
        Where-Object { $_.Series -eq $bestSeries -and $_.SeriesPart -gt 0 } |
        Sort-Object -Property SeriesPart |
        ForEach-Object { $_.Url })

    $middle = if ($partUrls.Count -ge 3) { $partUrls[[int]($partUrls.Count / 2)] } else { '' }

    # --- the pages ----------------------------------------------------------
    $pages = @()
    $pagesDir = Join-Path -Path $Root -ChildPath '_pages'
    if (Test-Path -LiteralPath $pagesDir) {
        foreach ($file in (Get-ChildItem -LiteralPath $pagesDir -File | Sort-Object -Property Name)) {
            $front = Get-FrontMatter -Path $file.FullName
            if (-not $front.ContainsKey('permalink')) { continue }

            $permalink = [string]$front['permalink']
            if ($permalink -match '404') { continue }
            $pages += $permalink
        }
    }

    # --- the one article each kind of test needs ----------------------------
    # The features of an article show on an article long enough to have them,
    # so the one with the most headings is taken rather than any one at all.
    $featureArticle = @($posts | Sort-Object -Property Headings -Descending | Select-Object -First 1)
    # The article that shows the most pictures is the one built to show them,
    # so that is where the viewer and the grid are looked for.
    $withImages = @($posts | Where-Object { $_.Images -gt 0 } | Sort-Object -Property Images -Descending | Select-Object -First 1)

    $outsideUrl = ''
    $outsideHost = ''
    foreach ($post in $posts) {
        foreach ($link in [regex]::Matches($post.Prose, 'https?://([a-z0-9.-]+)')) {
            $linkHost = $link.Groups[1].Value
            if ($ownHost -and ($linkHost -eq $ownHost -or $linkHost.EndsWith(".$ownHost"))) { continue }
            $outsideUrl = $post.Url
            $outsideHost = $linkHost
            break
        }
        if ($outsideUrl) { break }
    }

    # Paid content. Which article it is stands in its own front matter, so it
    # is read from there, and the words of the mark come from the language
    # file the layouts take them from as well.
    $paid = @($posts | Where-Object { $_.Commercial } | Select-Object -First 1)
    $paidUrl = ''
    $paidListing = ''
    if ($paid.Count) {
        $paidUrl = $paid[0].Url
        $category = @($paid[0].Categories)[0]
        if ($category) {
            $path = if ($strings.ContainsKey('path_categories')) { $strings['path_categories'] } else { 'kategorie' }
            $paidListing = "/$path/$category/"
        }
    }

    $redirects = @()
    foreach ($post in $posts) {
        foreach ($from in $post.RedirectFrom) {
            $redirects += @{ From = $from; To = $post.Url }
        }
    }

    $suffix = ''
    if ($strings.ContainsKey('page_suffix')) { $suffix = $strings['page_suffix'] -replace '%num%', '2' }

    @{
        PerPage = $perPage

        Paths = @{
            Categories = if ($strings.ContainsKey('path_categories')) { $strings['path_categories'] } else { 'kategorie' }
            Authors    = if ($strings.ContainsKey('path_authors')) { $strings['path_authors'] } else { 'autori' }
            Series     = if ($strings.ContainsKey('path_series')) { $strings['path_series'] } else { 'serialy' }
        }

        Categories         = $categories
        PagedCategory      = if ($paged.Count) { $paged[0] } else { '' }
        SinglePageCategory = if ($single.Count) { $single[0] } else { '' }
        ThinCategories     = $thin
        IndexedCategory    = if ($indexed.Count) { $indexed[0] } else { '' }

        Authors     = $authors
        EmptyAuthor = @($authors | Where-Object { $byAuthor[$_] -eq 0 } | Select-Object -First 1)
        PagedAuthor = @($authors | Where-Object { $byAuthor[$_] -gt $perPage } | Select-Object -First 1)

        Series              = $series
        SeriesPartUrls      = $partUrls
        SeriesMiddleArticle = $middle

        Pages    = $pages
        Articles = @($newest | Select-Object -First 3 | ForEach-Object { $_.Url })

        FeatureArticle         = if ($featureArticle.Count) { $featureArticle[0].Url } else { '' }
        ArticleWithImages      = if ($withImages.Count) { $withImages[0].Url } else { '' }
        ArticleWithOutsideLink = $outsideUrl
        OutsideLinkHost        = $outsideHost

        # Empty on a site with no paid article, and the tests of it are then
        # skipped.
        CommercialArticle = $paidUrl
        CommercialListing = $paidListing
        CommercialLabel   = if ($strings.ContainsKey('commercial_label')) { $strings['commercial_label'] } else { '' }
        SeriesLabel       = if ($strings.ContainsKey('series_label')) { $strings['series_label'] } else { '' }

        SecondPageTitlePart = $suffix
        Redirects           = $redirects

        # The theme builds these whatever the site holds.
        Assets = @(
            '/assets/css/main.css'
            '/assets/css/theme.css'
            '/assets/js/theme.js'
            '/assets/js/lightbox.js'
        )
        Files = @(
            '/feed.xml'
            '/sitemap.xml'
            '/robots.txt'
            '/search-index.json'
        )

        # An address no site has, for the test that a missing page says so.
        Missing = @('/this-address-is-not-on-the-site/')
    }
}

function Get-MeasuredPages {
    <#
    .SYNOPSIS
        The pages worth measuring for speed and accessibility.

    .DESCRIPTION
        Each is the worst case of its kind rather than a page picked at random,
        so a page that passes is not the easiest one on the site: the home page,
        the article carrying the most pictures, a category archive that runs to
        more than one page and a static page. The performance check and the
        PageSpeed report both measure these, so the choice is made here once.

        Returns an array, empty when the repository offers nothing to measure.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Facts)

    $targets = New-Object System.Collections.Generic.List[object]

    $targets.Add([pscustomobject]@{ Name = 'Home page'; Path = '/' })

    $article = if ($Facts.ArticleWithImages) {
        $Facts.ArticleWithImages
    } elseif (@($Facts.Articles).Count) {
        @($Facts.Articles)[0]
    } else {
        ''
    }
    if ($article) {
        $targets.Add([pscustomobject]@{ Name = 'Article with the most pictures'; Path = $article })
    }

    $category = if ($Facts.PagedCategory) { $Facts.PagedCategory } else { $Facts.IndexedCategory }
    if ($category) {
        $targets.Add([pscustomobject]@{
            Name = 'Category archive'
            Path = ('/{0}/{1}/' -f $Facts.Paths.Categories, $category)
        })
    }

    $page = @($Facts.Pages | Where-Object { $_ -and $_ -ne '/' } | Select-Object -First 1)
    if ($page.Count) {
        $targets.Add([pscustomobject]@{ Name = 'Static page'; Path = $page[0] })
    }

    # The comma keeps a list of one from being handed back as the one item.
    return ,$targets.ToArray()
}

Export-ModuleMember -Function Get-SiteFactsVersion, ConvertTo-Slug, Get-FrontMatter,
    Get-DataKeys, Get-LanguageStrings, Get-SiteConfig, Get-AddressFromConfig, Get-SiteFacts,
    Get-ChangelogVersion, Get-GeneratorVersion, Get-MeasuredPages
