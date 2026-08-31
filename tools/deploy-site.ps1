param(
    [string]$ManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "deploy\site-deployment-manifest-2.6.1.v1.json"),
    [string]$FileZillaProfilePath = (Join-Path $env:APPDATA "FileZilla\sitemanager.xml"),
    [switch]$Publish
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Net.Http

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$script:credential = $null
$script:ftpHostName = $null
$script:ftpPort = 0

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
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

function Get-CredentialProfile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$ProfileName)

    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "The external FileZilla profile is unavailable."
    }
    $item = Get-Item -LiteralPath $resolved
    if ($item.Length -lt 1 -or $item.Length -gt 1048576) {
        throw "The external FileZilla profile has an invalid size."
    }

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
        HostName = $hostName
        Port = $port
        UserName = $userName
        Password = $password
    }
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

function Test-FileUnavailableError {
    param([Exception]$Exception)

    $current = $Exception
    while ($current.InnerException) { $current = $current.InnerException }
    return $current -is [Net.WebException] -and
        $current.Response -is [Net.FtpWebResponse] -and
        [int]$current.Response.StatusCode -eq 550
}

function Get-RemoteIdentity {
    param([Parameter(Mandatory)][string]$RemotePath)

    try {
        $sizeRequest = New-FtpRequest -RemotePath $RemotePath -Method ([Net.WebRequestMethods+Ftp]::GetFileSize)
        $sizeResponse = $sizeRequest.GetResponse()
        try { $size = [int64]$sizeResponse.ContentLength } finally { $sizeResponse.Dispose() }
    }
    catch {
        if (Test-FileUnavailableError -Exception $_.Exception) {
            return [pscustomobject]@{ status = "absent"; bytes = $null; sha256 = $null }
        }
        throw
    }

    $request = New-FtpRequest -RemotePath $RemotePath -Method ([Net.WebRequestMethods+Ftp]::DownloadFile)
    $response = $request.GetResponse()
    $stream = $response.GetResponseStream()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
        $stream.Dispose()
        $response.Dispose()
    }
    return [pscustomobject]@{ status = "present"; bytes = $size; sha256 = $digest }
}

function Test-RemoteIdentity {
    param([string]$RemotePath, [int64]$Bytes, [string]$Sha256)

    $identity = Get-RemoteIdentity -RemotePath $RemotePath
    return $identity.status -ceq "present" -and
        [int64]$identity.bytes -eq $Bytes -and
        [string]$identity.sha256 -ceq $Sha256
}

function Test-RemoteDirectory {
    param([string]$RemotePath)

    try {
        $request = New-FtpRequest -RemotePath $RemotePath -Method ([Net.WebRequestMethods+Ftp]::ListDirectory)
        $response = $request.GetResponse()
        $response.Dispose()
        return $true
    }
    catch {
        if (Test-FileUnavailableError -Exception $_.Exception) { return $false }
        throw
    }
}

function Ensure-RemoteDirectory {
    param([string]$RemotePath)

    if ([string]::IsNullOrEmpty($RemotePath) -or (Test-RemoteDirectory -RemotePath $RemotePath)) { return }
    $request = New-FtpRequest -RemotePath $RemotePath -Method ([Net.WebRequestMethods+Ftp]::MakeDirectory)
    $response = $request.GetResponse()
    $response.Dispose()
    if (-not (Test-RemoteDirectory -RemotePath $RemotePath)) {
        throw "Remote directory creation did not commit."
    }
}

function Ensure-RemoteParentDirectories {
    param([string]$RemotePath)

    $parts = $RemotePath -split "/"
    $current = @()
    for ($index = 0; $index -lt $parts.Count - 1; $index++) {
        $current += $parts[$index]
        Ensure-RemoteDirectory -RemotePath ($current -join "/")
    }
}

function Remove-RemoteFileIfPresent {
    param([string]$RemotePath)

    if ((Get-RemoteIdentity -RemotePath $RemotePath).status -ceq "absent") { return }
    $request = New-FtpRequest -RemotePath $RemotePath -Method ([Net.WebRequestMethods+Ftp]::DeleteFile)
    $response = $request.GetResponse()
    $response.Dispose()
    if ((Get-RemoteIdentity -RemotePath $RemotePath).status -cne "absent") {
        throw "Remote file deletion did not commit."
    }
}

function Rename-RemoteFile {
    param([string]$RemotePath, [string]$NewLeafName)

    if ($NewLeafName -notmatch "^[A-Za-z0-9._-]+$") { throw "Unsafe remote rename leaf." }
    $request = New-FtpRequest -RemotePath $RemotePath -Method ([Net.WebRequestMethods+Ftp]::Rename)
    $request.RenameTo = $NewLeafName
    $response = $request.GetResponse()
    $response.Dispose()
}

function Send-RemoteFileOnce {
    param([string]$LocalPath, [string]$RemotePath)

    $bytes = [IO.File]::ReadAllBytes($LocalPath)
    $request = New-FtpRequest -RemotePath $RemotePath -Method ([Net.WebRequestMethods+Ftp]::UploadFile)
    $request.ContentLength = $bytes.Length
    $output = $null
    try {
        $output = $request.GetRequestStream()
        $output.Write($bytes, 0, $bytes.Length)
        $output.Flush()
        $output.Dispose()
        $output = $null
        try {
            $response = $request.GetResponse()
            $response.Dispose()
        }
        catch {
            # This host can report a terminal transfer error after committing
            # the complete small file. The exact remote identity below is the
            # authority; no second upload is attempted.
        }
    }
    finally {
        if ($output) { $output.Dispose() }
    }
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
        TargetLeaf = $leaf
    }
}

function Publish-ManifestFile {
    param(
        [Parameter(Mandatory)][pscustomobject]$File,
        [Parameter(Mandatory)][string]$StagingRoot,
        [Parameter(Mandatory)][string]$Nonce
    )

    $relative = [string]$File.path
    $desiredBytes = [int64]$File.bytes
    $desiredSha256 = [string]$File.sha256
    $before = $File.expected_before
    if ($before.status -ceq "present" -and
        [int64]$before.bytes -eq $desiredBytes -and
        [string]$before.sha256 -ceq $desiredSha256) {
        Write-Host "SKIP $relative"
        return [ordered]@{
            path = $relative
            status = "already-current"
            bytes = $desiredBytes
            sha256 = $desiredSha256
        }
    }

    $localPath = [IO.Path]::GetFullPath((Join-Path $StagingRoot ($relative -replace "/", "\")))
    $auxiliary = Get-RemoteAuxiliaryPaths -RelativePath $relative -Nonce $Nonce
    Ensure-RemoteParentDirectories -RemotePath $relative
    Send-RemoteFileOnce -LocalPath $localPath -RemotePath $auxiliary.StagePath
    if (-not (Test-RemoteIdentity -RemotePath $auxiliary.StagePath -Bytes $desiredBytes -Sha256 $desiredSha256)) {
        throw "Staged remote identity mismatch for $relative"
    }

    $hadTarget = $before.status -ceq "present"
    try {
        if ($hadTarget) {
            Rename-RemoteFile -RemotePath $relative -NewLeafName $auxiliary.BackupLeaf
        }
        Rename-RemoteFile -RemotePath $auxiliary.StagePath -NewLeafName $auxiliary.TargetLeaf
        if (-not (Test-RemoteIdentity -RemotePath $relative -Bytes $desiredBytes -Sha256 $desiredSha256)) {
            throw "Published remote identity mismatch for $relative"
        }
        Remove-RemoteFileIfPresent -RemotePath $auxiliary.BackupPath
    }
    catch {
        Remove-RemoteFileIfPresent -RemotePath $relative
        if ($hadTarget -and (Get-RemoteIdentity -RemotePath $auxiliary.BackupPath).status -ceq "present") {
            Rename-RemoteFile -RemotePath $auxiliary.BackupPath -NewLeafName $auxiliary.TargetLeaf
        }
        Remove-RemoteFileIfPresent -RemotePath $auxiliary.StagePath
        throw
    }

    Write-Host "PUBLISH $relative"
    return [ordered]@{
        path = $relative
        status = "published"
        bytes = $desiredBytes
        sha256 = $desiredSha256
    }
}

function Write-CreateOnlyReceipt {
    param([System.Collections.IDictionary]$Receipt, [string]$Path)

    $resolved = [IO.Path]::GetFullPath($Path)
    $receiptRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot "deploy\receipts"))
    if (-not $resolved.StartsWith($receiptRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetExtension($resolved) -cne ".json") {
        throw "Deployment receipt path escaped its create-only root."
    }
    if (Test-Path -LiteralPath $resolved) { throw "Deployment receipt already exists." }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $resolved)) | Out-Null
    $temporary = "$resolved.tmp"
    if (Test-Path -LiteralPath $temporary) { throw "Deployment receipt staging path is occupied." }
    [IO.File]::WriteAllText(
        $temporary,
        (($Receipt | ConvertTo-Json -Depth 10) + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporary -Destination $resolved
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

$manifestItem = Get-Item -LiteralPath $ManifestPath
if ($manifestItem.Length -lt 1 -or $manifestItem.Length -gt 1048576) {
    throw "Deployment manifest size is invalid."
}
$manifestSha256 = Get-FileSha256 -Path $manifestItem.FullName
$manifest = Get-Content -Raw -LiteralPath $manifestItem.FullName | ConvertFrom-Json
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
    $manifest.source_commit -notmatch "^[0-9a-f]{40}$" -or
    $manifest.source_tree -notmatch "^[0-9a-f]{40}$" -or
    @($manifest.files).Count -ne 11 -or
    @($manifest.retired_paths).Count -ne 12 -or
    @($manifest.route_smokes).Count -ne 4 -or
    @($manifest.prohibited_public_paths).Count -ne 4) {
    throw "Deployment manifest identity or bounds are invalid."
}

$gitStatus = @(git -C $repositoryRoot status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $gitStatus.Count -ne 0) {
    throw "Deployment requires a clean Git worktree."
}
git -C $repositoryRoot fetch --no-tags origin
if ($LASTEXITCODE -ne 0) { throw "Fresh remote fetch failed." }
$head = [string](git -C $repositoryRoot rev-parse HEAD)
$tracking = [string](git -C $repositoryRoot rev-parse "@{upstream}")
$fetched = [string](git -C $repositoryRoot rev-parse FETCH_HEAD)
$direct = [string]((git -C $repositoryRoot ls-remote origin HEAD) -split "\s+")[0]
if ($LASTEXITCODE -ne 0 -or $head.Trim() -cne $tracking.Trim() -or
    $head.Trim() -cne $fetched.Trim() -or $head.Trim() -cne $direct.Trim()) {
    throw "Deployment requires local, tracking, fetched, and direct remote equality."
}
git -C $repositoryRoot merge-base --is-ancestor ([string]$manifest.source_commit) HEAD
if ($LASTEXITCODE -ne 0) { throw "Manifest source commit is not an ancestor of the publisher commit." }
$sourceTree = [string](git -C $repositoryRoot rev-parse ("{0}^{{tree}}" -f [string]$manifest.source_commit))
if ($LASTEXITCODE -ne 0 -or $sourceTree.Trim() -cne [string]$manifest.source_tree) {
    throw "Manifest source tree does not match its source commit."
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

Write-Host ("VALID {0} files, {1} retired files, {2} bytes, manifest {3}" -f @($manifest.files).Count, @($manifest.retired_paths).Count, $totalBytes, $manifestSha256)
if (-not $Publish) { exit 0 }

$startedUtc = [DateTime]::UtcNow.ToString("o")
$nonce = (Get-TextSha256 -Value ([string]$manifest.operation_id)).Substring(0, 12)
$results = @()
$retiredResults = @()
$currentPath = $null
$profile = $null
try {
    $profile = Get-CredentialProfile -Path $FileZillaProfilePath -ProfileName ([string]$manifest.transport_profile)
    $script:ftpHostName = $profile.HostName
    $script:ftpPort = $profile.Port
    $script:credential = [Net.NetworkCredential]::new($profile.UserName, $profile.Password)
    $profile.Password = $null

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
            (Get-RemoteIdentity -RemotePath $auxiliary.BackupPath).status -cne "absent") {
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

    $regularFiles = @($manifest.files | Select-Object -First (@($manifest.files).Count - 1))
    foreach ($file in $regularFiles) {
        $currentPath = [string]$file.path
        $results += Publish-ManifestFile -File $file -StagingRoot $stagingRoot -Nonce $nonce
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

    $marker = @($manifest.files)[-1]
    $currentPath = [string]$marker.path
    $results += Publish-ManifestFile -File $marker -StagingRoot $stagingRoot -Nonce $nonce

    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    try {
        foreach ($file in @($manifest.files | Where-Object { $null -ne $_.https_readback_path })) {
            $url = "{0}{1}?release_readback={2}" -f $manifest.origin, $file.https_readback_path, $nonce
            $response = $client.GetAsync($url).GetAwaiter().GetResult()
            try {
                if ([int]$response.StatusCode -ne 200) { throw "HTTPS readback status failed for $($file.path)." }
                $body = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                $sha = [Security.Cryptography.SHA256]::Create()
                try {
                    $actualSha256 = ([BitConverter]::ToString($sha.ComputeHash($body))).Replace("-", "").ToLowerInvariant()
                }
                finally { $sha.Dispose() }
                if ($body.Length -ne [int64]$file.bytes -or $actualSha256 -cne [string]$file.sha256) {
                    throw "HTTPS readback identity mismatch for $($file.path)."
                }
            }
            finally { $response.Dispose() }
            Write-Host "READBACK $($file.path)"
        }

        foreach ($route in @($manifest.route_smokes)) {
            $url = "{0}{1}?release_smoke={2}" -f $manifest.origin, $route.path, $nonce
            $response = $client.GetAsync($url).GetAwaiter().GetResult()
            try {
                $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                if ([int]$response.StatusCode -ne 200 -or
                    -not $body.Contains([string]$route.contains)) {
                    throw "HTTPS route smoke failed for $($route.path)."
                }
            }
            finally { $response.Dispose() }
            Write-Host "SMOKE $($route.path)"
        }

        foreach ($retired in @($manifest.retired_paths)) {
            $url = "{0}/{1}?release_retired={2}" -f $manifest.origin, [string]$retired.path, $nonce
            $response = $client.GetAsync($url).GetAwaiter().GetResult()
            try {
                if ([int]$response.StatusCode -notin @(404, 410)) {
                    throw "A retired public file remained readable."
                }
            }
            finally { $response.Dispose() }
            Write-Host "RETIRED-READBACK $($retired.path)"
        }

        foreach ($path in @($manifest.prohibited_public_paths)) {
            $url = "{0}{1}?release_protected={2}" -f $manifest.origin, $path, $nonce
            $response = $client.GetAsync($url).GetAwaiter().GetResult()
            try {
                if ([int]$response.StatusCode -eq 200) {
                    throw "A prohibited private path became publicly readable."
                }
            }
            finally { $response.Dispose() }
            Write-Host "PROTECTED $path"
        }
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }

    $receipt = [ordered]@{
        schema = "uaix.site_create_only_deployment_receipt.v1"
        operation_id = [string]$manifest.operation_id
        site = [string]$manifest.site
        origin = [string]$manifest.origin
        version = [string]$manifest.version
        source_commit = [string]$manifest.source_commit
        source_tree = [string]$manifest.source_tree
        publisher_commit = $head.Trim()
        manifest_sha256 = $manifestSha256
        operation_nonce = $nonce
        started_utc = $startedUtc
        completed_utc = [DateTime]::UtcNow.ToString("o")
        status = "published-and-readback-verified"
        file_count = @($manifest.files).Count
        total_bytes = $totalBytes
        published_count = @($results | Where-Object { $_.status -eq "published" }).Count
        already_current_count = @($results | Where-Object { $_.status -eq "already-current" }).Count
        files = $results
        retired_count = 0
        already_retired_count = $retiredResults.Count
        retired_paths = $retiredResults
    }
    Write-CreateOnlyReceipt -Receipt $receipt -Path $receiptPath
    Write-Host "RECEIPT $receiptPath"
}
catch {
    $failure = [ordered]@{
        schema = "uaix.site_create_only_deployment_receipt.v1"
        operation_id = [string]$manifest.operation_id
        site = [string]$manifest.site
        origin = [string]$manifest.origin
        version = [string]$manifest.version
        source_commit = [string]$manifest.source_commit
        source_tree = [string]$manifest.source_tree
        publisher_commit = $head.Trim()
        manifest_sha256 = $manifestSha256
        operation_nonce = $nonce
        started_utc = $startedUtc
        completed_utc = [DateTime]::UtcNow.ToString("o")
        status = "terminal-failure"
        failure_code = Get-SafeFailureCode -Exception $_.Exception
        current_path = $currentPath
        completed_file_count = $results.Count
        files = $results
        completed_retired_count = 0
        confirmed_historical_retirement_count = $retiredResults.Count
        retired_paths = $retiredResults
    }
    Write-CreateOnlyReceipt -Receipt $failure -Path $receiptPath
    Write-Host "FAILURE_RECEIPT $receiptPath"
    throw
}
finally {
    if ($profile) { $profile.Password = $null }
    $script:credential = $null
}
