param(
    [string]$WikiDir = ".wiki",
    [string]$Owner = "rudolfstepan",
    [string]$Repo = "6502-sbc-emulator",
    [string]$Branch = "main",
    [switch]$Push
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$wikiPath = Join-Path $repoRoot $WikiDir
$repoUrl = "https://github.com/$Owner/$Repo"
$wikiRemote = "https://github.com/$Owner/$Repo.wiki.git"

$pages = @(
    @{ Source = "README.md"; Page = "Home"; Title = "Home" }
    @{ Source = "docs/ARCHITECTURE.md"; Page = "Architecture-Overview"; Title = "Architecture Overview" }
    @{ Source = "docs/VIC.md"; Page = "VIC-Video-Interface-Controller"; Title = "VIC Video Interface Controller" }
    @{ Source = "docs/KEYBOARD.md"; Page = "Keyboard-Integration"; Title = "Keyboard Integration" }
    @{ Source = "docs/MSBASIC.md"; Page = "MS-BASIC-on-SBC6502"; Title = "MS BASIC on SBC6502" }
    @{ Source = "docs/BASIC_CONVERTER.md"; Page = "MS-BASIC-Text-Converter"; Title = "MS BASIC Text Converter" }
    @{ Source = "examples/README_GRAPHICS.md"; Page = "VIC-Graphics-Test"; Title = "VIC Graphics Test" }
    @{ Source = "docs/THIRD_PARTY.md"; Page = "Third-Party-Components"; Title = "Third-Party Components" }
    @{ Source = "CHANGELOG.md"; Page = "Changelog"; Title = "Changelog" }
    @{ Source = "CONTRIBUTING.md"; Page = "Contributing"; Title = "Contributing" }
    @{ Source = "SECURITY.md"; Page = "Security-Policy"; Title = "Security Policy" }
    @{ Source = "CODE_OF_CONDUCT.md"; Page = "Code-of-Conduct"; Title = "Code of Conduct" }
    @{ Source = "docs/archive/BUGFIXES_2026-05.md"; Page = "Archived-Bug-Fixes-May-2026"; Title = "Archived Bug Fixes - May 2026" }
)

function Convert-ToRepoPath {
    param([string]$Path)
    return ($Path -replace "\\", "/").TrimStart("./")
}

function Convert-ToAnchor {
    param([string]$Heading)
    $anchor = $Heading.ToLowerInvariant()
    $anchor = $anchor -replace '[^\p{Ll}\p{Nd}\s-]', ''
    $anchor = $anchor -replace '\s+', '-'
    return $anchor.Trim("-")
}

function Convert-ToRelativePath {
    param(
        [string]$BasePath,
        [string]$TargetPath
    )

    $baseUri = New-Object System.Uri((Join-Path (Resolve-Path $BasePath) ""))
    $targetUri = New-Object System.Uri($TargetPath)
    return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString())
}

$pageBySource = @{}
foreach ($page in $pages) {
    $pageBySource[(Convert-ToRepoPath $page.Source).ToLowerInvariant()] = $page.Page
}

function Resolve-DocLink {
    param(
        [string]$SourceFile,
        [string]$Url
    )

    if ($Url -match '^(https?:|mailto:|#)') {
        return $Url
    }

    $urlParts = $Url.Split("#", 2)
    $target = $urlParts[0]
    $anchor = ""
    if ($urlParts.Count -eq 2) {
        $anchor = "#" + $urlParts[1]
    }

    if ([string]::IsNullOrWhiteSpace($target)) {
        return $Url
    }

    $sourceDir = Split-Path (Convert-ToRepoPath $SourceFile) -Parent
    $combined = if ([string]::IsNullOrWhiteSpace($sourceDir)) { $target } else { Join-Path $sourceDir $target }
    $full = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $combined))
    $relative = Convert-ToRelativePath -BasePath $repoRoot -TargetPath $full
    $repoPath = Convert-ToRepoPath $relative
    $key = $repoPath.ToLowerInvariant()

    if ($pageBySource.ContainsKey($key)) {
        return "$repoUrl/wiki/$($pageBySource[$key])$anchor"
    }

    $encodedPath = ($repoPath -split "/" | ForEach-Object { [uri]::EscapeDataString($_) }) -join "/"
    if (Test-Path (Join-Path $repoRoot $repoPath) -PathType Container) {
        return "$repoUrl/tree/$Branch/$encodedPath$anchor"
    }
    return "$repoUrl/blob/$Branch/$encodedPath$anchor"
}

function Convert-MarkdownForWiki {
    param(
        [string]$SourceFile,
        [string]$Markdown
    )

    $imageLinkCallback = {
        param($match)
        $image = $match.Groups["image"].Value
        $url = $match.Groups["url"].Value
        $converted = Resolve-DocLink -SourceFile $SourceFile -Url $url
        return "[$image]($converted)"
    }

    $callback = {
        param($match)
        $text = $match.Groups["text"].Value
        $url = $match.Groups["url"].Value
        $converted = Resolve-DocLink -SourceFile $SourceFile -Url $url
        return "[$text]($converted)"
    }

    $convertedMarkdown = [regex]::Replace($Markdown, '\[(?<image>!\[[^\]]+\]\([^)]+\))\]\((?<url>[^)]+)\)', $imageLinkCallback)
    return [regex]::Replace($convertedMarkdown, '\[(?<text>[^\]]+)\]\((?<url>[^)]+)\)', $callback)
}

if (-not (Test-Path $wikiPath)) {
    New-Item -ItemType Directory -Path $wikiPath | Out-Null
}

if (-not (Test-Path (Join-Path $wikiPath ".git"))) {
    Push-Location $wikiPath
    try {
        git init | Out-Host
        git remote add origin $wikiRemote
    }
    finally {
        Pop-Location
    }
}

foreach ($page in $pages) {
    $source = Convert-ToRepoPath $page.Source
    $sourcePath = Join-Path $repoRoot $source
    if (-not (Test-Path $sourcePath)) {
        throw "Missing source Markdown file: $source"
    }

    $markdown = Get-Content -Raw -Encoding UTF8 $sourcePath
    $converted = Convert-MarkdownForWiki -SourceFile $source -Markdown $markdown
    $header = "[Source file]($repoUrl/blob/$Branch/$source)"
    $body = "$header`n`n$converted"
    Set-Content -Encoding UTF8 -Path (Join-Path $wikiPath "$($page.Page).md") -Value $body
}

$sidebar = @(
    "# 6502 SBC Emulator",
    "",
    "## Main",
    "- [Home]($repoUrl/wiki/Home)",
    "- [Architecture Overview]($repoUrl/wiki/Architecture-Overview)",
    "- [VIC Video Interface Controller]($repoUrl/wiki/VIC-Video-Interface-Controller)",
    "- [Keyboard Integration]($repoUrl/wiki/Keyboard-Integration)",
    "- [MS BASIC on SBC6502]($repoUrl/wiki/MS-BASIC-on-SBC6502)",
    "- [MS BASIC Text Converter]($repoUrl/wiki/MS-BASIC-Text-Converter)",
    "- [VIC Graphics Test]($repoUrl/wiki/VIC-Graphics-Test)",
    "",
    "## Project",
    "- [Third-Party Components]($repoUrl/wiki/Third-Party-Components)",
    "- [Changelog]($repoUrl/wiki/Changelog)",
    "- [Contributing]($repoUrl/wiki/Contributing)",
    "- [Security Policy]($repoUrl/wiki/Security-Policy)",
    "- [Code of Conduct]($repoUrl/wiki/Code-of-Conduct)",
    "- [Archived Bug Fixes - May 2026]($repoUrl/wiki/Archived-Bug-Fixes-May-2026)"
)
Set-Content -Encoding UTF8 -Path (Join-Path $wikiPath "_Sidebar.md") -Value ($sidebar -join "`n")

$footer = "Generated from [$Repo]($repoUrl) Markdown documentation."
Set-Content -Encoding UTF8 -Path (Join-Path $wikiPath "_Footer.md") -Value $footer

Push-Location $wikiPath
try {
    git add .
    if (-not (git diff --cached --quiet)) {
        git commit -m "Publish project documentation wiki" | Out-Host
    }
    else {
        Write-Host "Wiki content is already up to date."
    }

    if ($Push) {
        git push -u origin master
    }
}
finally {
    Pop-Location
}
