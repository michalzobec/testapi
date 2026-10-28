<#
.SYNOPSIS
    Smoke tests for a published Mundana Reworked site.

.DESCRIPTION
    Asks a deployed site whether it still stands: whether the addresses answer,
    whether the redirects lead where they should, whether a missing address
    says so, and whether what is built from the articles - the archives, the
    pagination, the series, the generated files - still holds together.

    Everything here goes over HTTP and nothing runs a browser, so anything the
    reader's browser does is out of reach: the viewer for pictures, the mark
    on a picture that opens, the search, the switch between light and dark.
    See README.md.

    Run through Invoke-SmokeTest.ps1 rather than directly; it is what hands
    over the expectations of the site being tested.

.NOTES
    Copyright (c) 2025-2026 Michal Zobec, ZOBEC Consulting. All Rights Reserved.
    Web: https://www.michalzobec.cz
    Licensed under GNU General Public License 3
#>

#Requires -Version 5.1

param(
    [Parameter(Mandatory)]
    [hashtable]$Config,

    # The switches of the site, read out of its _config.yml by the runner. A
    # feature is asked about where it is switched on, and asked to be absent
    # where it is not, which is what catches a switch that does nothing.
    [hashtable]$Settings = @{}
)

Set-StrictMode -Version Latest

$Script:ScriptVersion = '26.10.28.2229'

# Built while the tests are being discovered, so that each address becomes a
# test of its own and a failure names the address rather than a list.
$Script:Base = $Config.BaseUrl.TrimEnd('/')
$Script:CategoriesPath = $Config.Paths.Categories
$Script:AuthorsPath = $Config.Paths.Authors
$Script:SeriesPath = $Config.Paths.Series

$Script:CategoryArchives = $Config.Categories | ForEach-Object { "/$Script:CategoriesPath/$_/" }
$Script:AuthorArchives = $Config.Authors | ForEach-Object { "/$Script:AuthorsPath/$_/" }
$Script:SeriesArchives = $Config.Series | ForEach-Object { "/$Script:SeriesPath/$_/" }

# The changelog of the theme, for the version the site says it was built
# from. The tests are usually run from the repository, but they do not have to
# be, and without it that one check is skipped rather than failed.

$Script:MustAnswer = @('/') +
    @("/$Script:CategoriesPath/", "/$Script:AuthorsPath/", "/$Script:SeriesPath/") +
    $Script:CategoryArchives + $Script:AuthorArchives + $Script:SeriesArchives +
    $Config.Pages + $Config.Articles + $Config.Files + $Config.Assets

# What each switch in the configuration leaves in the HTML. The marker is a
# class or an attribute the feature writes and nothing else does, and Page
# says which of the pages fetched below has to carry it.
$Script:Measured = $false
foreach ($key in 'analytics_google_analytics', 'analytics_microsoft_clarity', 'analytics_meta_pixel') {
    if (-not [string]::IsNullOrWhiteSpace([string]$Settings[$key])) { $Script:Measured = $true }
}

$Script:Features = @(
    @{ Name = 'the switch between light and dark'; Page = 'Home';    Marker = 'themeswitch';          On = [bool]$Settings['darkmode'] }
    @{ Name = 'the block of the publisher';        Page = 'Home';    Marker = 'publisher-footer';     On = [bool]$Settings['publisherblock'] }
    @{ Name = 'the news of the other sites';       Page = 'Home';    Marker = 'publisher-news';       On = [bool]$Settings['publisherblocknews'] }
    @{ Name = 'the warning before leaving';        Page = 'Home';    Marker = 'external-warning';     On = [bool]$Settings['externallinkwarning'] }
    @{ Name = 'the button from Google';            Page = 'Home';    Marker = 'swg/js/v1/publisher';  On = [bool]$Settings['google_preferred_source'] }
    @{ Name = 'the strip of a test instance';      Page = 'Home';    Marker = 'devtest-banner';       On = [bool]$Settings['devtest_mode'] }
    @{ Name = 'the bar asking about measuring';    Page = 'Home';    Marker = 'consent-bar';          On = ([bool]$Settings['consent'] -and $Script:Measured) }
    @{ Name = 'measuring by Google';               Page = 'Home';    Marker = 'googletagmanager.com/gtag/js'; On = (-not [string]::IsNullOrWhiteSpace([string]$Settings['analytics_google_analytics'])) }
    @{ Name = 'measuring by Clarity';              Page = 'Home';    Marker = 'clarity.ms/tag/';      On = (-not [string]::IsNullOrWhiteSpace([string]$Settings['analytics_microsoft_clarity'])) }
    @{ Name = 'the pixel of Meta';                 Page = 'Home';    Marker = 'connect.facebook.net'; On = (-not [string]::IsNullOrWhiteSpace([string]$Settings['analytics_meta_pixel'])) }
    @{ Name = 'the viewer for the pictures';       Page = 'Images';  Marker = 'data-viewer-script';   On = [bool]$Settings['imageviewer'] }
    @{ Name = 'the grid of thumbnails';            Page = 'Images';  Marker = 'image-grid';           On = [bool]$Settings['imagegrid'] }
    @{ Name = 'the table of contents';             Page = 'Article'; Marker = '<details class="toc"'; On = [bool]$Settings['tocblock'] }
    @{ Name = 'the articles on the same subject';  Page = 'Article'; Marker = 'related-block';        On = [bool]$Settings['relatedblock'] }
    @{ Name = 'the call to action';                Page = 'Article'; Marker = 'cta-block';            On = [bool]$Settings['ctablock'] }
    @{ Name = 'the dialog for feedback';           Page = 'Article'; Marker = 'feedback-block';       On = [bool]$Settings['feedbackblock'] }
    @{ Name = 'the box listing the parts';         Page = 'Middle';  Marker = 'series-block';         On = [bool]$Settings['seriesblock'] }
    @{ Name = 'the links to the parts beside';     Page = 'Middle';  Marker = 'series-nav';           On = [bool]$Settings['seriesnav'] }
    @{ Name = 'fetching the next page ahead';      Page = 'Home';    Marker = 'speculationrules';     On = [bool]$Settings['prefetch'] }
)

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'SiteProbe.psm1') -Force

    # Pester reads the file twice: once to find out what the tests are, and
    # again to run them. What is set at the top of the file belongs to the
    # first pass only, so everything the tests themselves reach for is set
    # here as well. The values come from $Config either way, which Pester
    # hands to both passes, so there is still one source of them.
    #
    # The rule that follows from it: -Skip and -ForEach are read during the
    # first pass, so they may only ask $Config, $Settings or something set at
    # the top of this file. A -Skip asking a $Script: variable set here reads
    # nothing, and under Set-StrictMode the whole file fails to be read at
    # all. It has happened twice.
    $Script:Base = $Config.BaseUrl.TrimEnd('/')
    $Script:CategoriesPath = $Config.Paths.Categories
    $Script:AuthorsPath = $Config.Paths.Authors
    $Script:SeriesPath = $Config.Paths.Series
    $Script:CategoryArchives = $Config.Categories | ForEach-Object { "/$Script:CategoriesPath/$_/" }
    $Script:AuthorArchives = $Config.Authors | ForEach-Object { "/$Script:AuthorsPath/$_/" }
    $Script:SeriesArchives = $Config.Series | ForEach-Object { "/$Script:SeriesPath/$_/" }

    function Get-Address {
        param([Parameter(Mandatory)][string]$Path)
        $Script:Base + '/' + $Path.TrimStart('/')
    }

    function Get-Page {
        param([Parameter(Mandatory)][string]$Path)
        Get-SiteResponse -Url (Get-Address -Path $Path)
    }
}

Describe 'Every address answers' {
    It 'answers with 200: <_>' -ForEach $Script:MustAnswer {
        $response = Get-Page -Path $_
        $response.StatusCode | Should -Be 200 -Because "$_ has to be there"
    }
}

Describe 'A missing address says so' {
    It 'answers with 404: <_>' -ForEach $Config.Missing {
        (Get-Page -Path $_).StatusCode | Should -Be 404
    }

    It 'has a page of its own for 404' {
        (Get-Page -Path '/404.html').StatusCode | Should -Be 200
    }
}

Describe 'An address an article used to have' {
    # Renaming an article and leaving its earlier address pointing at the new
    # one is what the redirect is for, so that is what is asked about here. The
    # theme also redirects the addresses the original Mundana used, but a site
    # built from this theme never had them, and a test of them would be a test
    # of a history the site does not have.
    #
    # A static site has no server to answer 301 with, so jekyll-redirect-from
    # writes a page instead: it answers 200 and carries the new address in a
    # meta refresh, in the canonical and in a link for the reader. That is the
    # redirect on GitHub Pages and it is what is checked here. Behind a server
    # that does answer 301 the first branch takes over, so the same test holds
    # either way.
    It 'redirects <from> to <to>' -ForEach $Config.Redirects {
        $response = Get-SiteResponse -Url (Get-Address -Path $_.From) -NoRedirect
        $target = $_.To.TrimEnd('/')

        if ($response.StatusCode -in @(301, 302, 307, 308)) {
            $response.Location | Should -Not -BeNullOrEmpty -Because 'a redirect has to say where to'
            $response.Location.TrimEnd('/') | Should -BeLike ('*' + $target) -Because 'and it has to be the first page, not page two of something'
        } else {
            $response.StatusCode | Should -Be 200 -Because 'the older address has to lead somewhere, by a page if not by a header'
            $response.Content | Should -BeLike '*http-equiv*refresh*' -Because 'the page standing in for the redirect carries one'
            $response.Content | Should -BeLike ('*' + $target + '*') -Because 'and it has to point at the first page, not at page two of something'
        }
    }
}

Describe 'Pagination' {
    It 'gives the paged category a second page' {
        (Get-Page -Path "/$Script:CategoriesPath/$($Config.PagedCategory)/2/").StatusCode | Should -Be 200
    }

    It 'gives the paged author a second page' {
        (Get-Page -Path "/$Script:AuthorsPath/$($Config.PagedAuthor)/2/").StatusCode | Should -Be 200
    }

    It 'gives no second page to a category that fits on one' {
        (Get-Page -Path "/$Script:CategoriesPath/$($Config.SinglePageCategory)/2/").StatusCode | Should -Be 404
    }

    It 'links from the first page of the paged category to the second' {
        $html = (Get-Page -Path "/$Script:CategoriesPath/$($Config.PagedCategory)/").Content
        Test-LinkPresent -Html $html -Path "/$Script:CategoriesPath/$($Config.PagedCategory)/2/" | Should -BeTrue
    }

    It 'links from the second page back to the first' {
        $html = (Get-Page -Path "/$Script:CategoriesPath/$($Config.PagedCategory)/2/").Content
        Test-LinkPresent -Html $html -Path "/$Script:CategoriesPath/$($Config.PagedCategory)/" | Should -BeTrue
    }

    It 'gives the home page a second page and links to it' {
        $html = (Get-Page -Path '/').Content
        Test-LinkPresent -Html $html -Path '/page2/' | Should -BeTrue
        (Get-Page -Path '/page2/').StatusCode | Should -Be 200
    }
}

Describe 'The head of a page' {
    BeforeAll {
        $Script:ArticleHtml = (Get-Page -Path $Config.Articles[0]).Content
    }

    It 'has a title' {
        $Script:ArticleHtml | Should -Match '<title>[^<]+</title>'
    }

    It 'has a description' {
        $Script:ArticleHtml | Should -Match '<meta[^>]+name=["'']description["''][^>]+content=["''][^"'']+'
    }

    It 'has a canonical address' {
        $Script:ArticleHtml | Should -Match '<link[^>]+rel=["'']canonical["'']'
    }

    It 'has the tags a shared link needs' {
        $Script:ArticleHtml | Should -Match 'property=["'']og:title["'']'
    }

    It 'has structured data' {
        $Script:ArticleHtml | Should -Match 'application/ld\+json'
    }

    It 'says in the title of a second page that it is one' {
        $html = (Get-Page -Path "/$Script:CategoriesPath/$($Config.PagedCategory)/2/").Content
        $html | Should -Match ([regex]::Escape($Config.SecondPageTitlePart))
    }
}

Describe 'An article' {
    BeforeAll {
        $Script:SeriesHtml = (Get-Page -Path $Config.SeriesMiddleArticle).Content
        $Script:ImagesHtml = (Get-Page -Path $Config.ArticleWithImages).Content
    }

    It 'in a series links to the archive of that series' {
        Test-LinkPresent -Html $Script:SeriesHtml -Path "/$Script:SeriesPath/$($Config.Series[0])/" | Should -BeTrue
    }

    It 'in the middle of a series links to the part before it' {
        $index = [array]::IndexOf($Config.SeriesPartUrls, $Config.SeriesMiddleArticle)
        $index | Should -BeGreaterThan 0 -Because 'the article picked has to have a part before it'
        Test-LinkPresent -Html $Script:SeriesHtml -Path $Config.SeriesPartUrls[$index - 1] | Should -BeTrue
    }

    It 'in the middle of a series links to the part after it' {
        $index = [array]::IndexOf($Config.SeriesPartUrls, $Config.SeriesMiddleArticle)
        $index | Should -BeLessThan ($Config.SeriesPartUrls.Count - 1) -Because 'the article picked has to have a part after it'
        Test-LinkPresent -Html $Script:SeriesHtml -Path $Config.SeriesPartUrls[$index + 1] | Should -BeTrue
    }

    It 'holds pictures offered in several sizes' {
        $Script:ImagesHtml | Should -Match '<img[^>]+srcset='
    }

    It 'has a trail of where it sits' {
        $Script:SeriesHtml | Should -Match 'breadcrumb'
    }

    # A part of a series says so over its lead and in every listing it appears
    # in, the same way paid content does.
    It 'in a series says so over its lead' -Skip:(-not $Config.SeriesLabel) {
        $Script:SeriesHtml | Should -BeLike '*content-banner*'
        $Script:SeriesHtml | Should -BeLike "*$($Config.SeriesLabel)*"
    }

    It 'in a series carries the mark in the archive of that series' -Skip:(-not $Config.SeriesLabel) {
        $archive = (Get-Page -Path "/$Script:SeriesPath/$($Config.Series[0])/").Content
        $archive | Should -BeLike '*content-tag*'
        $archive | Should -BeLike "*$($Config.SeriesLabel)*"
    }

    # The button is written into the page hidden and theme.js is what shows it.
    # That is the whole of what a test outside a browser can see, and it is the
    # part that matters: the markup is there and it does not show itself to a
    # reader whose browser would have nothing to move the page with.
    It 'offers the way back to the beginning of the page, hidden until the script shows it' {
        $Script:SeriesHtml | Should -Match 'id="back-to-top"'
        $Script:SeriesHtml | Should -Match '<button[^>]+id="back-to-top"[^>]*\shidden'
    }
}

# Paid content. Which article was paid for is written in its own front matter
# and the words of the mark in the language file, so both are read from the
# repository like everything else. A site with no paid article has nothing to
# read and the whole block is skipped.
Describe 'An article that was paid for' {
    BeforeAll {
        if ($Config.CommercialArticle) {
            $Script:PaidHtml = (Get-Page -Path $Config.CommercialArticle).Content
            $Script:PaidList = (Get-Page -Path $Config.CommercialListing).Content
            $Script:PaidFeed = (Get-Page -Path '/feed.xml').Content
        }
    }

    It 'says so over its lead, with the mark' -Skip:(-not $Config.CommercialArticle) {
        $Script:PaidHtml | Should -BeLike '*content-banner*'
        $Script:PaidHtml | Should -BeLike "*$($Config.CommercialLabel)*"
    }

    It 'says so over the lead and not over the headline' -Skip:(-not $Config.CommercialArticle) {
        # Measured by where the three land in the page: the headline first,
        # then the mark, then the article itself.
        $headline = $Script:PaidHtml.IndexOf('article-headline')
        $banner   = $Script:PaidHtml.IndexOf('content-banner')
        $article  = $Script:PaidHtml.IndexOf('article-post')

        $headline | Should -BeGreaterThan -1
        $banner | Should -BeGreaterThan $headline -Because 'over the headline the mark is read as part of the head of the page'
        $banner | Should -BeLessThan $article -Because 'the mark stands over the lead, not inside the text'
    }

    It 'is marked in the archive of its category' -Skip:(-not $Config.CommercialArticle) {
        $Script:PaidList | Should -BeLike '*content-tag*'
        Test-LinkPresent -Html $Script:PaidList -Path $Config.CommercialArticle | Should -BeTrue
    }

    It 'has the label in front of its title in the feed' -Skip:(-not $Config.CommercialArticle) {
        $Script:PaidFeed | Should -BeLike "*$($Config.CommercialLabel)*"
    }
}

Describe 'The archive of a series' {
    BeforeAll {
        $Script:SeriesArchiveHtml = (Get-Page -Path "/$Script:SeriesPath/$($Config.Series[0])/").Content
    }

    It 'links to every part, including <_>' -ForEach $Config.SeriesPartUrls {
        Test-LinkPresent -Html $Script:SeriesArchiveHtml -Path $_ | Should -BeTrue
    }
}

Describe 'Links that lead away' {
    BeforeAll {
        $Script:OutsideHtml = (Get-Page -Path $Config.ArticleWithOutsideLink).Content
        $Script:Tags = Get-LinkTag -Html $Script:OutsideHtml
    }

    It 'marks the link to a site that is not known' {
        $outside = $Script:Tags | Where-Object { $_ -match [regex]::Escape($Config.OutsideLinkHost) }
        $outside | Should -Not -BeNullOrEmpty -Because 'the article has to hold such a link for this to mean anything'
        foreach ($tag in $outside) {
            $tag | Should -Match 'data-external' -Because "a link to $($Config.OutsideLinkHost) leads away"
        }
    }

    It 'leaves a link inside the site unmarked' {
        $inside = $Script:Tags | Where-Object { $_ -match 'href=["'']/' -and $_ -notmatch 'href=["'']//' }
        $inside | Should -Not -BeNullOrEmpty
        foreach ($tag in $inside) {
            $tag | Should -Not -Match 'data-external' -Because 'it does not lead away'
        }
    }
}

# On a test instance every page says noindex, so neither half of this can be
# told apart from the state of the whole site: the thin archive would pass for
# the wrong reason and the long one would fail for a reason that is correct.
# The block is therefore skipped there rather than lying in either direction.
Describe 'Archives too thin to offer' {
    It 'says noindex on the archive of <_>' -ForEach $Config.ThinCategories -Skip:([bool]$Settings['devtest_mode']) {
        $html = (Get-Page -Path "/$Script:CategoriesPath/$_/").Content
        $html | Should -Match 'name=["'']robots["''][^>]*content=["'']noindex' -Because 'an archive of fewer than three articles is thin'
    }

    It 'leaves an archive that is long enough indexed' -Skip:([bool]$Settings['devtest_mode']) {
        $html = (Get-Page -Path "/$Script:CategoriesPath/$($Config.IndexedCategory)/").Content
        $html | Should -Not -Match 'name=["'']robots["''][^>]*content=["'']noindex'
    }
}

Describe 'The files built from the articles' {
    It 'offers a feed that is XML and holds something' {
        $feed = (Get-Page -Path '/feed.xml').Content
        { [xml]$feed } | Should -Not -Throw
        ([xml]$feed).feed.entry.Count | Should -BeGreaterThan 0
    }

    It 'offers a map of the site that is XML' {
        $map = (Get-Page -Path '/sitemap.xml').Content
        { [xml]$map } | Should -Not -Throw
    }

    It 'has the archives of the categories in that map' {
        $map = (Get-Page -Path '/sitemap.xml').Content
        foreach ($archive in $Script:CategoryArchives) {
            $map | Should -BeLike "*$archive*" -Because "$archive is a page of its own"
        }
    }

    It 'keeps the unfinished articles out of that map' {
        (Get-Page -Path '/sitemap.xml').Content | Should -Not -BeLike '*/drafts/*'
    }

    It 'offers an index for the search that is JSON and holds records' {
        $index = (Get-Page -Path '/search-index.json').Content
        { $index | ConvertFrom-Json } | Should -Not -Throw
        ($index | ConvertFrom-Json).Count | Should -BeGreaterThan 4
    }

    # A test instance deliberately keeps the map out of robots.txt, so the
    # expectation turns around rather than being given up: the absence of the
    # line is then what proves the switch did its work.
    It 'points the crawlers at the map' {
        $robots = (Get-Page -Path '/robots.txt').Content

        if ($Settings['devtest_mode']) {
            $robots | Should -Not -Match 'Sitemap:' -Because 'a test instance does not offer its map'
        } else {
            $robots | Should -Match 'Sitemap:'
        }
    }
}

Describe 'The features the configuration switches' {
    # One test for each switch, and it holds whichever way the switch is set:
    # where the feature is on its mark has to be in the page, where it is off
    # the mark must not be there at all. The second half is the one that
    # catches a switch that does nothing.
    #
    # Nothing here says a feature ought to be on. Which of them a site uses is
    # its own business; what is checked is that the configuration and the page
    # say the same thing.
    #
    # The two blocks of the publisher are the one place where that can fail
    # honestly: they need sites.json as well as the switch, so a site whose
    # download of it came back empty has the switch on and the block missing.
    BeforeAll {
        $Script:Pages = @{
            Home    = (Get-Page -Path '/').Content
            Article = (Get-Page -Path $Config.FeatureArticle).Content
            Images  = (Get-Page -Path $Config.ArticleWithImages).Content
            Middle  = (Get-Page -Path $Config.SeriesMiddleArticle).Content
            Index   = (Get-Page -Path ('/{0}/' -f $Config.Paths.Categories)).Content
        }
    }

    It '<name>' -ForEach $Script:Features {
        $html = $Script:Pages[$_.Page]

        if ($_.On) {
            $html | Should -BeLike "*$($_.Marker)*" -Because 'the configuration has it switched on'
        } else {
            $html | Should -Not -BeLike "*$($_.Marker)*" -Because 'the configuration has it switched off'
        }
    }

    # The index of the categories has no second form to fall back to, so this
    # is not a switch in the table above but a thing that has to be there.
    It 'shows the categories as a filter' {
        $Script:Pages['Index'] | Should -BeLike '*cat-filter*' -Because 'the index of the categories is a filter and has no other form'
    }

    # Not only that something is measuring, but that it measures for this
    # site. A configuration merged by hand from another site carries the
    # switch on and the identifier of the site it came from, and every test
    # above passes on it.
    It 'measures under the identifier this site was given' -Skip:(-not $Script:Measured) {
        foreach ($key in 'analytics_google_analytics', 'analytics_microsoft_clarity', 'analytics_meta_pixel') {
            $id = [string]$Settings[$key]
            if ([string]::IsNullOrWhiteSpace($id)) { continue }

            $Script:Pages['Home'] | Should -BeLike "*$id*" -Because "$key is filled in, so the page has to carry that identifier"
        }
    }

    # The pixel without a script is the one that cannot ask anybody anything,
    # so it belongs on a site that answers the question elsewhere and nowhere
    # else. It is written into the page only with consent switched off.
    It 'keeps the pixel without a script away unless consent is handled elsewhere' -Skip:([string]::IsNullOrWhiteSpace([string]$Settings['analytics_meta_pixel'])) {
        if ($Settings['consent']) {
            $Script:Pages['Home'] | Should -Not -BeLike '*facebook.com/tr?id=*' -Because 'the bar asks, so the pixel waits for the answer'
        } else {
            $Script:Pages['Home'] | Should -BeLike '*facebook.com/tr?id=*'
        }
    }
}

# What the configuration says about the site, as the pages show it. These are
# the values a new site changes first and the ones a configuration merged by
# hand from another site carries over without anybody noticing.
Describe 'What the configuration says about the site' {
    BeforeAll {
        $Script:HomeHtml = (Get-Page -Path '/').Content

        $Script:ContactPath = [string]$Settings['contactsite_url']
        $Script:ContactHtml = if ($Script:ContactPath) {
            (Get-Page -Path $Script:ContactPath).Content
        } else { '' }

        # The key in the configuration against the class the icon carries.
        # X is still twitter in the configuration, the same key the authors
        # use, and social-link-x in the page.
        $Script:Networks = @(
            @{ Key = 'social_facebook'; Nav = 'social-link-facebook'; Foot = 'share-facebook' }
            @{ Key = 'social_threads';  Nav = 'social-link-threads';  Foot = 'share-threads' }
            @{ Key = 'social_linkedin'; Nav = 'social-link-linkedin'; Foot = 'share-linkedin' }
            @{ Key = 'social_twitter';  Nav = 'social-link-x';        Foot = 'share-x' }
        )
    }

    It 'shows the social networks in the order they belong in' {
        foreach ($where in 'Nav', 'Foot') {
            $seen = @()

            foreach ($network in $Script:Networks) {
                if ([string]::IsNullOrWhiteSpace([string]$Settings[$network.Key])) { continue }

                $at = $Script:HomeHtml.IndexOf($network[$where])
                if ($at -ge 0) { $seen += $at }
            }

            for ($i = 1; $i -lt $seen.Count; $i++) {
                $seen[$i] | Should -BeGreaterThan $seen[$i - 1] -Because 'the order is Facebook, Threads, LinkedIn, X'
            }
        }
    }

    It 'shows an icon for every profile that is filled in, and none for the rest' {
        foreach ($network in $Script:Networks) {
            $filled = -not [string]::IsNullOrWhiteSpace([string]$Settings[$network.Key])

            if ($filled) {
                $Script:HomeHtml | Should -BeLike "*$($network.Nav)*" -Because "$($network.Key) is filled in"
            } else {
                $Script:HomeHtml | Should -Not -BeLike "*$($network.Nav)*" -Because "$($network.Key) is empty"
            }
        }
    }

    It 'describes the publisher with the values from the configuration' -Skip:(-not $Settings['organization_name']) {
        $pairs = @(
            @{ Field = 'name';            Value = [string]$Settings['organization_name'] }
            @{ Field = 'legalName';       Value = [string]$Settings['organization_legal_name'] }
            @{ Field = 'addressLocality'; Value = [string]$Settings['organization_locality'] }
            @{ Field = 'addressCountry';  Value = [string]$Settings['organization_country'] }
        )

        foreach ($pair in $pairs) {
            if ([string]::IsNullOrWhiteSpace($pair.Value)) { continue }

            $expected = '"{0}"\s*:\s*"{1}"' -f $pair.Field, [regex]::Escape($pair.Value)
            $Script:HomeHtml | Should -Match $expected -Because 'the structured data says who publishes the site'
        }
    }

    It 'links from the footer to the pages the configuration names' {
        foreach ($key in 'privacy_url', 'terms_url', 'contactsite_url') {
            $path = [string]$Settings[$key]
            if ([string]::IsNullOrWhiteSpace($path)) { continue }

            Test-LinkPresent -Html $Script:HomeHtml -Path $path | Should -BeTrue -Because "$key is filled in"
        }
    }

    It 'has a form on the contact page only with a form to send it to' -Skip:(-not $Settings['contactsite_url']) {
        if ([string]::IsNullOrWhiteSpace([string]$Settings['contact_formspree_id'])) {
            $Script:ContactHtml | Should -Not -BeLike '*formspree.io/f/*' -Because 'with no form id there is nowhere to send a message'
        } else {
            $Script:ContactHtml | Should -BeLike "*formspree.io/f/$($Settings['contact_formspree_id'])*"
        }
    }

    It 'claims the site with Google only when asked to' {
        if ([string]::IsNullOrWhiteSpace([string]$Settings['google_site_verification'])) {
            $Script:HomeHtml | Should -Not -Match 'name=["'']google-site-verification["'']'
        } else {
            $Script:HomeHtml | Should -Match ('content=["'']{0}["'']' -f [regex]::Escape([string]$Settings['google_site_verification']))
        }
    }

    It 'says who holds the copyright and since when' {
        $owner = [string]$Settings['copyrightowner']
        if ([string]::IsNullOrWhiteSpace($owner)) { $owner = [string]$Settings['author'] }

        if (-not [string]::IsNullOrWhiteSpace($owner)) {
            $Script:HomeHtml | Should -BeLike "*$owner*"
        }

        # Only the first year is checked. The second is the year of the build,
        # so a site built in December and tested in January would fail a test
        # that asked for today's year, and the site would be right.
        $from = [string]$Settings['copyrightstart']
        if (-not [string]::IsNullOrWhiteSpace($from)) {
            $Script:HomeHtml | Should -BeLike "*$from*"
        }
    }
}
