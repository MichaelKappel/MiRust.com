param(
    [string]$ManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "deploy\site-deployment-manifest-2.6.1.v1.json"),
    [string]$FileZillaProfilePath = (Join-Path $env:APPDATA "FileZilla\sitemanager.xml"),
    [switch]$Publish,
    [switch]$AllowUncommittedValidation
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Net.Http

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$authorityPath = [IO.Path]::GetFullPath((Join-Path $repositoryRoot "deploy\publication-authority-2.6.1.v1.json"))
$canonicalManifestPath = [IO.Path]::GetFullPath((Join-Path $repositoryRoot "deploy\site-deployment-manifest-2.6.1.v1.json"))
$authoritySha256 = "0a20b3073d6bb0977589d3469892370369fb8b8579ed6bd76f4ed74b18e4fb97"
$script:credential = $null
$script:ftpHostName = $null
$script:ftpPort = 0
$script:remoteWritesAdmitted = $false
$script:remoteMutationObserved = $false
$script:ownedPublicationLease = $null

function Assert-DirectNonReparseAncestry {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label,
        [switch]$Leaf,
        [switch]$Container
    )

    $resolved = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($resolved)
    if ([string]::IsNullOrEmpty($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "$Label ancestry is unavailable."
    }
    $current = $root
    $relative = $resolved.Substring($root.Length)
    foreach ($segment in @($relative -split '[\\/]' | Where-Object { $_.Length -gt 0 })) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) { throw "$Label ancestry is unavailable." }
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label ancestry contains a reparse point."
        }
    }
    if ($Leaf -and -not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "$Label is not a regular file."
    }
    if ($Container -and -not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw "$Label is not a directory."
    }
    return $resolved
}

function Open-StableRegularFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    $resolved = Assert-DirectNonReparseAncestry -Path $Path -Label $Label -Leaf
    $stream = $null
    try {
        $stream = [IO.FileStream]::new(
            $resolved,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        Assert-DirectNonReparseAncestry -Path $resolved -Label $Label -Leaf | Out-Null
        $item = Get-Item -LiteralPath $resolved -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($item.Attributes -band [IO.FileAttributes]::Directory) -ne 0 -or
            [int64]$item.Length -ne [int64]$stream.Length) {
            throw "$Label changed while its read handle was acquired."
        }
        return ,$stream
    }
    catch {
        if ($null -ne $stream) { $stream.Dispose() }
        throw
    }
}

function Read-StableRegularFileBytes {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int64]$MaximumBytes,
        [Parameter(Mandatory)][string]$Label
    )

    $stream = Open-StableRegularFile -Path $Path -Label $Label
    try {
        if ($stream.Length -lt 0 -or $stream.Length -gt $MaximumBytes -or $stream.Length -gt [int]::MaxValue) {
            throw "$Label exceeded its byte bound."
        }
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -eq 0) { throw "$Label ended before its observed length." }
            $offset += $read
        }
        if ($stream.ReadByte() -ne -1) { throw "$Label changed while it was read." }
        Assert-DirectNonReparseAncestry -Path $Path -Label $Label -Leaf | Out-Null
        return ,$bytes
    }
    finally { $stream.Dispose() }
}

function Invoke-CanonicalSourceAuthorityGate {
    param(
        [Parameter(Mandatory)][pscustomobject]$Authority,
        [switch]$RequireRemoteExact
    )

    $tinyRustRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot ([string]$Authority.source_verifier.relative_repository_path)))
    $expectedRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $repositoryRoot) "TinyRustLM.com"))
    $verifier = [IO.Path]::GetFullPath((Join-Path $tinyRustRoot (([string]$Authority.source_verifier.path) -replace "/", "\")))
    if ($tinyRustRoot -cne $expectedRoot) { throw "Canonical source-authority repository path is invalid." }
    Assert-DirectNonReparseAncestry -Path $repositoryRoot -Label "Publisher repository" -Container | Out-Null
    Assert-DirectNonReparseAncestry -Path $tinyRustRoot -Label "Canonical source-authority repository" -Container | Out-Null
    Assert-DirectNonReparseAncestry -Path $verifier -Label "Canonical source-authority verifier" -Leaf | Out-Null

    $branch = Invoke-GitText -Repository $tinyRustRoot -Arguments @("symbolic-ref", "--quiet", "--short", "HEAD")
    $origin = Invoke-GitText -Repository $tinyRustRoot -Arguments @(
        "remote", "get-url", [string]$Authority.source_verifier.remote_name
    )
    $commit = Invoke-GitText -Repository $tinyRustRoot -Arguments @("rev-parse", "HEAD")
    $tree = Invoke-GitText -Repository $tinyRustRoot -Arguments @("rev-parse", "HEAD^{tree}")
    $blob = Invoke-GitText -Repository $tinyRustRoot -Arguments @(
        "rev-parse", ("HEAD:{0}" -f [string]$Authority.source_verifier.path)
    )
    if ($branch -cne [string]$Authority.source_verifier.branch -or
        $origin -cne [string]$Authority.source_verifier.remote_url -or
        $commit -cne [string]$Authority.source_verifier.commit -or
        $tree -cne [string]$Authority.source_verifier.tree -or
        $blob -cne [string]$Authority.source_verifier.blob) {
        throw "Canonical source-authority verifier revision is not the pinned authority."
    }
    if ($RequireRemoteExact) {
        $status = @(Invoke-GitLines -Repository $tinyRustRoot -Arguments @("status", "--porcelain", "--untracked-files=all"))
        $tracking = Invoke-GitText -Repository $tinyRustRoot -Arguments @("rev-parse", "@{upstream}")
        $remoteLine = Invoke-GitText -Repository $tinyRustRoot -Arguments @(
            "ls-remote", "--refs", [string]$Authority.source_verifier.remote_name,
            ("refs/heads/{0}" -f [string]$Authority.source_verifier.branch)
        )
        $remoteCommit = [string]($remoteLine -split "\s+")[0]
        if ($status.Count -ne 0 -or $tracking -cne $commit -or $remoteCommit -cne $commit) {
            throw "Canonical source-authority verifier is not clean and remote-exact."
        }
    }

    $verifierHandle = Open-StableRegularFile -Path $verifier -Label "Pinned source-authority verifier"
    $node = Get-Command node -CommandType Application -ErrorAction Stop
    $nodeHandle = Open-StableRegularFile -Path $node.Source -Label "Node executable"
    try {
        if ($verifierHandle.Length -ne [int64]$Authority.source_verifier.bytes) {
            throw "Pinned source-authority verifier byte identity drifted."
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $verifierHandle.Position = 0
            $verifierSha256 = ([BitConverter]::ToString($sha.ComputeHash($verifierHandle))).Replace("-", "").ToLowerInvariant()
        }
        finally { $sha.Dispose() }
        if ($verifierSha256 -cne [string]$Authority.source_verifier.sha256) {
            throw "Pinned source-authority verifier byte identity drifted."
        }
        $arguments = @($verifier)
        if ($RequireRemoteExact) { $arguments += @("--require-clean", "--require-remote-exact") }
        $output = @(& $node.Source @arguments 2>&1)
        if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) {
            throw "Canonical source-authority verification failed."
        }
    }
    finally {
        $nodeHandle.Dispose()
        $verifierHandle.Dispose()
    }
    try { $result = ([string]$output[0]) | ConvertFrom-Json }
    catch { throw "Canonical source-authority verifier returned invalid evidence." }
    if ($result.verdict -cne "pass" -or $result.canonicalLayoutAvailable -ne $true -or
        $result.localScanPerformed -ne $true) {
        throw "Canonical source-authority verification did not pass."
    }

    return [pscustomobject]@{
        RepositoryRoot = $tinyRustRoot
        VerifierPath = $verifier
        VerifierCommit = $commit
        VerifierTree = $tree
        VerifierBlob = $blob
        VerifierSha256 = $verifierSha256
        NodePath = [IO.Path]::GetFullPath($node.Source)
        NodeSha256 = Get-FileSha256 -Path $node.Source
        Strict = [bool]$RequireRemoteExact
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    $stream = Open-StableRegularFile -Path $Path -Label "Hashed regular file"
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Get-TextSha256 {
    param([Parameter(Mandatory)][string]$Value)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Get-BytesSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace("-", "").ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function ConvertFrom-StrictUtf8Json {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$Label
    )

    if ($Bytes.Length -lt 2 -or $Bytes.Length -gt 1048576 -or
        ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xef -and $Bytes[1] -eq 0xbb -and $Bytes[2] -eq 0xbf)) {
        throw "$Label has an invalid bounded UTF-8 JSON encoding."
    }
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    try { $text = $encoding.GetString($Bytes) }
    catch { throw "$Label is not strict UTF-8 JSON." }
    if ($text.IndexOf([char]0) -ge 0 -or -not $text.EndsWith("`n", [StringComparison]::Ordinal)) {
        throw "$Label must be NUL-free canonical LF-terminated JSON."
    }
    try { $value = $text | ConvertFrom-Json }
    catch { throw "$Label is malformed JSON." }
    if ($null -eq $value -or $value -isnot [pscustomobject]) {
        throw "$Label must contain one JSON object."
    }
    return $value
}

function Assert-ExactProperties {
    param(
        [Parameter(Mandatory)][pscustomobject]$Value,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$Label
    )

    $actual = @($Value.PSObject.Properties.Name)
    if ($actual.Count -ne $Expected.Count) {
        throw "$Label has an invalid property set."
    }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ([string]$actual[$index] -cne [string]$Expected[$index]) {
            throw "$Label has an invalid property set."
        }
    }
}

function Read-ExactJsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int64]$Bytes,
        [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][string]$Label
    )

    $resolved = [IO.Path]::GetFullPath($Path)
    $content = Read-StableRegularFileBytes -Path $resolved -MaximumBytes 1048576 -Label $Label
    if ($content.Length -ne $Bytes -or (Get-BytesSha256 -Bytes $content) -cne $Sha256) {
        throw "$Label identity is invalid."
    }
    return ConvertFrom-StrictUtf8Json -Bytes $content -Label $Label
}

function Assert-PublicationAuthority {
    param([Parameter(Mandatory)][pscustomobject]$Authority)

    Assert-ExactProperties -Value $Authority -Expected @(
        "schema", "site", "origin", "public_host", "candidate", "publisher",
        "source_verifier", "transport", "predecessor", "contains_credentials", "contains_private_paths"
    ) -Label "Publication authority"
    Assert-ExactProperties -Value $Authority.candidate -Expected @(
        "version", "release_id", "operation_id", "content_commit", "content_tree",
        "manifest_commit", "manifest_tree", "manifest_path", "manifest_bytes", "manifest_sha256"
    ) -Label "Publication authority candidate"
    Assert-ExactProperties -Value $Authority.publisher -Expected @(
        "branch", "remote_name", "remote_url"
    ) -Label "Publication authority publisher"
    Assert-ExactProperties -Value $Authority.source_verifier -Expected @(
        "repository", "relative_repository_path", "branch", "remote_name", "remote_url",
        "commit", "tree", "path", "blob", "bytes", "sha256"
    ) -Label "Publication authority source verifier"
    Assert-ExactProperties -Value $Authority.transport -Expected @(
        "protocol", "profile_name", "host", "port", "root_sentinel_path",
        "root_sentinel_bytes", "root_sentinel_sha256"
    ) -Label "Publication authority transport"
    Assert-ExactProperties -Value $Authority.predecessor -Expected @(
        "version", "release_id", "manifest_path", "manifest_bytes", "manifest_sha256",
        "receipt_path", "receipt_bytes", "receipt_sha256", "documents"
    ) -Label "Publication authority predecessor"

    $expectedDocumentRoles = @("release-marker", "release-history", "site-manifest")
    $expectedDocumentPaths = @(
        "/.well-known/site-release.json",
        "/.well-known/site-release-history.json",
        "/.well-known/mirust-site.json"
    )
    $documents = @($Authority.predecessor.documents)
    if ($documents.Count -ne 3) { throw "Publication authority predecessor closure is invalid." }
    for ($index = 0; $index -lt $documents.Count; $index++) {
        Assert-ExactProperties -Value $documents[$index] -Expected @(
            "role", "path", "bytes", "sha256", "schema"
        ) -Label "Publication authority predecessor document"
        if ([string]$documents[$index].role -cne $expectedDocumentRoles[$index] -or
            [string]$documents[$index].path -cne $expectedDocumentPaths[$index] -or
            [int64]$documents[$index].bytes -lt 2 -or [int64]$documents[$index].bytes -gt 65536 -or
            [string]$documents[$index].sha256 -notmatch "^[0-9a-f]{64}$") {
            throw "Publication authority predecessor closure is invalid."
        }
    }

    $origin = $null
    $remote = $null
    $verifierRemote = $null
    if ($Authority.schema -cne "mirust.static_site_publication_authority.v1" -or
        $Authority.site -cne "MiRust.com" -or
        $Authority.origin -cne "https://mirust.com" -or
        $Authority.public_host -cne "mirust.com" -or
        -not [Uri]::TryCreate([string]$Authority.origin, [UriKind]::Absolute, [ref]$origin) -or
        $origin.Scheme -cne "https" -or $origin.Host -cne "mirust.com" -or $origin.AbsolutePath -cne "/" -or
        $Authority.candidate.version -cne "2.6.1" -or
        $Authority.candidate.release_id -cne "mirust.com@2.6.1" -or
        $Authority.candidate.operation_id -cne "mirust-root-discovery-2.6.1-20260831-v1" -or
        $Authority.candidate.content_commit -cne "2c5763655e1ad23f812efe40365cae62a74562dd" -or
        $Authority.candidate.content_tree -cne "c97d3f010dd26be7de48feef72d21ee101a3a208" -or
        $Authority.candidate.manifest_commit -cne "cbefce77356a59de044f42a98dc76a2f5f557173" -or
        $Authority.candidate.manifest_tree -cne "80599516d4400d1834ea50648cf1fed10ad0cda4" -or
        $Authority.candidate.manifest_path -cne "deploy/site-deployment-manifest-2.6.1.v1.json" -or
        [int64]$Authority.candidate.manifest_bytes -ne 6848 -or
        $Authority.candidate.manifest_sha256 -cne "eeda38875c31130dd05f91b3974fd4a0326d3be5636954bb3fda131ea58f6e01" -or
        $Authority.publisher.branch -cne "master" -or
        $Authority.publisher.remote_name -cne "origin" -or
        -not [Uri]::TryCreate([string]$Authority.publisher.remote_url, [UriKind]::Absolute, [ref]$remote) -or
        $remote.Scheme -cne "https" -or $remote.Host -cne "github.com" -or
        $Authority.source_verifier.repository -cne "TinyRustLM.com" -or
        $Authority.source_verifier.relative_repository_path -cne "../TinyRustLM.com" -or
        $Authority.source_verifier.branch -cne "codex/model-acquisition-v2" -or
        $Authority.source_verifier.remote_name -cne "origin" -or
        -not [Uri]::TryCreate([string]$Authority.source_verifier.remote_url, [UriKind]::Absolute, [ref]$verifierRemote) -or
        $verifierRemote.Scheme -cne "https" -or $verifierRemote.Host -cne "github.com" -or
        $Authority.source_verifier.commit -cne "4f3b36fbba69d9c875a50069e866fcf673158378" -or
        $Authority.source_verifier.tree -cne "59789a32cb4f6f9e9c81f1311039f5005fb154fb" -or
        $Authority.source_verifier.path -cne "tinyrustlm/tools/verify-single-source-authority.js" -or
        $Authority.source_verifier.blob -cne "db3ad2184e58cbb4584eb75c8d0062494ebe06d8" -or
        [int64]$Authority.source_verifier.bytes -ne 144650 -or
        $Authority.source_verifier.sha256 -cne "d8005c826d3e477787a79ad4f25fbd3cf25bd37cb810b3b2bf708667e2290d47" -or
        $Authority.transport.protocol -cne "ftps-explicit" -or
        $Authority.transport.profile_name -cne "MiRust.com" -or
        $Authority.transport.host -cne "ftp.mirust.com" -or
        [int]$Authority.transport.port -ne 21 -or
        $Authority.transport.root_sentinel_path -cne ".well-known/security.txt" -or
        [int64]$Authority.transport.root_sentinel_bytes -ne 113 -or
        $Authority.transport.root_sentinel_sha256 -cne "db3029d15deb26062dbf00e2aa966032e0cf31951222fe7c49e19847295fcb9f" -or
        $Authority.predecessor.version -cne "2.6.0" -or
        $Authority.predecessor.release_id -cne "mirust.com@2.6.0" -or
        $Authority.predecessor.manifest_path -cne "deploy/site-deployment-manifest.v1.json" -or
        [int64]$Authority.predecessor.manifest_bytes -ne 7948 -or
        $Authority.predecessor.manifest_sha256 -cne "e76ecddc240df8b29d80d7f00fb12d97c7d4cbf5b3c134e7114577db523c144a" -or
        $Authority.predecessor.receipt_path -cne "deploy/receipts/site-deployment-mirust-root-discovery-2.6.0-20260829-v1.json" -or
        [int64]$Authority.predecessor.receipt_bytes -ne 8285 -or
        $Authority.predecessor.receipt_sha256 -cne "ed4c2ba6817a8ca78c544bd5b474c97b8fcb537fafa8e4c4a1aa052ebe5f79fa" -or
        $Authority.contains_credentials -ne $false -or $Authority.contains_private_paths -ne $false) {
        throw "Publication authority identity is invalid."
    }
}

function Assert-RelativePath {
    param([Parameter(Mandatory)][string]$Path)

    if ($Path.Length -gt 512 -or
        $Path.StartsWith("/") -or
        $Path.StartsWith("\") -or
        $Path.Contains("\") -or
        $Path -match "(^|/)\.\.(/|$)" -or
        $Path -notmatch "^[A-Za-z0-9._/-]+$" -or
        $Path -match "//") {
        throw "Deployment manifest contains an unsafe relative path."
    }
    return $Path
}

function Get-EncodedRemotePath {
    param([string]$RemotePath)

    if ([string]::IsNullOrEmpty($RemotePath)) { return "" }
    $validated = Assert-RelativePath -Path $RemotePath
    return (($validated -split "/") | ForEach-Object { [Uri]::EscapeDataString($_) }) -join "/"
}

function Assert-SafeCredentialFile {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = Assert-DirectNonReparseAncestry -Path $Path -Label "Credential file" -Leaf
    if ($resolved.StartsWith($repositoryRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Credential file must remain outside source custody."
    }
    $item = Get-Item -LiteralPath $resolved -Force
    if ($item.Length -lt 1 -or $item.Length -gt 1048576 -or
        ($item.Attributes -band [IO.FileAttributes]::Directory) -ne 0) {
        throw "Credential file has an invalid bounded identity."
    }

    try {
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $allowedSids = @($currentSid, "S-1-5-18", "S-1-5-32-544")
        $acl = Get-Acl -LiteralPath $resolved
        $ownerSid = ([Security.Principal.NTAccount]$acl.Owner).Translate([Security.Principal.SecurityIdentifier]).Value
        if ($allowedSids -cnotcontains $ownerSid) { throw "unsafe" }
        $sensitiveRights = [Security.AccessControl.FileSystemRights]::ReadData -bor
            [Security.AccessControl.FileSystemRights]::Read -bor
            [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
            [Security.AccessControl.FileSystemRights]::WriteData -bor
            [Security.AccessControl.FileSystemRights]::Modify -bor
            [Security.AccessControl.FileSystemRights]::FullControl
        foreach ($rule in @($acl.Access)) {
            if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
                ($rule.FileSystemRights -band $sensitiveRights) -eq 0) { continue }
            $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
            if ($allowedSids -cnotcontains $sid) { throw "unsafe" }
        }
    }
    catch {
        throw "Credential file ACL custody is unsafe or unreadable."
    }
    return $resolved
}

function Get-CredentialProfile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$ProfileName)

    $resolved = Assert-SafeCredentialFile -Path $Path

    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create($resolved, $settings)
    $document = [Xml.XmlDocument]::new()
    $document.XmlResolver = $null
    try { $document.Load($reader) } finally { $reader.Dispose() }

    $matches = @($document.SelectNodes("/FileZilla3/Servers/Server") | Where-Object {
        $name = $_.SelectSingleNode("Name")
        $name -and [string]::Equals([string]$name.InnerText, $ProfileName, [StringComparison]::Ordinal)
    })
    if ($matches.Count -ne 1) {
        throw "The external FileZilla profile must contain exactly one matching site."
    }

    $site = $matches[0]
    $required = {
        param([string]$Name)
        $node = $site.SelectSingleNode($Name)
        if (-not $node -or [string]::IsNullOrWhiteSpace([string]$node.InnerText)) {
            throw "The deployment profile is missing a required field."
        }
        return ([string]$node.InnerText).Trim()
    }

    $hostName = & $required "Host"
    $portText = & $required "Port"
    $userName = & $required "User"
    $passwordNode = $site.SelectSingleNode("Pass")
    if (-not $passwordNode) { throw "The deployment profile is missing a required field." }
    $encoding = if ($passwordNode.Attributes["encoding"]) {
        [string]$passwordNode.Attributes["encoding"].Value
    }
    else { "" }
    if ($encoding -and -not [string]::Equals($encoding, "base64", [StringComparison]::OrdinalIgnoreCase)) {
        throw "The deployment profile password encoding is unsupported."
    }
    $password = if ($encoding) {
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$passwordNode.InnerText))
    }
    else { [string]$passwordNode.InnerText }

    $port = 0
    if ([Uri]::CheckHostName($hostName) -eq [UriHostNameType]::Unknown -or
        -not [int]::TryParse($portText, [ref]$port) -or
        $port -lt 1 -or $port -gt 65535 -or
        $userName.Length -gt 256 -or
        [string]::IsNullOrEmpty($password) -or $password.Length -gt 4096) {
        $password = $null
        throw "The deployment profile contains an invalid bounded field."
    }

    return [pscustomobject]@{
        ProfileName = $ProfileName
        HostName = $hostName
        Port = $port
        UserName = $userName
        Password = $password
    }
}

function Assert-TransportProfileBinding {
    param(
        [Parameter(Mandatory)][pscustomobject]$Profile,
        [Parameter(Mandatory)][pscustomobject]$Authority
    )

    if ([string]$Profile.ProfileName -cne [string]$Authority.transport.profile_name -or
        [string]$Profile.HostName -cne [string]$Authority.transport.host -or
        [int]$Profile.Port -ne [int]$Authority.transport.port) {
        throw "The credential profile does not match the source-controlled publication target."
    }
}

function Assert-RemoteIdentityMatch {
    param(
        [Parameter(Mandatory)][pscustomobject]$Identity,
        [Parameter(Mandatory)][int64]$Bytes,
        [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][string]$Label
    )

    if ($Identity.status -cne "present" -or [int64]$Identity.bytes -ne $Bytes -or
        [string]$Identity.sha256 -cne $Sha256) {
        throw "$Label identity mismatch."
    }
}

function Assert-RemoteMutationAdmitted {
    if (-not $script:remoteWritesAdmitted -or $null -eq $script:ownedPublicationLease) {
        throw "Remote mutation was attempted before target custody admission."
    }
    Assert-OwnedPublicationLease -Lease $script:ownedPublicationLease
    $script:remoteMutationObserved = $true
}

function New-FtpRequest {
    param([string]$RemotePath, [Parameter(Mandatory)][string]$Method)

    $encoded = Get-EncodedRemotePath -RemotePath $RemotePath
    $uri = [Uri]("ftp://{0}:{1}/{2}" -f $script:ftpHostName, $script:ftpPort, $encoded)
    $request = [Net.FtpWebRequest]::Create($uri)
    $request.Method = $Method
    $request.EnableSsl = $true
    $request.UseBinary = $true
    $request.UsePassive = $true
    $request.KeepAlive = $false
    $request.Timeout = 60000
    $request.ReadWriteTimeout = 60000
    $request.Credentials = $script:credential
    return $request
}

function Get-RemoteParentAndLeaf {
    param([Parameter(Mandatory)][string]$RemotePath)

    $validated = Assert-RelativePath -Path $RemotePath
    $slash = $validated.LastIndexOf("/")
    return [pscustomobject]@{
        Parent = if ($slash -ge 0) { $validated.Substring(0, $slash) } else { "" }
        Leaf = if ($slash -ge 0) { $validated.Substring($slash + 1) } else { $validated }
    }
}

function Read-BoundedStreamBytes {
    param(
        [Parameter(Mandatory)][IO.Stream]$Stream,
        [Parameter(Mandatory)][int64]$MaximumBytes,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    $output = [IO.MemoryStream]::new()
    $buffer = [byte[]]::new(8192)
    try {
        while ($true) {
            $read = $Stream.Read($buffer, 0, $buffer.Length)
            if ($read -eq 0) { break }
            if ($output.Length + $read -gt $MaximumBytes) { throw $FailureMessage }
            $output.Write($buffer, 0, $read)
        }
        return ,$output.ToArray()
    }
    finally { $output.Dispose() }
}

function Get-RemoteDirectoryEntries {
    param([AllowEmptyString()][string]$RemotePath)

    try {
        $request = New-FtpRequest -RemotePath $RemotePath -Method ([Net.WebRequestMethods+Ftp]::ListDirectory)
        $response = $request.GetResponse()
        try {
            $stream = $response.GetResponseStream()
            try {
                $bytes = Read-BoundedStreamBytes -Stream $stream -MaximumBytes 65536 `
                    -FailureMessage "Remote directory inventory exceeded its bound."
            }
            finally { $stream.Dispose() }
        }
        finally { $response.Dispose() }
    }
    catch {
        throw "Remote directory inventory is inaccessible or ambiguous."
    }

    try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
    catch { throw "Remote directory inventory encoding is ambiguous." }
    if ($text.IndexOf([char]0) -ge 0) { throw "Remote directory inventory encoding is ambiguous." }
    $entries = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($line in @($text -split "`r?`n")) {
        if ($line.Length -eq 0) { continue }
        if ($line.Length -gt 255 -or $line -in @(".", "..") -or
            $line.Contains("/") -or $line.Contains("\") -or $line -match "[\x00-\x1f\x7f]") {
            throw "Remote directory inventory contains an ambiguous entry."
        }
        if (-not $entries.Add($line)) { throw "Remote directory inventory contains a duplicate entry." }
    }
    return $entries
}

function Get-RemoteDirectoryState {
    param([Parameter(Mandatory)][string]$RemotePath)

    $parts = Get-RemoteParentAndLeaf -RemotePath $RemotePath
    $parentEntries = Get-RemoteDirectoryEntries -RemotePath $parts.Parent
    if (-not $parentEntries.Contains($parts.Leaf)) {
        return [pscustomobject]@{ status = "absent"; entries = $null }
    }
    $entries = Get-RemoteDirectoryEntries -RemotePath $RemotePath
    return [pscustomobject]@{ status = "present"; entries = $entries }
}

function Test-ExactFtpFileUnavailable {
    param([Parameter(Mandatory)][Exception]$Exception)

    $current = $Exception
    while ($null -ne $current.InnerException) { $current = $current.InnerException }
    if ($current -isnot [Net.WebException] -or $current.Response -isnot [Net.FtpWebResponse]) {
        return $false
    }
    try {
        return $current.Response.StatusCode -eq [Net.FtpStatusCode]::ActionNotTakenFileUnavailable
    }
    finally { $current.Response.Dispose() }
}

function Invoke-RemoteSizeProbe {
    param([Parameter(Mandatory)][string]$RemotePath)

    try {
        $request = New-FtpRequest -RemotePath $RemotePath -Method ([Net.WebRequestMethods+Ftp]::GetFileSize)
        $response = $request.GetResponse()
        try { $size = [int64]$response.ContentLength } finally { $response.Dispose() }
        if ($size -lt 0 -or $size -gt 1048576) {
            throw "Remote SIZE returned an invalid bounded value."
        }
        return [pscustomobject]@{ status = "present"; bytes = $size }
    }
    catch {
        if (Test-ExactFtpFileUnavailable -Exception $_.Exception) {
            return [pscustomobject]@{ status = "unavailable"; bytes = $null }
        }
        throw "Remote SIZE evidence is inaccessible or ambiguous."
    }
}

function Invoke-RemoteDownloadProbe {
    param([Parameter(Mandatory)][string]$RemotePath)

    try {
        $request = New-FtpRequest -RemotePath $RemotePath -Method ([Net.WebRequestMethods+Ftp]::DownloadFile)
        $response = $request.GetResponse()
        try {
            $stream = $response.GetResponseStream()
            try {
                $bytes = Read-BoundedStreamBytes -Stream $stream -MaximumBytes 1048576 `
                    -FailureMessage "Remote file exceeded its identity bound."
            }
            finally { $stream.Dispose() }
        }
        finally { $response.Dispose() }
        return [pscustomobject]@{ status = "present"; content = $bytes }
    }
    catch {
        if (Test-ExactFtpFileUnavailable -Exception $_.Exception) {
            return [pscustomobject]@{ status = "unavailable"; content = $null }
        }
        throw "Remote download evidence is inaccessible or ambiguous."
    }
}

function Get-RemoteIdentity {
    param([Parameter(Mandatory)][string]$RemotePath)

    $parts = Get-RemoteParentAndLeaf -RemotePath $RemotePath
    $beforeEntries = Get-RemoteDirectoryEntries -RemotePath $parts.Parent
    $listedBefore = $beforeEntries.Contains($parts.Leaf)
    try {
        $sizeProbe = Invoke-RemoteSizeProbe -RemotePath $RemotePath
        $downloadProbe = Invoke-RemoteDownloadProbe -RemotePath $RemotePath
    }
    catch {
        throw "Remote LIST, SIZE, and download evidence is conflicting or ambiguous."
    }
    $afterEntries = Get-RemoteDirectoryEntries -RemotePath $parts.Parent
    $listedAfter = $afterEntries.Contains($parts.Leaf)
    if ($listedBefore -ne $listedAfter) {
        throw "Remote identity changed during proof."
    }
    if (-not $listedBefore) {
        if ($sizeProbe.status -ceq "unavailable" -and $downloadProbe.status -ceq "unavailable") {
            return [pscustomobject]@{ status = "absent"; bytes = $null; sha256 = $null; content = $null }
        }
        throw "Remote LIST, SIZE, and download evidence is conflicting or ambiguous."
    }
    if ($sizeProbe.status -cne "present" -or $downloadProbe.status -cne "present" -or
        $downloadProbe.content.Length -ne [int64]$sizeProbe.bytes) {
        throw "Remote LIST, SIZE, and download evidence is conflicting or ambiguous."
    }
    return [pscustomobject]@{
        status = "present"
        bytes = [int64]$sizeProbe.bytes
        sha256 = Get-BytesSha256 -Bytes $downloadProbe.content
        content = $downloadProbe.content
    }
}

function Test-RemoteIdentity {
    param([string]$RemotePath, [int64]$Bytes, [string]$Sha256)

    $identity = Get-RemoteIdentity -RemotePath $RemotePath
    return $identity.status -ceq "present" -and
        [int64]$identity.bytes -eq $Bytes -and
        [string]$identity.sha256 -ceq $Sha256
}

function Assert-RemoteParentDirectories {
    param([Parameter(Mandatory)][string]$RemotePath)

    $parts = $RemotePath -split "/"
    $current = @()
    for ($index = 0; $index -lt $parts.Count - 1; $index++) {
        $current += $parts[$index]
        $state = Get-RemoteDirectoryState -RemotePath ($current -join "/")
        if ($state.status -cne "present") { throw "Remote parent directory is absent or inaccessible." }
    }
}

function Send-RemoteBytesOnce {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$RemotePath,
        [Parameter(Mandatory)][string]$Sha256
    )

    Assert-RemoteMutationAdmitted
    $request = New-FtpRequest -RemotePath $RemotePath -Method ([Net.WebRequestMethods+Ftp]::UploadFile)
    $request.ContentLength = $Bytes.Length
    $output = $null
    $requestFailed = $false
    try {
        $output = $request.GetRequestStream()
        $output.Write($Bytes, 0, $Bytes.Length)
        $output.Flush()
        $output.Dispose()
        $output = $null
        $response = $request.GetResponse()
        $response.Dispose()
    }
    catch { $requestFailed = $true }
    finally { if ($output) { $output.Dispose() } }

    $actual = Get-RemoteIdentity -RemotePath $RemotePath
    if ($actual.status -cne "present" -or [int64]$actual.bytes -ne $Bytes.Length -or
        [string]$actual.sha256 -cne $Sha256) {
        if ($requestFailed) { throw "Remote upload outcome is ambiguous." }
        throw "Remote upload did not commit its exact bytes."
    }
}

function Move-RemoteFileExact {
    param(
        [Parameter(Mandatory)][string]$RemotePath,
        [Parameter(Mandatory)][string]$NewLeafName,
        [Parameter(Mandatory)][int64]$Bytes,
        [Parameter(Mandatory)][string]$Sha256
    )

    if ($NewLeafName -notmatch "^[A-Za-z0-9._-]+$") { throw "Unsafe remote rename leaf." }
    $sourceParts = Get-RemoteParentAndLeaf -RemotePath $RemotePath
    $destination = if ($sourceParts.Parent) { "$($sourceParts.Parent)/$NewLeafName" } else { $NewLeafName }
    Assert-RemoteIdentityMatch -Identity (Get-RemoteIdentity -RemotePath $RemotePath) `
        -Bytes $Bytes -Sha256 $Sha256 -Label "Remote rename source"
    if ((Get-RemoteIdentity -RemotePath $destination).status -cne "absent") {
        throw "Remote rename destination is occupied."
    }

    Assert-RemoteMutationAdmitted
    $failed = $false
    try {
        $request = New-FtpRequest -RemotePath $RemotePath -Method ([Net.WebRequestMethods+Ftp]::Rename)
        $request.RenameTo = $NewLeafName
        $response = $request.GetResponse()
        $response.Dispose()
    }
    catch { $failed = $true }

    $sourceAfter = Get-RemoteIdentity -RemotePath $RemotePath
    $destinationAfter = Get-RemoteIdentity -RemotePath $destination
    if ($sourceAfter.status -ceq "absent" -and $destinationAfter.status -ceq "present" -and
        [int64]$destinationAfter.bytes -eq $Bytes -and [string]$destinationAfter.sha256 -ceq $Sha256) {
        return
    }
    if ($failed -and $sourceAfter.status -ceq "present" -and
        [int64]$sourceAfter.bytes -eq $Bytes -and [string]$sourceAfter.sha256 -ceq $Sha256 -and
        $destinationAfter.status -ceq "absent") {
        throw "Remote rename did not commit."
    }
    throw "Remote rename outcome is ambiguous."
}

function Remove-RemoteFileExact {
    param(
        [Parameter(Mandatory)][string]$RemotePath,
        [Parameter(Mandatory)][int64]$Bytes,
        [Parameter(Mandatory)][string]$Sha256
    )

    Assert-RemoteIdentityMatch -Identity (Get-RemoteIdentity -RemotePath $RemotePath) `
        -Bytes $Bytes -Sha256 $Sha256 -Label "Remote delete source"
    Assert-RemoteMutationAdmitted
    $failed = $false
    try {
        $request = New-FtpRequest -RemotePath $RemotePath -Method ([Net.WebRequestMethods+Ftp]::DeleteFile)
        $response = $request.GetResponse()
        $response.Dispose()
    }
    catch { $failed = $true }
    $after = Get-RemoteIdentity -RemotePath $RemotePath
    if ($after.status -ceq "absent") { return }
    if ($failed -and $after.status -ceq "present" -and [int64]$after.bytes -eq $Bytes -and
        [string]$after.sha256 -ceq $Sha256) {
        throw "Remote delete did not commit."
    }
    throw "Remote delete outcome is ambiguous."
}

function Get-RemoteAuxiliaryPaths {
    param([string]$RelativePath, [string]$Nonce)

    $slash = $RelativePath.LastIndexOf("/")
    $parent = if ($slash -ge 0) { $RelativePath.Substring(0, $slash + 1) } else { "" }
    $leaf = if ($slash -ge 0) { $RelativePath.Substring($slash + 1) } else { $RelativePath }
    $extension = [IO.Path]::GetExtension($leaf)
    $stem = $leaf.Substring(0, $leaf.Length - $extension.Length)
    return [pscustomobject]@{
        StagePath = "$parent$stem.deploy-$Nonce$extension"
        StageLeaf = "$stem.deploy-$Nonce$extension"
        BackupPath = "$parent$stem.backup-$Nonce$extension"
        BackupLeaf = "$stem.backup-$Nonce$extension"
        RollbackPath = "$parent$stem.rollback-$Nonce$extension"
        RollbackLeaf = "$stem.rollback-$Nonce$extension"
        TargetLeaf = $leaf
    }
}

function Write-CreateOnlyBytes {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][byte[]]$Bytes)

    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
}

function ConvertTo-CanonicalJsonBytes {
    param([Parameter(Mandatory)]$Value)

    return [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 12) + "`n")
}

function Test-ExactIdentity {
    param($Identity, [int64]$Bytes, [string]$Sha256)

    return $Identity.status -ceq "present" -and [int64]$Identity.bytes -eq $Bytes -and
        [string]$Identity.sha256 -ceq $Sha256
}

function Assert-DeploymentSourceClosure {
    param(
        [Parameter(Mandatory)][string]$StagingRoot,
        [Parameter(Mandatory)][pscustomobject]$Manifest
    )

    $root = Assert-DirectNonReparseAncestry -Path $StagingRoot -Label "Deployment source staging" -Container
    $expected = @{}
    foreach ($file in @($Manifest.files)) {
        $relative = [string]$file.path
        $local = [IO.Path]::GetFullPath((Join-Path $root ($relative -replace "/", "\")))
        if (-not $local.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Deployment source staging escaped custody."
        }
        Assert-DirectNonReparseAncestry -Path $local -Label "Deployment source member" -Leaf | Out-Null
        $item = Get-Item -LiteralPath $local -Force
        if ($item.Length -ne [int64]$file.bytes -or
            (Get-FileSha256 -Path $local) -cne [string]$file.sha256) {
            throw "Deployment source member identity drifted: $relative"
        }
        $expected[$relative] = $true
    }
    $actual = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File)
    if ($actual.Count -ne $expected.Count) { throw "Deployment source inventory is not exact." }
    foreach ($item in $actual) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Deployment source inventory contains a reparse point."
        }
        $relative = $item.FullName.Substring($root.Length).TrimStart("\", "/").Replace("\", "/")
        if (-not $expected.ContainsKey($relative)) { throw "Deployment source inventory contains an unregistered member." }
    }
}

function Assert-OwnedSnapshotPath {
    param([Parameter(Mandatory)]$Snapshot)

    $root = [IO.Path]::GetFullPath([string]$Snapshot.Root)
    $parent = [IO.Path]::GetFullPath([string]$Snapshot.Parent)
    if (-not $root.StartsWith($parent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($root) -cne (".custody-snapshot-" + [string]$Snapshot.SnapshotId)) {
        throw "Owned snapshot path identity is invalid."
    }
    Assert-DirectNonReparseAncestry -Path $root -Label "Owned deployment snapshot" -Container | Out-Null
}

function Assert-SealedDeploymentSnapshot {
    param([Parameter(Mandatory)]$Snapshot)

    Assert-OwnedSnapshotPath -Snapshot $Snapshot
    $expected = @{}
    foreach ($record in @($Snapshot.Files)) { $expected[[string]$record.path] = $record }
    $expected[".custody-owner.json"] = [pscustomobject]@{
        path = ".custody-owner.json"; bytes = $Snapshot.OwnerBytes.Length; sha256 = $Snapshot.OwnerSha256
    }
    $expected[".custody-seal.json"] = [pscustomobject]@{
        path = ".custody-seal.json"; bytes = $Snapshot.SealBytes.Length; sha256 = $Snapshot.SealSha256
    }
    $actual = @(Get-ChildItem -LiteralPath $Snapshot.Root -Recurse -Force -File)
    if ($actual.Count -ne $expected.Count) { throw "Owned deployment snapshot inventory drifted." }
    foreach ($item in $actual) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Owned deployment snapshot contains a reparse point."
        }
        $relative = $item.FullName.Substring($Snapshot.Root.Length).TrimStart("\", "/").Replace("\", "/")
        if (-not $expected.ContainsKey($relative)) { throw "Owned deployment snapshot has an extra member." }
        $record = $expected[$relative]
        if ($item.Length -ne [int64]$record.bytes -or
            (Get-FileSha256 -Path $item.FullName) -cne [string]$record.sha256) {
            throw "Owned deployment snapshot member identity drifted."
        }
    }
}

function Remove-OwnedDeploymentSnapshot {
    param([Parameter(Mandatory)]$Snapshot)

    Assert-OwnedSnapshotPath -Snapshot $Snapshot
    $originalRoot = [IO.Path]::GetFullPath([string]$Snapshot.Root)
    $ownerPath = Join-Path $originalRoot ".custody-owner.json"
    if (-not (Test-Path -LiteralPath $ownerPath -PathType Leaf) -or
        (Get-FileSha256 -Path $ownerPath) -cne [string]$Snapshot.OwnerSha256) {
        throw "Owned snapshot cleanup identity is unavailable."
    }
    $quarantine = "$originalRoot.deleting-$([Guid]::NewGuid().ToString('N'))"
    if (Test-Path -LiteralPath $quarantine) {
        throw "Owned snapshot cleanup quarantine is occupied."
    }
    [IO.Directory]::Move($originalRoot, $quarantine)
    if (Test-Path -LiteralPath $originalRoot) {
        throw "Owned snapshot cleanup rename outcome is ambiguous."
    }
    Assert-DirectNonReparseAncestry -Path $quarantine -Label "Quarantined deployment snapshot" -Container | Out-Null
    $Snapshot.Root = $quarantine
    $ownerPath = Join-Path $quarantine ".custody-owner.json"
    if ((Get-FileSha256 -Path $ownerPath) -cne [string]$Snapshot.OwnerSha256) {
        throw "Quarantined snapshot ownership identity drifted."
    }
    $allowed = @(".custody-owner.json", ".custody-seal.json") + @($Snapshot.Files | ForEach-Object { [string]$_.path })
    $items = @(Get-ChildItem -LiteralPath $quarantine -Recurse -Force)
    foreach ($item in $items) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Owned snapshot cleanup encountered a reparse point."
        }
        if (-not $item.PSIsContainer) {
            $relative = $item.FullName.Substring($quarantine.Length).TrimStart("\", "/").Replace("\", "/")
            if ($allowed -cnotcontains $relative) { throw "Owned snapshot cleanup encountered an unknown member." }
        }
    }
    foreach ($item in @($items | Where-Object { -not $_.PSIsContainer } | Sort-Object FullName -Descending)) {
        Assert-DirectNonReparseAncestry -Path $item.FullName -Label "Owned snapshot cleanup member" -Leaf | Out-Null
        $item.IsReadOnly = $false
        Remove-Item -LiteralPath $item.FullName -Force
    }
    foreach ($item in @($items | Where-Object { $_.PSIsContainer } | Sort-Object { $_.FullName.Length } -Descending)) {
        Assert-DirectNonReparseAncestry -Path $item.FullName -Label "Owned snapshot cleanup directory" -Container | Out-Null
        Remove-Item -LiteralPath $item.FullName
    }
    Assert-DirectNonReparseAncestry -Path $quarantine -Label "Quarantined deployment snapshot" -Container | Out-Null
    Remove-Item -LiteralPath $quarantine
    if (Test-Path -LiteralPath $quarantine) { throw "Owned snapshot cleanup did not commit." }
}

function New-OwnedDeploymentSnapshot {
    param(
        [Parameter(Mandatory)][string]$StagingRoot,
        [Parameter(Mandatory)][pscustomobject]$Manifest,
        [Parameter(Mandatory)]$OperationIdentity
    )

    Assert-DeploymentSourceClosure -StagingRoot $StagingRoot -Manifest $Manifest
    $stagingParent = Assert-DirectNonReparseAncestry -Path (Split-Path -Parent $StagingRoot) `
        -Label "Deployment staging parent" -Container
    $parent = $stagingParent

    $snapshotId = [Guid]::NewGuid().ToString("N")
    $root = Join-Path $parent (".custody-snapshot-" + $snapshotId)
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $snapshot = [pscustomobject]@{
        Parent = $parent
        Root = $root
        SnapshotId = $snapshotId
        OwnerBytes = $null
        OwnerSha256 = $null
        SealBytes = $null
        SealSha256 = $null
        Files = [Collections.ArrayList]::new()
    }
    try {
        $owner = [ordered]@{
            schema = "mirust.deployment_snapshot_owner.v1"
            operation_id = [string]$Manifest.operation_id
            snapshot_id = $snapshotId
        }
        $snapshot.OwnerBytes = ConvertTo-CanonicalJsonBytes -Value $owner
        $snapshot.OwnerSha256 = Get-BytesSha256 -Bytes $snapshot.OwnerBytes
        Write-CreateOnlyBytes -Path (Join-Path $root ".custody-owner.json") -Bytes $snapshot.OwnerBytes

        foreach ($file in @($Manifest.files)) {
            $relative = [string]$file.path
            $source = [IO.Path]::GetFullPath((Join-Path $StagingRoot ($relative -replace "/", "\")))
            $bytes = Read-StableRegularFileBytes -Path $source -MaximumBytes 65536 `
                -Label "Deployment source member"
            if ($bytes.Length -ne [int64]$file.bytes -or
                (Get-BytesSha256 -Bytes $bytes) -cne [string]$file.sha256) {
                throw "Deployment source changed during snapshot copy."
            }
            $destination = [IO.Path]::GetFullPath((Join-Path $root ($relative -replace "/", "\")))
            if (-not $destination.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Snapshot member escaped operation custody."
            }
            [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
            Write-CreateOnlyBytes -Path $destination -Bytes $bytes
            [void]$snapshot.Files.Add([pscustomobject]@{
                path = $relative
                bytes = $bytes.Length
                sha256 = [string]$file.sha256
            })
        }

        $seal = [ordered]@{
            schema = "mirust.deployment_snapshot_seal.v1"
            operation_id = [string]$Manifest.operation_id
            snapshot_id = $snapshotId
            manifest_sha256 = [string]$OperationIdentity.ManifestSha256
            source_commit = [string]$OperationIdentity.SourceCommit
            source_tree = [string]$OperationIdentity.SourceTree
            publisher_commit = [string]$OperationIdentity.PublisherCommit
            publisher_tree = [string]$OperationIdentity.PublisherTree
            publisher_tool_blob = [string]$OperationIdentity.PublisherToolBlob
            publisher_tool_sha256 = [string]$OperationIdentity.PublisherToolSha256
            builder_tool_blob = [string]$OperationIdentity.BuilderToolBlob
            builder_tool_sha256 = [string]$OperationIdentity.BuilderToolSha256
            source_publisher_blob = [string]$OperationIdentity.SourcePublisherBlob
            source_builder_blob = [string]$OperationIdentity.SourceBuilderBlob
            verifier_commit = [string]$OperationIdentity.VerifierCommit
            verifier_tree = [string]$OperationIdentity.VerifierTree
            verifier_blob = [string]$OperationIdentity.VerifierBlob
            verifier_sha256 = [string]$OperationIdentity.VerifierSha256
            node_sha256 = [string]$OperationIdentity.NodeSha256
            git_sha256 = [string]$OperationIdentity.GitSha256
            files = @($snapshot.Files)
        }
        $snapshot.SealBytes = ConvertTo-CanonicalJsonBytes -Value $seal
        $snapshot.SealSha256 = Get-BytesSha256 -Bytes $snapshot.SealBytes
        Write-CreateOnlyBytes -Path (Join-Path $root ".custody-seal.json") -Bytes $snapshot.SealBytes
        foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force -File)) { $item.IsReadOnly = $true }
        Assert-SealedDeploymentSnapshot -Snapshot $snapshot
        return $snapshot
    }
    catch {
        if ($snapshot.OwnerSha256 -and (Test-Path -LiteralPath (Join-Path $root ".custody-owner.json"))) {
            try { Remove-OwnedDeploymentSnapshot -Snapshot $snapshot } catch { }
        }
        elseif (Test-Path -LiteralPath $root -PathType Container) {
            $residue = @(Get-ChildItem -LiteralPath $root -Force)
            if ($residue.Count -eq 0) { Remove-Item -LiteralPath $root }
        }
        throw
    }
}

function Get-SealedSnapshotFileBytes {
    param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)][pscustomobject]$File)

    $record = @($Snapshot.Files | Where-Object { [string]$_.path -ceq [string]$File.path })
    if ($record.Count -ne 1) { throw "Sealed snapshot member is unavailable." }
    $path = [IO.Path]::GetFullPath((Join-Path $Snapshot.Root (([string]$File.path) -replace "/", "\")))
    if (-not $path.StartsWith($Snapshot.Root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Sealed snapshot member escaped custody."
    }
    $bytes = Read-StableRegularFileBytes -Path $path -MaximumBytes 65536 `
        -Label "Sealed snapshot member"
    if ($bytes.Length -ne [int64]$record[0].bytes -or
        (Get-BytesSha256 -Bytes $bytes) -cne [string]$record[0].sha256) {
        throw "Sealed snapshot member identity drifted."
    }
    return ,$bytes
}

function Publish-ManifestFile {
    param(
        [Parameter(Mandatory)][pscustomobject]$File,
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][string]$Nonce,
        [Parameter(Mandatory)][Collections.ArrayList]$Journal
    )

    $relative = [string]$File.path
    $desiredBytes = [int64]$File.bytes
    $desiredSha256 = [string]$File.sha256
    $before = $File.expected_before
    $observedBefore = Get-RemoteIdentity -RemotePath $relative
    if ($observedBefore.status -cne [string]$before.status -or
        ($observedBefore.status -ceq "present" -and
         ([int64]$observedBefore.bytes -ne [int64]$before.bytes -or
          [string]$observedBefore.sha256 -cne [string]$before.sha256 -or
          $observedBefore.content -isnot [byte[]]))) {
        throw "Authenticated remote before-state drifted for $relative"
    }
    $auxiliary = Get-RemoteAuxiliaryPaths -RelativePath $relative -Nonce $Nonce
    $entry = [pscustomobject]@{
        Path = $relative
        DesiredBytes = $desiredBytes
        DesiredSha256 = $desiredSha256
        BeforeStatus = [string]$before.status
        BeforeBytes = if ($before.status -ceq "present") { [int64]$before.bytes } else { [int64]0 }
        BeforeSha256 = if ($before.status -ceq "present") { [string]$before.sha256 } else { $null }
        BeforeContent = if ($before.status -ceq "present") { [byte[]]$observedBefore.content } else { $null }
        Auxiliary = $auxiliary
        Mutated = $false
        State = "observed"
    }
    [void]$Journal.Add($entry)
    if ($before.status -ceq "present" -and [int64]$before.bytes -eq $desiredBytes -and
        [string]$before.sha256 -ceq $desiredSha256) {
        $entry.State = "unchanged"
        Write-Host "SKIP $relative"
        return [ordered]@{ path = $relative; status = "already-current"; bytes = $desiredBytes; sha256 = $desiredSha256 }
    }

    Assert-RemoteParentDirectories -RemotePath $relative
    foreach ($path in @($auxiliary.StagePath, $auxiliary.BackupPath, $auxiliary.RollbackPath)) {
        if ((Get-RemoteIdentity -RemotePath $path).status -cne "absent") {
            throw "Publication auxiliary path is occupied for $relative"
        }
    }
    $bytes = Get-SealedSnapshotFileBytes -Snapshot $Snapshot -File $File
    Send-RemoteBytesOnce -Bytes $bytes -RemotePath $auxiliary.StagePath -Sha256 $desiredSha256
    $entry.State = "staged"

    if ($before.status -ceq "present") {
        $entry.Mutated = $true
        Remove-RemoteFileExact -RemotePath $relative `
            -Bytes ([int64]$before.bytes) -Sha256 ([string]$before.sha256)
        $entry.State = "target-removed"
    }
    else { $entry.Mutated = $true }
    Move-RemoteFileExact -RemotePath $auxiliary.StagePath -NewLeafName $auxiliary.TargetLeaf `
        -Bytes $desiredBytes -Sha256 $desiredSha256
    $entry.State = "published"
    Assert-RemoteIdentityMatch -Identity (Get-RemoteIdentity -RemotePath $relative) `
        -Bytes $desiredBytes -Sha256 $desiredSha256 -Label "Published remote file"

    Write-Host "PUBLISH $relative"
    return [ordered]@{ path = $relative; status = "published"; bytes = $desiredBytes; sha256 = $desiredSha256 }
}

function Restore-DeploymentJournalEntry {
    param([Parameter(Mandatory)]$Entry)

    $target = Get-RemoteIdentity -RemotePath $Entry.Path
    $stage = Get-RemoteIdentity -RemotePath $Entry.Auxiliary.StagePath
    $rollback = Get-RemoteIdentity -RemotePath $Entry.Auxiliary.RollbackPath
    $targetDesired = Test-ExactIdentity -Identity $target -Bytes $Entry.DesiredBytes -Sha256 $Entry.DesiredSha256
    $stageDesired = Test-ExactIdentity -Identity $stage -Bytes $Entry.DesiredBytes -Sha256 $Entry.DesiredSha256

    if ($Entry.BeforeStatus -ceq "present") {
        if ($Entry.BeforeContent -isnot [byte[]] -or
            $Entry.BeforeContent.Length -ne [int64]$Entry.BeforeBytes -or
            (Get-BytesSha256 -Bytes $Entry.BeforeContent) -cne [string]$Entry.BeforeSha256) {
            throw "Rollback predecessor bytes are unavailable or invalid."
        }
        $targetBefore = Test-ExactIdentity -Identity $target -Bytes $Entry.BeforeBytes -Sha256 $Entry.BeforeSha256
        if (-not $targetBefore) {
            if ($targetDesired) {
                Remove-RemoteFileExact -RemotePath $Entry.Path `
                    -Bytes $Entry.DesiredBytes -Sha256 $Entry.DesiredSha256
            }
            elseif ($target.status -cne "absent") { throw "Rollback target identity is ambiguous." }
            if ($rollback.status -cne "absent") { throw "Rollback holding path is occupied." }
            Send-RemoteBytesOnce -Bytes $Entry.BeforeContent -RemotePath $Entry.Auxiliary.RollbackPath `
                -Sha256 $Entry.BeforeSha256
            Move-RemoteFileExact -RemotePath $Entry.Auxiliary.RollbackPath `
                -NewLeafName $Entry.Auxiliary.TargetLeaf -Bytes $Entry.BeforeBytes -Sha256 $Entry.BeforeSha256
        }
        Assert-RemoteIdentityMatch -Identity (Get-RemoteIdentity -RemotePath $Entry.Path) `
            -Bytes $Entry.BeforeBytes -Sha256 $Entry.BeforeSha256 -Label "Rolled-back remote target"
    }
    else {
        if ($targetDesired) {
            Remove-RemoteFileExact -RemotePath $Entry.Path `
                -Bytes $Entry.DesiredBytes -Sha256 $Entry.DesiredSha256
        }
        elseif ($target.status -cne "absent") { throw "Rollback target identity is ambiguous." }
    }

    $stage = Get-RemoteIdentity -RemotePath $Entry.Auxiliary.StagePath
    if (Test-ExactIdentity -Identity $stage -Bytes $Entry.DesiredBytes -Sha256 $Entry.DesiredSha256) {
        Remove-RemoteFileExact -RemotePath $Entry.Auxiliary.StagePath `
            -Bytes $Entry.DesiredBytes -Sha256 $Entry.DesiredSha256
    }
    elseif ($stage.status -cne "absent") { throw "Rollback staging cleanup is ambiguous." }
    $rollback = Get-RemoteIdentity -RemotePath $Entry.Auxiliary.RollbackPath
    if ($rollback.status -cne "absent") { throw "Rollback holding cleanup is ambiguous." }
    if ((Get-RemoteIdentity -RemotePath $Entry.Auxiliary.BackupPath).status -cne "absent") {
        throw "Rollback encountered an unowned legacy backup path."
    }
    $Entry.State = "rolled-back"
}

function Invoke-ReleaseRollback {
    param([Parameter(Mandatory)][Collections.ArrayList]$Journal)

    $failures = 0
    for ($index = $Journal.Count - 1; $index -ge 0; $index--) {
        try {
            Restore-DeploymentJournalEntry -Entry $Journal[$index]
            Write-Host "ROLLBACK $($Journal[$index].Path)"
        }
        catch { $failures++ }
    }
    if ($failures -ne 0) { throw "Release rollback could not prove exact restoration for every journal entry." }
}

function Complete-ReleaseTransaction {
    param([Parameter(Mandatory)][Collections.ArrayList]$Journal)

    foreach ($entry in @($Journal)) {
        Assert-RemoteIdentityMatch -Identity (Get-RemoteIdentity -RemotePath $entry.Path) `
            -Bytes $entry.DesiredBytes -Sha256 $entry.DesiredSha256 -Label "Final remote target"
        foreach ($path in @(
            $entry.Auxiliary.StagePath,
            $entry.Auxiliary.BackupPath,
            $entry.Auxiliary.RollbackPath
        )) {
            if ((Get-RemoteIdentity -RemotePath $path).status -cne "absent") {
                throw "Final transaction auxiliary state is ambiguous."
            }
        }
        $entry.State = "committed"
    }
}

function Assert-ManifestRemoteBeforeState {
    param(
        [Parameter(Mandatory)][pscustomobject]$Manifest,
        [Parameter(Mandatory)][string]$Nonce
    )

    foreach ($file in @($Manifest.files)) {
        $relative = [string]$file.path
        $expected = $file.expected_before
        $actual = Get-RemoteIdentity -RemotePath $relative
        if ($actual.status -cne [string]$expected.status -or
            ($actual.status -ceq "present" -and
             ([int64]$actual.bytes -ne [int64]$expected.bytes -or
              [string]$actual.sha256 -cne [string]$expected.sha256))) {
            throw "Rollback did not restore the complete authenticated before-state."
        }
        $auxiliary = Get-RemoteAuxiliaryPaths -RelativePath $relative -Nonce $Nonce
        foreach ($path in @($auxiliary.StagePath, $auxiliary.BackupPath, $auxiliary.RollbackPath)) {
            if ((Get-RemoteIdentity -RemotePath $path).status -cne "absent") {
                throw "Rollback did not remove every operation auxiliary."
            }
        }
    }
    foreach ($retired in @($Manifest.retired_paths)) {
        if ((Get-RemoteIdentity -RemotePath ([string]$retired.path)).status -cne "absent") {
            throw "Rollback did not preserve every authenticated retirement."
        }
    }
}

function Assert-OwnedPublicationLease {
    param([Parameter(Mandatory)]$Lease)

    $expectedParent = [IO.Path]::GetFullPath((Join-Path $repositoryRoot "deploy\staging"))
    $expectedPath = [IO.Path]::GetFullPath((Join-Path $expectedParent ".mirust-publication.lock"))
    if ($Lease.Released -or $null -eq $Lease.Stream -or
        $Lease.Stream.SafeFileHandle.IsClosed -or $Lease.Stream.SafeFileHandle.IsInvalid -or
        [string]$Lease.Path -cne $expectedPath -or [string]$Lease.Parent -cne $expectedParent) {
        throw "Exclusive publication lease ownership is unavailable."
    }
    Assert-DirectNonReparseAncestry -Path $Lease.Parent -Label "Publication lease parent" -Container | Out-Null
    Assert-DirectNonReparseAncestry -Path $Lease.Path -Label "Publication lease" -Leaf | Out-Null
    if ([int64]$Lease.Stream.Length -ne [int64]$Lease.OwnerBytes.Length) {
        throw "Exclusive publication lease identity drifted."
    }
    $position = $Lease.Stream.Position
    try {
        $Lease.Stream.Position = 0
        $observed = [byte[]]::new($Lease.OwnerBytes.Length)
        $offset = 0
        while ($offset -lt $observed.Length) {
            $read = $Lease.Stream.Read($observed, $offset, $observed.Length - $offset)
            if ($read -eq 0) { throw "Exclusive publication lease ended early." }
            $offset += $read
        }
        if ((Get-BytesSha256 -Bytes $observed) -cne [string]$Lease.OwnerSha256) {
            throw "Exclusive publication lease identity drifted."
        }
    }
    finally { $Lease.Stream.Position = $position }
}

function New-ExclusivePublicationLease {
    param(
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$PublisherCommit,
        [Parameter(Mandatory)][string]$SnapshotSealSha256
    )

    $leaseId = [Guid]::NewGuid().ToString("N")
    $parent = Assert-DirectNonReparseAncestry `
        -Path (Join-Path $repositoryRoot "deploy\staging") `
        -Label "Publication lease parent" -Container
    $leasePath = [IO.Path]::GetFullPath((Join-Path $parent ".mirust-publication.lock"))
    $owner = [ordered]@{
        schema = "mirust.exclusive_publication_lease.v1"
        operation_id = $OperationId
        lease_id = $leaseId
        publisher_commit = $PublisherCommit
        snapshot_seal_sha256 = $SnapshotSealSha256
    }
    $ownerBytes = ConvertTo-CanonicalJsonBytes -Value $owner
    $stream = $null
    $options = [IO.FileOptions]([int][IO.FileOptions]::DeleteOnClose -bor [int][IO.FileOptions]::WriteThrough)
    try {
        $stream = [IO.FileStream]::new(
            $leasePath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None,
            4096,
            $options
        )
        $stream.Write($ownerBytes, 0, $ownerBytes.Length)
        $stream.Flush($true)
    }
    catch {
        if ($null -ne $stream) { $stream.Dispose() }
        throw "Exclusive publication lease is occupied or inaccessible."
    }
    $lease = [pscustomobject]@{
        Parent = $parent
        Path = $leasePath
        OperationId = $OperationId
        LeaseId = $leaseId
        OwnerBytes = $ownerBytes
        OwnerSha256 = Get-BytesSha256 -Bytes $ownerBytes
        Stream = $stream
        Released = $false
    }
    try {
        Assert-OwnedPublicationLease -Lease $lease
        $script:ownedPublicationLease = $lease
        return $lease
    }
    catch {
        $stream.Dispose()
        throw
    }
}

function Remove-ExactOwnedPublicationLease {
    param([Parameter(Mandatory)]$Lease)

    Assert-OwnedPublicationLease -Lease $Lease
    $path = [string]$Lease.Path
    try {
        $Lease.Stream.Dispose()
        $Lease.Stream = $null
        $Lease.Released = $true
        $script:ownedPublicationLease = $null
    }
    catch { throw "Exclusive publication lease release failed." }
    if (Test-Path -LiteralPath $path) {
        throw "Exclusive publication lease release outcome is ambiguous."
    }
}

function Assert-PredecessorSemantics {
    param(
        [Parameter(Mandatory)][pscustomobject]$Document,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][pscustomobject]$Authority
    )

    if ($Role -ceq "release-marker") {
        Assert-ExactProperties -Value $Document -Expected @(
            "schema", "site_id", "origin", "release_id", "version", "release_date",
            "last_publish_date", "updates_path", "status", "scope"
        ) -Label "Public predecessor release marker"
        if ($Document.site_id -cne "mirust.com" -or $Document.origin -cne [string]$Authority.origin -or
            $Document.release_id -cne [string]$Authority.predecessor.release_id -or
            $Document.version -cne [string]$Authority.predecessor.version -or
            $Document.release_date -cne "2026-08-29" -or $Document.last_publish_date -cne "2026-08-29" -or
            $Document.updates_path -cne "/.well-known/site-release-history.json" -or
            $Document.status -cne "published" -or $Document.scope -cne "bounded-root-discovery-only") {
            throw "Public predecessor release marker is newer, divergent, or inconsistent."
        }
        return
    }

    if ($Role -ceq "release-history") {
        Assert-ExactProperties -Value $Document -Expected @(
            "schema", "site_id", "origin", "current_release_id", "releases"
        ) -Label "Public predecessor release history"
        $releases = @($Document.releases)
        if ($Document.site_id -cne "mirust.com" -or $Document.origin -cne [string]$Authority.origin -or
            $Document.current_release_id -cne [string]$Authority.predecessor.release_id -or
            $releases.Count -ne 1 -or $releases[0].release_id -cne [string]$Authority.predecessor.release_id -or
            $releases[0].version -cne [string]$Authority.predecessor.version -or
            $releases[0].release_date -cne "2026-08-29" -or
            $releases[0].last_publish_date -cne "2026-08-29") {
            throw "Public predecessor release history is newer, divergent, or inconsistent."
        }
        return
    }

    if ($Role -ceq "site-manifest") {
        Assert-ExactProperties -Value $Document -Expected @(
            "schema", "site", "version", "release_id", "release_date", "scope",
            "wordpress_source_included", "current_lanes", "redirect_only", "source_policy", "boundaries"
        ) -Label "Public predecessor site manifest"
        if ($Document.site -cne [string]$Authority.origin -or
            $Document.version -cne [string]$Authority.predecessor.version -or
            $Document.release_id -cne [string]$Authority.predecessor.release_id -or
            $Document.release_date -cne "2026-08-29" -or
            $Document.scope -cne "bounded-root-discovery-only" -or
            $Document.wordpress_source_included -ne $false -or
            @($Document.current_lanes).Count -ne 4) {
            throw "Public predecessor site manifest is newer, divergent, or inconsistent."
        }
        return
    }

    throw "Public predecessor document role is unsupported."
}

function Assert-PredecessorDocumentBytes {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][pscustomobject]$Descriptor,
        [Parameter(Mandatory)][pscustomobject]$Authority
    )

    if ($Bytes.Length -ne [int64]$Descriptor.bytes -or
        (Get-BytesSha256 -Bytes $Bytes) -cne [string]$Descriptor.sha256) {
        throw "Public predecessor $($Descriptor.role) byte identity mismatch."
    }
    $document = ConvertFrom-StrictUtf8Json -Bytes $Bytes -Label "Public predecessor $($Descriptor.role)"
    if ([string]$document.schema -cne [string]$Descriptor.schema) {
        throw "Public predecessor $($Descriptor.role) schema is invalid."
    }
    Assert-PredecessorSemantics -Document $document -Role ([string]$Descriptor.role) -Authority $Authority
}

function Read-BoundedHttpContent {
    param(
        [Parameter(Mandatory)][Net.Http.HttpContent]$Content,
        [Parameter(Mandatory)][int64]$MaximumBytes
    )

    $stream = $Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    try {
        return ,(Read-BoundedStreamBytes -Stream $stream -MaximumBytes $MaximumBytes `
            -FailureMessage "HTTPS response exceeded its byte bound.")
    }
    finally { $stream.Dispose() }
}

function Assert-UnambiguousHttpResponse {
    param(
        [Parameter(Mandatory)][Net.Http.HttpResponseMessage]$Response,
        [Parameter(Mandatory)][Uri]$ExpectedUri,
        [Parameter(Mandatory)][int64]$ExpectedBytes,
        [string[]]$ExpectedMediaTypes = @("application/json")
    )

    if ([int]$Response.StatusCode -ne 200 -or
        $null -eq $Response.RequestMessage -or
        $Response.RequestMessage.RequestUri.AbsoluteUri -cne $ExpectedUri.AbsoluteUri -or
        $null -ne $Response.Headers.Location -or
        $Response.Headers.Contains("Age") -or $Response.Headers.Contains("Warning") -or
        $Response.Content.Headers.ContentEncoding.Count -ne 0 -or
        $null -ne $Response.Content.Headers.ContentRange -or
        ($null -ne $Response.Content.Headers.ContentLength -and
         [int64]$Response.Content.Headers.ContentLength -ne $ExpectedBytes) -or
        $null -eq $Response.Content.Headers.ContentType -or
        $ExpectedMediaTypes -cnotcontains [string]$Response.Content.Headers.ContentType.MediaType) {
        throw "HTTPS response was redirected, cached ambiguously, transformed, or unbounded."
    }
    foreach ($headerName in @("X-Cache", "X-Cache-Hits", "CF-Cache-Status")) {
        if ($Response.Headers.Contains($headerName)) {
            $values = [string]::Join(",", @($Response.Headers.GetValues($headerName)))
            if ($values -match "(?i)(hit|stale|revalidated|updating)") {
                throw "HTTPS response was served from an ambiguous cache state."
            }
        }
    }
}

function Assert-UnambiguousHttpDenial {
    param(
        [Parameter(Mandatory)][Net.Http.HttpResponseMessage]$Response,
        [Parameter(Mandatory)][Uri]$ExpectedUri,
        [Parameter(Mandatory)][int[]]$AllowedStatusCodes
    )

    $status = [int]$Response.StatusCode
    if ($AllowedStatusCodes -notcontains $status -or ($status -ge 200 -and $status -lt 400) -or
        $null -eq $Response.RequestMessage -or
        $Response.RequestMessage.RequestUri.AbsoluteUri -cne $ExpectedUri.AbsoluteUri -or
        $null -ne $Response.Headers.Location -or $Response.Headers.Contains("Age") -or
        $Response.Headers.Contains("Warning") -or $Response.Content.Headers.ContentEncoding.Count -ne 0 -or
        $null -ne $Response.Content.Headers.ContentRange -or
        ($null -ne $Response.Content.Headers.ContentLength -and
         [int64]$Response.Content.Headers.ContentLength -gt 65536)) {
        throw "HTTPS denial or absence proof was redirected, cached, transformed, or ambiguous."
    }
    foreach ($headerName in @("X-Cache", "X-Cache-Hits", "CF-Cache-Status")) {
        if ($Response.Headers.Contains($headerName)) {
            $values = [string]::Join(",", @($Response.Headers.GetValues($headerName)))
            if ($values -match "(?i)(hit|stale|revalidated|updating)") {
                throw "HTTPS denial or absence proof came from an ambiguous cache state."
            }
        }
    }
}

function New-NoCacheHttpRequest {
    param(
        [Parameter(Mandatory)][Uri]$Uri,
        [Parameter(Mandatory)][string]$UserAgent,
        [string]$Accept = "*/*"
    )

    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $Uri)
    $request.Headers.Accept.ParseAdd($Accept)
    $request.Headers.AcceptEncoding.ParseAdd("identity")
    $request.Headers.CacheControl = [Net.Http.Headers.CacheControlHeaderValue]::new()
    $request.Headers.CacheControl.NoCache = $true
    $request.Headers.CacheControl.NoStore = $true
    $request.Headers.CacheControl.MaxAge = [TimeSpan]::Zero
    $request.Headers.Pragma.ParseAdd("no-cache")
    $request.Headers.UserAgent.ParseAdd($UserAgent)
    return $request
}

function Assert-AuthorizedHttpsUri {
    param(
        [Parameter(Mandatory)][Uri]$Uri,
        [Parameter(Mandatory)][pscustomobject]$Authority,
        [Parameter(Mandatory)][string]$ExpectedPath
    )

    if ($Uri.Scheme -cne "https" -or $Uri.Host -cne [string]$Authority.public_host -or
        $Uri.Port -ne 443 -or $Uri.AbsolutePath -cne $ExpectedPath) {
        throw "HTTPS proof URL escaped publication authority."
    }
}

function Assert-PublicPredecessor {
    param([Parameter(Mandatory)][pscustomobject]$Authority)

    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $handler.AutomaticDecompression = [Net.DecompressionMethods]::None
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    $probe = [Guid]::NewGuid().ToString("N")
    try {
        foreach ($descriptor in @($Authority.predecessor.documents)) {
            $uri = [Uri]("{0}{1}?publication_predecessor={2}" -f $Authority.origin, $descriptor.path, $probe)
            if ($uri.Scheme -cne "https" -or $uri.Host -cne [string]$Authority.public_host -or
                $uri.Port -ne 443 -or $uri.AbsolutePath -cne [string]$descriptor.path) {
                throw "Public predecessor URL escaped the publication authority."
            }
            $request = New-NoCacheHttpRequest -Uri $uri `
                -UserAgent "MiRust-Publisher-Predecessor/2.6.1" -Accept "application/json"
            try {
                $response = $client.SendAsync(
                    $request,
                    [Net.Http.HttpCompletionOption]::ResponseHeadersRead
                ).GetAwaiter().GetResult()
                try {
                    Assert-UnambiguousHttpResponse -Response $response -ExpectedUri $uri -ExpectedBytes ([int64]$descriptor.bytes)
                    $bytes = Read-BoundedHttpContent -Content $response.Content -MaximumBytes ([int64]$descriptor.bytes)
                    Assert-PredecessorDocumentBytes -Bytes $bytes -Descriptor $descriptor -Authority $Authority
                }
                finally { $response.Dispose() }
            }
            finally { $request.Dispose() }
            Write-Host "PREDECESSOR $($descriptor.role)"
        }
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Get-ExpectedHttpMediaTypes {
    param([Parameter(Mandatory)][string]$Path)

    if ($Path.EndsWith(".json", [StringComparison]::Ordinal)) { return "application/json" }
    if ($Path.EndsWith(".xml", [StringComparison]::Ordinal)) { return @("application/xml", "text/xml") }
    if ($Path.EndsWith(".txt", [StringComparison]::Ordinal)) { return "text/plain" }
    return "text/html"
}

function Assert-PostPublicationHttps {
    param(
        [Parameter(Mandatory)][pscustomobject]$Manifest,
        [Parameter(Mandatory)][pscustomobject]$Authority
    )

    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $handler.AutomaticDecompression = [Net.DecompressionMethods]::None
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    try {
        foreach ($file in @($Manifest.files | Where-Object { $null -ne $_.https_readback_path })) {
            $path = [string]$file.https_readback_path
            $uri = [Uri]("{0}{1}?publication_readback={2}" -f $Manifest.origin, $path, [Guid]::NewGuid().ToString("N"))
            Assert-AuthorizedHttpsUri -Uri $uri -Authority $Authority -ExpectedPath $path
            $mediaTypes = @(Get-ExpectedHttpMediaTypes -Path $path)
            $request = New-NoCacheHttpRequest -Uri $uri -UserAgent "MiRust-Publisher-Readback/2.6.1" `
                -Accept $mediaTypes[0]
            try {
                $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                try {
                    Assert-UnambiguousHttpResponse -Response $response -ExpectedUri $uri `
                        -ExpectedBytes ([int64]$file.bytes) -ExpectedMediaTypes $mediaTypes
                    $body = Read-BoundedHttpContent -Content $response.Content -MaximumBytes ([int64]$file.bytes)
                    if ($body.Length -ne [int64]$file.bytes -or
                        (Get-BytesSha256 -Bytes $body) -cne [string]$file.sha256) {
                        throw "HTTPS readback identity mismatch."
                    }
                }
                finally { $response.Dispose() }
            }
            finally { $request.Dispose() }
            Write-Host "READBACK $($file.path)"
        }

        foreach ($route in @($Manifest.route_smokes)) {
            $path = [string]$route.path
            $uri = [Uri]("{0}{1}?publication_smoke={2}" -f $Manifest.origin, $path, [Guid]::NewGuid().ToString("N"))
            Assert-AuthorizedHttpsUri -Uri $uri -Authority $Authority -ExpectedPath $path
            $mediaTypes = @(Get-ExpectedHttpMediaTypes -Path $path)
            $request = New-NoCacheHttpRequest -Uri $uri -UserAgent "MiRust-Publisher-Smoke/2.6.1" -Accept $mediaTypes[0]
            try {
                $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                try {
                    if ([int]$response.StatusCode -ne 200 -or $null -eq $response.RequestMessage -or
                        $response.RequestMessage.RequestUri.AbsoluteUri -cne $uri.AbsoluteUri -or
                        $null -ne $response.Headers.Location -or $response.Headers.Contains("Age") -or
                        $response.Headers.Contains("Warning") -or $response.Content.Headers.ContentEncoding.Count -ne 0 -or
                        $null -ne $response.Content.Headers.ContentRange -or
                        $null -eq $response.Content.Headers.ContentType -or
                        $mediaTypes -cnotcontains [string]$response.Content.Headers.ContentType.MediaType) {
                        throw "HTTPS route smoke response is ambiguous."
                    }
                    $body = Read-BoundedHttpContent -Content $response.Content -MaximumBytes 65536
                    try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($body) }
                    catch { throw "HTTPS route smoke encoding is invalid." }
                    if (-not $text.Contains([string]$route.contains)) { throw "HTTPS route smoke content failed." }
                }
                finally { $response.Dispose() }
            }
            finally { $request.Dispose() }
            Write-Host "SMOKE $path"
        }

        foreach ($retired in @($Manifest.retired_paths)) {
            $path = "/" + [string]$retired.path
            $uri = [Uri]("{0}{1}?publication_retired={2}" -f $Manifest.origin, $path, [Guid]::NewGuid().ToString("N"))
            Assert-AuthorizedHttpsUri -Uri $uri -Authority $Authority -ExpectedPath $path
            $request = New-NoCacheHttpRequest -Uri $uri -UserAgent "MiRust-Publisher-Retired/2.6.1"
            try {
                $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                try {
                    Assert-UnambiguousHttpDenial -Response $response -ExpectedUri $uri -AllowedStatusCodes @(404, 410)
                    [void](Read-BoundedHttpContent -Content $response.Content -MaximumBytes 65536)
                }
                finally { $response.Dispose() }
            }
            finally { $request.Dispose() }
            Write-Host "RETIRED-READBACK $($retired.path)"
        }

        foreach ($path in @($Manifest.prohibited_public_paths)) {
            $uri = [Uri]("{0}{1}?publication_private={2}" -f $Manifest.origin, $path, [Guid]::NewGuid().ToString("N"))
            Assert-AuthorizedHttpsUri -Uri $uri -Authority $Authority -ExpectedPath ([string]$path)
            $request = New-NoCacheHttpRequest -Uri $uri -UserAgent "MiRust-Publisher-Private/2.6.1"
            try {
                $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                try {
                    Assert-UnambiguousHttpDenial -Response $response -ExpectedUri $uri `
                        -AllowedStatusCodes @(401, 403, 404, 410)
                    [void](Read-BoundedHttpContent -Content $response.Content -MaximumBytes 65536)
                }
                finally { $response.Dispose() }
            }
            finally { $request.Dispose() }
            Write-Host "PROTECTED $path"
        }
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Invoke-GitLines {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $output = @(& git -C $Repository @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Git identity verification failed." }
    return @($output | ForEach-Object { [string]$_ })
}

function Invoke-GitText {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $lines = @(Invoke-GitLines -Repository $Repository -Arguments $Arguments)
    if ($lines.Count -ne 1 -or [string]::IsNullOrWhiteSpace($lines[0])) {
        throw "Git returned an invalid bounded identity."
    }
    return $lines[0].Trim()
}

function New-DeploymentOperationIdentity {
    param(
        [Parameter(Mandatory)][pscustomobject]$Authority,
        [Parameter(Mandatory)][string]$ManifestSha256,
        [Parameter(Mandatory)]$SourceAuthorityGate,
        [Parameter(Mandatory)][bool]$Strict
    )

    $publisherTool = Join-Path $repositoryRoot "tools\deploy-site.ps1"
    $builderTool = Join-Path $repositoryRoot "tools\build-site-deployment-manifest.js"
    $gitTool = Get-Command git -CommandType Application -ErrorAction Stop
    $head = Invoke-GitText -Repository $repositoryRoot -Arguments @("rev-parse", "HEAD")
    $headTree = Invoke-GitText -Repository $repositoryRoot -Arguments @("rev-parse", "HEAD^{tree}")
    return [pscustomobject]@{
        Strict = $Strict
        ManifestSha256 = $ManifestSha256
        AuthoritySha256 = $authoritySha256
        SourceCommit = [string]$Authority.candidate.content_commit
        SourceTree = [string]$Authority.candidate.content_tree
        ManifestCommit = [string]$Authority.candidate.manifest_commit
        ManifestTree = [string]$Authority.candidate.manifest_tree
        PublisherCommit = $head
        PublisherTree = $headTree
        PublisherToolBlob = Invoke-GitText -Repository $repositoryRoot `
            -Arguments @("rev-parse", "HEAD:tools/deploy-site.ps1")
        PublisherToolSha256 = Get-FileSha256 -Path $publisherTool
        BuilderToolBlob = Invoke-GitText -Repository $repositoryRoot `
            -Arguments @("rev-parse", "HEAD:tools/build-site-deployment-manifest.js")
        BuilderToolSha256 = Get-FileSha256 -Path $builderTool
        SourcePublisherBlob = Invoke-GitText -Repository $repositoryRoot `
            -Arguments @("rev-parse", (([string]$Authority.candidate.content_commit) + ":tools/deploy-site.ps1"))
        SourceBuilderBlob = Invoke-GitText -Repository $repositoryRoot `
            -Arguments @("rev-parse", (([string]$Authority.candidate.content_commit) + ":tools/build-site-deployment-manifest.js"))
        VerifierCommit = [string]$SourceAuthorityGate.VerifierCommit
        VerifierTree = [string]$SourceAuthorityGate.VerifierTree
        VerifierBlob = [string]$SourceAuthorityGate.VerifierBlob
        VerifierSha256 = [string]$SourceAuthorityGate.VerifierSha256
        NodeSha256 = [string]$SourceAuthorityGate.NodeSha256
        GitSha256 = Get-FileSha256 -Path $gitTool.Source
        VerifierRepositoryRoot = [string]$SourceAuthorityGate.RepositoryRoot
        VerifierPath = [string]$SourceAuthorityGate.VerifierPath
        NodePath = [string]$SourceAuthorityGate.NodePath
        GitPath = [string]$gitTool.Source
        PublisherToolPath = $publisherTool
        BuilderToolPath = $builderTool
    }
}

function Assert-DeploymentOperationIdentity {
    param(
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][pscustomobject]$Manifest,
        [Parameter(Mandatory)][string]$StagingRoot,
        $Snapshot,
        [switch]$RequireRemoteExact
    )

    if ($Identity.VerifierCommit -cne [string]$authority.source_verifier.commit -or
        $Identity.VerifierTree -cne [string]$authority.source_verifier.tree -or
        $Identity.VerifierBlob -cne [string]$authority.source_verifier.blob -or
        $Identity.VerifierSha256 -cne [string]$authority.source_verifier.sha256 -or
        (Invoke-GitText -Repository $repositoryRoot -Arguments @("rev-parse", "HEAD")) -cne $Identity.PublisherCommit -or
        (Invoke-GitText -Repository $repositoryRoot -Arguments @("rev-parse", "HEAD^{tree}")) -cne $Identity.PublisherTree -or
        (Invoke-GitText -Repository $repositoryRoot -Arguments @("rev-parse", ($Identity.SourceCommit + "^{tree}"))) -cne $Identity.SourceTree -or
        (Invoke-GitText -Repository $repositoryRoot -Arguments @("rev-parse", ($Identity.ManifestCommit + "^{tree}"))) -cne $Identity.ManifestTree -or
        (Invoke-GitText -Repository $repositoryRoot -Arguments @("rev-parse", "HEAD:tools/deploy-site.ps1")) -cne $Identity.PublisherToolBlob -or
        (Invoke-GitText -Repository $repositoryRoot -Arguments @("rev-parse", "HEAD:tools/build-site-deployment-manifest.js")) -cne $Identity.BuilderToolBlob -or
        (Get-FileSha256 -Path $Identity.PublisherToolPath) -cne $Identity.PublisherToolSha256 -or
        (Get-FileSha256 -Path $Identity.BuilderToolPath) -cne $Identity.BuilderToolSha256 -or
        (Get-FileSha256 -Path $authorityPath) -cne $Identity.AuthoritySha256 -or
        (Get-FileSha256 -Path $canonicalManifestPath) -cne $Identity.ManifestSha256) {
        throw "Publisher, builder, source, or manifest identity drifted."
    }
    if ((Invoke-GitText -Repository $Identity.VerifierRepositoryRoot -Arguments @("rev-parse", "HEAD")) -cne $Identity.VerifierCommit -or
        (Invoke-GitText -Repository $Identity.VerifierRepositoryRoot -Arguments @("rev-parse", "HEAD^{tree}")) -cne $Identity.VerifierTree -or
        (Invoke-GitText -Repository $Identity.VerifierRepositoryRoot `
            -Arguments @("rev-parse", "HEAD:tinyrustlm/tools/verify-single-source-authority.js")) -cne $Identity.VerifierBlob -or
        (Get-FileSha256 -Path $Identity.VerifierPath) -cne $Identity.VerifierSha256 -or
        (Get-FileSha256 -Path $Identity.NodePath) -cne $Identity.NodeSha256 -or
        (Get-FileSha256 -Path $Identity.GitPath) -cne $Identity.GitSha256) {
        throw "Canonical verifier or executable tool identity drifted."
    }
    if ($Identity.Strict) {
        $status = @(Invoke-GitLines -Repository $repositoryRoot -Arguments @("status", "--porcelain", "--untracked-files=all"))
        if ($status.Count -ne 0) { throw "Publisher worktree drifted after admission." }
    }
    if ($RequireRemoteExact) {
        $tracking = Invoke-GitText -Repository $repositoryRoot -Arguments @("rev-parse", "@{upstream}")
        $remoteLine = Invoke-GitText -Repository $repositoryRoot -Arguments @(
            "ls-remote", "--refs", [string]$authority.publisher.remote_name,
            ("refs/heads/{0}" -f [string]$authority.publisher.branch)
        )
        $remote = [string]($remoteLine -split "\s+")[0]
        if ($tracking -cne $Identity.PublisherCommit -or $remote -cne $Identity.PublisherCommit) {
            throw "Publisher remote identity drifted after admission."
        }
    }
    Assert-DeploymentSourceClosure -StagingRoot $StagingRoot -Manifest $Manifest
    if ($null -ne $Snapshot) { Assert-SealedDeploymentSnapshot -Snapshot $Snapshot }
}

function Write-CreateOnlyReceipt {
    param(
        [System.Collections.IDictionary]$Receipt,
        [string]$Path,
        [Parameter(Mandatory)][string]$OwnershipId
    )

    $resolved = [IO.Path]::GetFullPath($Path)
    $receiptRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot "deploy\receipts"))
    if (-not $resolved.StartsWith($receiptRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetExtension($resolved) -cne ".json") {
        throw "Deployment receipt path escaped its create-only root."
    }
    if (Test-Path -LiteralPath $resolved) { throw "Deployment receipt already exists." }
    Assert-DirectNonReparseAncestry -Path $receiptRoot -Label "Deployment receipt root" -Container | Out-Null
    $temporary = "$resolved.pending-$OwnershipId"
    if (Test-Path -LiteralPath $temporary) { throw "Deployment receipt staging path is occupied." }
    $bytes = ConvertTo-CanonicalJsonBytes -Value $Receipt
    $sha256 = Get-BytesSha256 -Bytes $bytes
    Write-CreateOnlyBytes -Path $temporary -Bytes $bytes
    if ((Get-FileSha256 -Path $temporary) -cne $sha256) {
        throw "Deployment receipt staging identity is invalid."
    }
    try { [IO.File]::Move($temporary, $resolved) }
    catch {
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf) -or
            (Get-FileSha256 -Path $resolved) -cne $sha256) {
            throw "Deployment receipt commit outcome is ambiguous."
        }
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf) -or
        (Get-FileSha256 -Path $resolved) -cne $sha256) {
        throw "Deployment receipt did not commit exact bytes."
    }
}

function Get-SafeFailureCode {
    param([Exception]$Exception)

    $current = $Exception
    while ($current.InnerException) { $current = $current.InnerException }
    $code = $current.GetType().FullName
    if ($current -is [Net.WebException]) {
        $code += "/" + [string]$current.Status
        if ($current.Response -is [Net.FtpWebResponse]) {
            $code += "/ftp-" + [int]$current.Response.StatusCode
        }
    }
    return $code
}

if ($MyInvocation.InvocationName -eq ".") { return }
if ($Publish -and $AllowUncommittedValidation) {
    throw "Uncommitted validation can never enable publication."
}
$authority = Read-ExactJsonFile `
    -Path $authorityPath `
    -Bytes 3156 `
    -Sha256 $authoritySha256 `
    -Label "Publication authority"
Assert-PublicationAuthority -Authority $authority
$sourceAuthorityGate = Invoke-CanonicalSourceAuthorityGate -Authority $authority -RequireRemoteExact:$Publish

$resolvedManifestPath = [IO.Path]::GetFullPath($ManifestPath)
if ($resolvedManifestPath -cne $canonicalManifestPath) {
    throw "Only the canonical committed 2.6.1 deployment manifest is admissible."
}
$manifest = Read-ExactJsonFile `
    -Path $resolvedManifestPath `
    -Bytes ([int64]$authority.candidate.manifest_bytes) `
    -Sha256 ([string]$authority.candidate.manifest_sha256) `
    -Label "Deployment manifest"
$manifestSha256 = [string]$authority.candidate.manifest_sha256

$predecessorManifestPath = [IO.Path]::GetFullPath((Join-Path $repositoryRoot ([string]$authority.predecessor.manifest_path -replace "/", "\")))
$predecessorReceiptPath = [IO.Path]::GetFullPath((Join-Path $repositoryRoot ([string]$authority.predecessor.receipt_path -replace "/", "\")))
$predecessorManifest = Read-ExactJsonFile `
    -Path $predecessorManifestPath `
    -Bytes ([int64]$authority.predecessor.manifest_bytes) `
    -Sha256 ([string]$authority.predecessor.manifest_sha256) `
    -Label "Immutable predecessor manifest"
$predecessorReceipt = Read-ExactJsonFile `
    -Path $predecessorReceiptPath `
    -Bytes ([int64]$authority.predecessor.receipt_bytes) `
    -Sha256 ([string]$authority.predecessor.receipt_sha256) `
    -Label "Immutable predecessor receipt"
if ($predecessorManifest.schema -cne "uaix.static_site_create_only_deployment_manifest.v1" -or
    $predecessorManifest.operation_id -cne "mirust-root-discovery-2.6.0-20260829-v1" -or
    $predecessorManifest.version -cne [string]$authority.predecessor.version -or
    $predecessorReceipt.schema -cne "uaix.site_create_only_deployment_receipt.v1" -or
    $predecessorReceipt.operation_id -cne [string]$predecessorManifest.operation_id -or
    $predecessorReceipt.version -cne [string]$authority.predecessor.version -or
    $predecessorReceipt.status -cne "published-and-readback-verified" -or
    $predecessorReceipt.manifest_sha256 -cne [string]$authority.predecessor.manifest_sha256) {
    throw "Immutable predecessor evidence is semantically inconsistent."
}

$origin = $null
if (-not [Uri]::TryCreate([string]$manifest.origin, [UriKind]::Absolute, [ref]$origin) -or
    $origin.Scheme -cne "https" -or $origin.AbsolutePath -cne "/" -or
    $manifest.schema -cne "uaix.static_site_create_only_deployment_manifest.v1" -or
    $manifest.operation_id -cne "mirust-root-discovery-2.6.1-20260831-v1" -or
    $manifest.site -cne "MiRust.com" -or
    $origin.Host -cne "mirust.com" -or
    $manifest.transport_profile -cne "MiRust.com" -or
    $manifest.version -cne "2.6.1" -or
    $manifest.release_date -cne "2026-08-31" -or
    $manifest.source_commit -cne [string]$authority.candidate.content_commit -or
    $manifest.source_tree -cne [string]$authority.candidate.content_tree -or
    @($manifest.files).Count -ne 11 -or
    @($manifest.retired_paths).Count -ne 12 -or
    @($manifest.route_smokes).Count -ne 4 -or
    @($manifest.prohibited_public_paths).Count -ne 4) {
    throw "Deployment manifest identity or bounds are invalid."
}

$gitStatus = @(git -C $repositoryRoot status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0) { throw "Git worktree inspection failed." }
if ($gitStatus.Count -ne 0) {
    if (-not $AllowUncommittedValidation) {
        throw "Deployment requires a clean Git worktree."
    }
    $allowedDirtyPaths = @(
        "deploy/README.md",
        "deploy/publication-authority-2.6.1.v1.json",
        "package.json",
        "tests/deployment-custody.test.ps1",
        "tests/deployment-publisher.test.js",
        "tests/site.test.js",
        "tools/build-site-deployment-manifest.js",
        "tools/deploy-site.ps1"
    )
    foreach ($line in $gitStatus) {
        $path = ([string]$line).Substring(3).Replace("\", "/")
        if ($path.Contains(" -> ")) { $path = ($path -split " -> ")[-1] }
        if ($allowedDirtyPaths -cnotcontains $path) {
            throw "Uncommitted validation encountered a non-publisher change."
        }
    }
}
$branch = Invoke-GitText -Repository $repositoryRoot -Arguments @("symbolic-ref", "--quiet", "--short", "HEAD")
$remoteUrl = Invoke-GitText -Repository $repositoryRoot -Arguments @(
    "remote", "get-url", [string]$authority.publisher.remote_name
)
if ($branch -cne [string]$authority.publisher.branch -or
    $remoteUrl -cne [string]$authority.publisher.remote_url) {
    throw "Publisher branch or remote authority is invalid."
}
$head = Invoke-GitText -Repository $repositoryRoot -Arguments @("rev-parse", "HEAD")
$tracking = Invoke-GitText -Repository $repositoryRoot -Arguments @("rev-parse", "@{upstream}")
if ($Publish) {
    $directLine = Invoke-GitText -Repository $repositoryRoot -Arguments @(
        "ls-remote", "--refs", [string]$authority.publisher.remote_name,
        ("refs/heads/{0}" -f [string]$authority.publisher.branch)
    )
    $direct = [string]($directLine -split "\s+")[0]
    if ($head -cne $tracking -or $head -cne $direct) {
        throw "Deployment requires local, tracking, and direct remote equality."
    }
}

$contentCommit = [string]$authority.candidate.content_commit
$manifestCommit = [string]$authority.candidate.manifest_commit
$contentTree = [string](git -C $repositoryRoot rev-parse ("{0}^{{tree}}" -f $contentCommit))
$manifestTree = [string](git -C $repositoryRoot rev-parse ("{0}^{{tree}}" -f $manifestCommit))
$manifestParents = [string](git -C $repositoryRoot show --no-patch --format=%P $manifestCommit)
$manifestChanges = @(git -C $repositoryRoot diff-tree --no-commit-id --name-only -r $manifestCommit)
$manifestBlob = [string](git -C $repositoryRoot rev-parse ("{0}:{1}" -f $manifestCommit, [string]$authority.candidate.manifest_path))
$workingManifestBlob = [string](git -C $repositoryRoot hash-object --no-filters $canonicalManifestPath)
if ($LASTEXITCODE -ne 0 -or $contentTree.Trim() -cne [string]$authority.candidate.content_tree -or
    $manifestTree.Trim() -cne [string]$authority.candidate.manifest_tree -or
    $manifestParents.Trim() -cne $contentCommit -or $manifestChanges.Count -ne 1 -or
    [string]$manifestChanges[0] -cne [string]$authority.candidate.manifest_path -or
    $manifestBlob.Trim() -cne $workingManifestBlob.Trim()) {
    throw "The immutable C1 content and C2 manifest relationship is invalid."
}
git -C $repositoryRoot merge-base --is-ancestor $contentCommit HEAD
if ($LASTEXITCODE -ne 0) { throw "C1 content commit is not an ancestor of the publisher commit." }
git -C $repositoryRoot merge-base --is-ancestor $manifestCommit HEAD
if ($LASTEXITCODE -ne 0) { throw "C2 manifest commit is not an ancestor of the publisher commit." }

$headTree = [string](git -C $repositoryRoot rev-parse "HEAD^{tree}")
if ($LASTEXITCODE -ne 0 -or $head.Trim() -notmatch "^[0-9a-f]{40}$" -or $headTree.Trim() -notmatch "^[0-9a-f]{40}$") {
    throw "Publisher commit identity is invalid."
}

$receiptPath = [IO.Path]::GetFullPath((Join-Path $repositoryRoot ([string]$manifest.receipt_path -replace "/", "\")))
if (Test-Path -LiteralPath $receiptPath) {
    throw "This create-only deployment operation is already terminal."
}
$stagingRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot ("deploy\staging\{0}" -f [string]$manifest.version)))
$seen = @{}
$totalBytes = [int64]0
foreach ($file in @($manifest.files)) {
    $relative = Assert-RelativePath -Path ([string]$file.path)
    if ($seen.ContainsKey($relative)) { throw "Deployment manifest contains a duplicate path." }
    $seen[$relative] = $true
    $bytes = [int64]$file.bytes
    if ($bytes -lt 1 -or $bytes -gt 65536 -or [string]$file.sha256 -notmatch "^[0-9a-f]{64}$" -or
        [string]$file.expected_before.status -notmatch "^(absent|present)$") {
        throw "Deployment manifest contains an invalid file identity."
    }
    if ($file.expected_before.status -ceq "present" -and
        ([int64]$file.expected_before.bytes -lt 1 -or
         [string]$file.expected_before.sha256 -notmatch "^[0-9a-f]{64}$")) {
        throw "Deployment manifest contains an invalid authenticated before-state."
    }
    $totalBytes += $bytes
    $localPath = [IO.Path]::GetFullPath((Join-Path $stagingRoot ($relative -replace "/", "\")))
    if (-not $localPath.StartsWith($stagingRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $localPath -PathType Leaf) -or
        (Get-Item -LiteralPath $localPath).Length -ne $bytes -or
        (Get-FileSha256 -Path $localPath) -cne [string]$file.sha256) {
        throw "Staged file identity does not match the manifest: $relative"
    }
}
$stagingFiles = @(Get-ChildItem -LiteralPath $stagingRoot -Recurse -Force -File)
if ($stagingFiles.Count -ne $seen.Count) { throw "Deployment staging closure contains an extra or missing file." }
foreach ($item in $stagingFiles) {
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Deployment staging closure contains a reparse point."
    }
    $relative = $item.FullName.Substring($stagingRoot.Length).TrimStart("\", "/").Replace("\", "/")
    if (-not $seen.ContainsKey($relative)) { throw "Deployment staging closure contains an unregistered file." }
}
$retiredSeen = @{}
foreach ($retired in @($manifest.retired_paths)) {
    $relative = Assert-RelativePath -Path ([string]$retired.path)
    if ($seen.ContainsKey($relative) -or $retiredSeen.ContainsKey($relative) -or
        [string]$retired.expected_before.status -cne "absent") {
        throw "Deployment manifest contains an invalid retired identity."
    }
    $retiredSeen[$relative] = $true
}
if ($totalBytes -gt 262144 -or [string]$manifest.files[-1].path -cne ".well-known/site-release.json" -or
    [string]$manifest.retired_paths[0].path -cne "workspace.uai") {
    throw "Deployment closure or marker ordering is invalid."
}
$sentinelEntries = @($manifest.files | Where-Object {
    [string]$_.path -ceq [string]$authority.transport.root_sentinel_path
})
if ($sentinelEntries.Count -ne 1 -or
    [int64]$sentinelEntries[0].bytes -ne [int64]$authority.transport.root_sentinel_bytes -or
    [string]$sentinelEntries[0].sha256 -cne [string]$authority.transport.root_sentinel_sha256 -or
    [string]$sentinelEntries[0].expected_before.status -cne "present" -or
    [int64]$sentinelEntries[0].expected_before.bytes -ne [int64]$authority.transport.root_sentinel_bytes -or
    [string]$sentinelEntries[0].expected_before.sha256 -cne [string]$authority.transport.root_sentinel_sha256) {
    throw "The stable remote-root sentinel is not preserved by the manifest."
}

$operationIdentity = New-DeploymentOperationIdentity -Authority $authority `
    -ManifestSha256 $manifestSha256 -SourceAuthorityGate $sourceAuthorityGate -Strict ([bool]$Publish)
$snapshot = New-OwnedDeploymentSnapshot -StagingRoot $stagingRoot -Manifest $manifest `
    -OperationIdentity $operationIdentity
Assert-DeploymentOperationIdentity -Identity $operationIdentity -Manifest $manifest `
    -StagingRoot $stagingRoot -Snapshot $snapshot
Write-Host ("VALID {0} files, {1} retired files, {2} bytes, manifest {3}, predecessor {4}" -f @($manifest.files).Count, @($manifest.retired_paths).Count, $totalBytes, $manifestSha256, [string]$authority.predecessor.release_id)
if ($AllowUncommittedValidation) { Write-Host "VALIDATION-ONLY uncommitted publisher controls; publication disabled" }
if (-not $Publish) {
    Remove-OwnedDeploymentSnapshot -Snapshot $snapshot
    exit 0
}

$startedUtc = [DateTime]::UtcNow.ToString("o")
$nonce = (Get-TextSha256 -Value ([string]$manifest.operation_id)).Substring(0, 12)
$results = @()
$retiredResults = @()
$journal = [Collections.ArrayList]::new()
$currentPath = $null
$profile = $null
$lease = $null
$leaseOwned = $false
$leaseReleased = $false
$snapshotCleanupVerified = $false
$rollbackVerified = $false
$publicationVerified = $false
$publicPredecessorVerified = $false
$targetCustodyVerified = $false
$remotePreflightVerified = $false
$terminalFailure = $null
try {
    Assert-DeploymentOperationIdentity -Identity $operationIdentity -Manifest $manifest `
        -StagingRoot $stagingRoot -Snapshot $snapshot -RequireRemoteExact
    $lease = New-ExclusivePublicationLease -OperationId ([string]$manifest.operation_id) `
        -PublisherCommit ([string]$operationIdentity.PublisherCommit) `
        -SnapshotSealSha256 ([string]$snapshot.SealSha256)
    $leaseOwned = $true
    Assert-OwnedPublicationLease -Lease $lease

    $profile = Get-CredentialProfile -Path $FileZillaProfilePath -ProfileName ([string]$manifest.transport_profile)
    Assert-TransportProfileBinding -Profile $profile -Authority $authority
    $script:ftpHostName = $profile.HostName
    $script:ftpPort = $profile.Port
    $script:credential = [Net.NetworkCredential]::new($profile.UserName, $profile.Password)
    $profile.Password = $null

    $rootSentinel = Get-RemoteIdentity -RemotePath ([string]$authority.transport.root_sentinel_path)
    Assert-RemoteIdentityMatch `
        -Identity $rootSentinel `
        -Bytes ([int64]$authority.transport.root_sentinel_bytes) `
        -Sha256 ([string]$authority.transport.root_sentinel_sha256) `
        -Label "Authenticated remote-root sentinel"
    $targetCustodyVerified = $true

    Assert-PublicPredecessor -Authority $authority
    $publicPredecessorVerified = $true

    foreach ($file in @($manifest.files)) {
        $currentPath = [string]$file.path
        $actual = Get-RemoteIdentity -RemotePath $currentPath
        $expected = $file.expected_before
        if ($actual.status -cne [string]$expected.status -or
            ($actual.status -ceq "present" -and
             ([int64]$actual.bytes -ne [int64]$expected.bytes -or
              [string]$actual.sha256 -cne [string]$expected.sha256))) {
            throw "Authenticated remote before-state drifted for $currentPath"
        }
        $auxiliary = Get-RemoteAuxiliaryPaths -RelativePath $currentPath -Nonce $nonce
        if ((Get-RemoteIdentity -RemotePath $auxiliary.StagePath).status -cne "absent" -or
            (Get-RemoteIdentity -RemotePath $auxiliary.BackupPath).status -cne "absent" -or
            (Get-RemoteIdentity -RemotePath $auxiliary.RollbackPath).status -cne "absent") {
            throw "Create-only staging identity is already occupied for $currentPath"
        }
    }

    foreach ($retired in @($manifest.retired_paths)) {
        $currentPath = [string]$retired.path
        $actual = Get-RemoteIdentity -RemotePath $currentPath
        if ($actual.status -cne "absent") {
            throw "Authenticated retired before-state drifted for $currentPath"
        }
    }

    $rootSentinel = Get-RemoteIdentity -RemotePath ([string]$authority.transport.root_sentinel_path)
    Assert-RemoteIdentityMatch `
        -Identity $rootSentinel `
        -Bytes ([int64]$authority.transport.root_sentinel_bytes) `
        -Sha256 ([string]$authority.transport.root_sentinel_sha256) `
        -Label "Authenticated remote-root sentinel recheck"
    Assert-OwnedPublicationLease -Lease $lease
    Assert-DeploymentOperationIdentity -Identity $operationIdentity -Manifest $manifest `
        -StagingRoot $stagingRoot -Snapshot $snapshot -RequireRemoteExact
    $remotePreflightVerified = $true
    $script:remoteWritesAdmitted = $true

    $regularFiles = @($manifest.files | Select-Object -First (@($manifest.files).Count - 1))
    foreach ($file in $regularFiles) {
        $currentPath = [string]$file.path
        $results += Publish-ManifestFile -File $file -Snapshot $snapshot -Nonce $nonce -Journal $journal
    }

    foreach ($retired in @($manifest.retired_paths)) {
        $currentPath = [string]$retired.path
        if ((Get-RemoteIdentity -RemotePath $currentPath).status -cne "absent") {
            throw "Historical retirement stopped being absent for $currentPath"
        }
        $retiredResults += [ordered]@{
            path = $currentPath
            status = "already-retired"
        }
        Write-Host "RETIRED $currentPath"
    }

    Assert-OwnedPublicationLease -Lease $lease
    Assert-DeploymentOperationIdentity -Identity $operationIdentity -Manifest $manifest `
        -StagingRoot $stagingRoot -Snapshot $snapshot -RequireRemoteExact
    $rootSentinel = Get-RemoteIdentity -RemotePath ([string]$authority.transport.root_sentinel_path)
    Assert-RemoteIdentityMatch -Identity $rootSentinel `
        -Bytes ([int64]$authority.transport.root_sentinel_bytes) `
        -Sha256 ([string]$authority.transport.root_sentinel_sha256) `
        -Label "Pre-marker remote-root sentinel"
    $marker = @($manifest.files)[-1]
    $currentPath = [string]$marker.path
    $results += Publish-ManifestFile -File $marker -Snapshot $snapshot -Nonce $nonce -Journal $journal

    Assert-PostPublicationHttps -Manifest $manifest -Authority $authority

    $rootSentinel = Get-RemoteIdentity -RemotePath ([string]$authority.transport.root_sentinel_path)
    Assert-RemoteIdentityMatch `
        -Identity $rootSentinel `
        -Bytes ([int64]$authority.transport.root_sentinel_bytes) `
        -Sha256 ([string]$authority.transport.root_sentinel_sha256) `
        -Label "Post-publication remote-root sentinel"
    Assert-OwnedPublicationLease -Lease $lease
    Assert-DeploymentOperationIdentity -Identity $operationIdentity -Manifest $manifest `
        -StagingRoot $stagingRoot -Snapshot $snapshot -RequireRemoteExact
    Complete-ReleaseTransaction -Journal $journal
    $publicationVerified = $true
}
catch {
    $terminalFailure = $_.Exception
    if ($leaseOwned -and -not $publicationVerified -and $script:remoteWritesAdmitted) {
        try {
            if ($journal.Count -gt 0) { Invoke-ReleaseRollback -Journal $journal }
            Assert-ManifestRemoteBeforeState -Manifest $manifest -Nonce $nonce
            $rootSentinel = Get-RemoteIdentity -RemotePath ([string]$authority.transport.root_sentinel_path)
            Assert-RemoteIdentityMatch -Identity $rootSentinel `
                -Bytes ([int64]$authority.transport.root_sentinel_bytes) `
                -Sha256 ([string]$authority.transport.root_sentinel_sha256) `
                -Label "Rolled-back remote-root sentinel"
            $rollbackVerified = $true
        }
        catch { $rollbackVerified = $false }
    }
    elseif ($leaseOwned -and -not $script:remoteMutationObserved) {
        $rollbackVerified = $true
    }
}
finally {
    if ($profile) { $profile.Password = $null }
    $script:remoteWritesAdmitted = $false
    $script:credential = $null
    $script:ftpHostName = $null
    $script:ftpPort = 0
    if ($null -ne $snapshot -and (Test-Path -LiteralPath $snapshot.Root -PathType Container)) {
        try {
            Remove-OwnedDeploymentSnapshot -Snapshot $snapshot
            $snapshotCleanupVerified = $true
        }
        catch {
            if ($null -eq $terminalFailure) { $terminalFailure = $_.Exception }
        }
    }
    else { $snapshotCleanupVerified = $true }
    if ($leaseOwned -and $null -ne $lease -and -not $lease.Released) {
        try {
            Remove-ExactOwnedPublicationLease -Lease $lease
            $leaseReleased = $true
        }
        catch {
            if ($null -eq $terminalFailure) { $terminalFailure = $_.Exception }
        }
    }
}

if (-not $leaseOwned) {
    if ($null -ne $terminalFailure) { throw $terminalFailure }
    throw "Publication ended without operation ownership."
}

$terminalStatus = if ($publicationVerified -and $snapshotCleanupVerified -and $leaseReleased) {
    "published-and-readback-verified"
}
elseif ($publicationVerified) {
    "terminal-failure-publication-verified-local-custody-incomplete"
}
elseif ($rollbackVerified) {
    "terminal-failure-no-publication"
}
else {
    "terminal-failure-rollback-incomplete"
}
$receipt = [ordered]@{
    schema = "uaix.site_create_only_deployment_receipt.v1"
    operation_id = [string]$manifest.operation_id
    site = [string]$manifest.site
    origin = [string]$manifest.origin
    version = [string]$manifest.version
    source_commit = [string]$manifest.source_commit
    source_tree = [string]$manifest.source_tree
    publisher_commit = [string]$operationIdentity.PublisherCommit
    publisher_tree = [string]$operationIdentity.PublisherTree
    manifest_commit = [string]$authority.candidate.manifest_commit
    manifest_sha256 = $manifestSha256
    publication_authority_sha256 = $authoritySha256
    operation_nonce = $nonce
    lease_id = [string]$lease.LeaseId
    snapshot_seal_sha256 = [string]$snapshot.SealSha256
    started_utc = $startedUtc
    completed_utc = [DateTime]::UtcNow.ToString("o")
    status = $terminalStatus
    rollback_verified = $rollbackVerified
    publication_verified = $publicationVerified
    snapshot_cleanup_verified = $snapshotCleanupVerified
    publication_lease_released = $leaseReleased
    public_predecessor_verified = $publicPredecessorVerified
    target_custody_verified = $targetCustodyVerified
    remote_preflight_verified = $remotePreflightVerified
    remote_mutation_observed = $script:remoteMutationObserved
    transport_profile = [string]$authority.transport.profile_name
    transport_host = [string]$authority.transport.host
    transport_port = [int]$authority.transport.port
    root_sentinel_path = [string]$authority.transport.root_sentinel_path
    root_sentinel_sha256 = [string]$authority.transport.root_sentinel_sha256
    current_path = $currentPath
    file_count = @($manifest.files).Count
    total_bytes = $totalBytes
    published_count = @($results | Where-Object { $_.status -eq "published" }).Count
    already_current_count = @($results | Where-Object { $_.status -eq "already-current" }).Count
    files = $results
    retired_count = 0
    already_retired_count = $retiredResults.Count
    retired_paths = $retiredResults
}
if ($terminalStatus -cne "published-and-readback-verified") {
    if ($null -eq $terminalFailure) {
        $terminalFailure = [InvalidOperationException]::new("Publication did not reach a successful terminal state.")
    }
    $receipt["failure_code"] = Get-SafeFailureCode -Exception $terminalFailure
}
Write-CreateOnlyReceipt -Receipt $receipt -Path $receiptPath -OwnershipId ([string]$lease.LeaseId)
Write-Host "RECEIPT $($manifest.receipt_path)"
if ($terminalStatus -cne "published-and-readback-verified") { throw $terminalFailure }
