$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
. (Join-Path $repositoryRoot "tools\deploy-site.ps1")

$deployRoot = Assert-DirectNonReparseAncestry `
    -Path (Join-Path $repositoryRoot "deploy") -Label "Test deployment root" -Container
$stagingParent = [IO.Path]::GetFullPath((Join-Path $deployRoot "staging"))
$createdStagingParent = -not (Test-Path -LiteralPath $stagingParent)
if ($createdStagingParent) {
    [IO.Directory]::CreateDirectory($stagingParent) | Out-Null
}
$stagingParent = Assert-DirectNonReparseAncestry `
    -Path $stagingParent -Label "Test deployment staging parent" -Container

$script:passed = 0

function Pass {
    param([Parameter(Mandatory)][string]$Name)
    $script:passed++
    Write-Host "PASS $Name"
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Name
    )

    $threw = $false
    try { & $Action }
    catch {
        $threw = $true
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "$Name returned the wrong typed rejection: $($_.Exception.Message)"
        }
    }
    if (-not $threw) { throw "$Name did not reject the hostile fixture." }
    Pass -Name $Name
}

function Get-GitBlobBytes {
    param([Parameter(Mandatory)][string]$Spec)

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = "git.exe"
    $start.Arguments = "-C `"$repositoryRoot`" cat-file blob `"$Spec`""
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    $memory = [IO.MemoryStream]::new()
    try {
        $process.StandardOutput.BaseStream.CopyTo($memory)
        $errorText = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "git cat-file failed: $errorText" }
        return ,$memory.ToArray()
    }
    finally {
        $memory.Dispose()
        $process.Dispose()
    }
}

$authorityBytes = [IO.File]::ReadAllBytes((Join-Path $repositoryRoot "deploy\publication-authority-2.6.1.v1.json"))
$authority = ConvertFrom-StrictUtf8Json -Bytes $authorityBytes -Label "Test publication authority"
Assert-PublicationAuthority -Authority $authority
Pass -Name "exact authority descriptor"

$substitutedAuthority = ConvertFrom-Json ($authority | ConvertTo-Json -Depth 12)
$substitutedAuthority.source_verifier.sha256 = "0" * 64
Assert-Throws -Action {
    Assert-PublicationAuthority -Authority $substitutedAuthority
} -Pattern "identity is invalid" -Name "substituted source-verifier pin"

$validProfile = [pscustomobject]@{
    ProfileName = "MiRust.com"
    HostName = "ftp.mirust.com"
    Port = 21
    UserName = "not-inspected"
    Password = "not-inspected"
}
Assert-TransportProfileBinding -Profile $validProfile -Authority $authority
Pass -Name "exact profile host and port"

$wrongHost = $validProfile.PSObject.Copy()
$wrongHost.HostName = "mirust.com"
Assert-Throws -Action {
    Assert-TransportProfileBinding -Profile $wrongHost -Authority $authority
} -Pattern "does not match" -Name "wrong transport host"

$wrongProfile = $validProfile.PSObject.Copy()
$wrongProfile.ProfileName = "Another Site"
Assert-Throws -Action {
    Assert-TransportProfileBinding -Profile $wrongProfile -Authority $authority
} -Pattern "does not match" -Name "wrong transport profile"

$wrongPort = $validProfile.PSObject.Copy()
$wrongPort.Port = 22
Assert-Throws -Action {
    Assert-TransportProfileBinding -Profile $wrongPort -Authority $authority
} -Pattern "does not match" -Name "wrong transport port"

$validSentinel = [pscustomobject]@{
    status = "present"
    bytes = 113
    sha256 = "db3029d15deb26062dbf00e2aa966032e0cf31951222fe7c49e19847295fcb9f"
}
Assert-RemoteIdentityMatch -Identity $validSentinel -Bytes 113 -Sha256 $validSentinel.sha256 -Label "Fixture root sentinel"
Pass -Name "exact remote-root sentinel"

$wrongSentinel = $validSentinel.PSObject.Copy()
$wrongSentinel.sha256 = "0" * 64
Assert-Throws -Action {
    Assert-RemoteIdentityMatch -Identity $wrongSentinel -Bytes 113 -Sha256 $validSentinel.sha256 -Label "Fixture root sentinel"
} -Pattern "identity mismatch" -Name "wrong remote root"

$script:remoteWritesAdmitted = $false
Assert-Throws -Action { Assert-RemoteMutationAdmitted } -Pattern "before target custody" -Name "pre-admission mutation"
$leasePath = Join-Path $repositoryRoot "deploy\staging\.mirust-publication.lock"
if (Test-Path -LiteralPath $leasePath) { throw "Publication lease fixture path is unexpectedly occupied." }
$lease = New-ExclusivePublicationLease `
    -OperationId "fixture-publication" `
    -PublisherCommit ("a" * 40) `
    -SnapshotSealSha256 ("b" * 64)
Assert-OwnedPublicationLease -Lease $lease
Pass -Name "exclusive publication lease ownership"
Assert-Throws -Action {
    New-ExclusivePublicationLease `
        -OperationId "losing-publication" `
        -PublisherCommit ("c" * 40) `
        -SnapshotSealSha256 ("d" * 64) | Out-Null
} -Pattern "occupied or inaccessible" -Name "competing publication lease"
$script:remoteWritesAdmitted = $true
$script:remoteMutationObserved = $false
Assert-RemoteMutationAdmitted
if (-not $script:remoteMutationObserved) { throw "Admitted mutation did not become observable." }
Pass -Name "owned publication mutation observation"
Remove-ExactOwnedPublicationLease -Lease $lease
$script:remoteWritesAdmitted = $false
if (Test-Path -LiteralPath $leasePath) { throw "Publication lease was not removed on release." }
Pass -Name "publication lease release"

function New-RemoteEntrySet {
    param([switch]$ContainsLeaf)
    $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if ($ContainsLeaf) { [void]$set.Add("candidate.json") }
    return ,$set
}
function Get-RemoteDirectoryEntries {
    param([AllowEmptyString()][string]$RemotePath)
    return ,(New-RemoteEntrySet -ContainsLeaf:$script:listContainsLeaf)
}
function Invoke-RemoteSizeProbe {
    param([Parameter(Mandatory)][string]$RemotePath)
    return $script:sizeProbe
}
function Invoke-RemoteDownloadProbe {
    param([Parameter(Mandatory)][string]$RemotePath)
    return $script:downloadProbe
}

$probeBytes = [Text.UTF8Encoding]::new($false).GetBytes("probe")
$script:listContainsLeaf = $false
$script:sizeProbe = [pscustomobject]@{ status = "present"; bytes = $probeBytes.Length }
$script:downloadProbe = [pscustomobject]@{ status = "unavailable"; content = $null }
Assert-Throws -Action {
    Get-RemoteIdentity -RemotePath "candidate.json" | Out-Null
} -Pattern "conflicting or ambiguous" -Name "LIST omission with SIZE presence"

$script:sizeProbe = [pscustomobject]@{ status = "unavailable"; bytes = $null }
$script:downloadProbe = [pscustomobject]@{ status = "present"; content = $probeBytes }
Assert-Throws -Action {
    Get-RemoteIdentity -RemotePath "candidate.json" | Out-Null
} -Pattern "conflicting or ambiguous" -Name "LIST omission with download presence"

$script:downloadProbe = [pscustomobject]@{ status = "unavailable"; content = $null }
$absentIdentity = Get-RemoteIdentity -RemotePath "candidate.json"
if ($absentIdentity.status -cne "absent") { throw "Concordant absence probes were not accepted." }
Pass -Name "concordant remote absence evidence"

$script:listContainsLeaf = $true
$script:sizeProbe = [pscustomobject]@{ status = "present"; bytes = $probeBytes.Length }
$script:downloadProbe = [pscustomobject]@{ status = "present"; content = $probeBytes }
$presentIdentity = Get-RemoteIdentity -RemotePath "candidate.json"
if (-not (Test-ExactIdentity -Identity $presentIdentity -Bytes $probeBytes.Length -Sha256 (Get-BytesSha256 $probeBytes))) {
    throw "Concordant presence probes were not accepted."
}
Pass -Name "concordant remote presence evidence"

$snapshotParent = [IO.Path]::GetFullPath((Join-Path $repositoryRoot "deploy\staging"))
$snapshotId = [Guid]::NewGuid().ToString("N")
$snapshotRoot = Join-Path $snapshotParent (".custody-snapshot-" + $snapshotId)
$ownerBytes = ConvertTo-CanonicalJsonBytes -Value ([ordered]@{
    schema = "mirust.deployment_snapshot_owner.v1"; operation_id = "fixture"; snapshot_id = $snapshotId
})
$sealBytes = ConvertTo-CanonicalJsonBytes -Value ([ordered]@{
    schema = "mirust.deployment_snapshot_seal.v1"; operation_id = "fixture"; snapshot_id = $snapshotId
})
[IO.Directory]::CreateDirectory($snapshotRoot) | Out-Null
Write-CreateOnlyBytes -Path (Join-Path $snapshotRoot ".custody-owner.json") -Bytes $ownerBytes
Write-CreateOnlyBytes -Path (Join-Path $snapshotRoot ".custody-seal.json") -Bytes $sealBytes
$snapshotFixture = [pscustomobject]@{
    Parent = $snapshotParent
    Root = $snapshotRoot
    SnapshotId = $snapshotId
    OwnerBytes = $ownerBytes
    OwnerSha256 = Get-BytesSha256 -Bytes $ownerBytes
    SealBytes = $sealBytes
    SealSha256 = Get-BytesSha256 -Bytes $sealBytes
    Files = [Collections.ArrayList]::new()
}
Remove-OwnedDeploymentSnapshot -Snapshot $snapshotFixture
if ((Test-Path -LiteralPath $snapshotRoot) -or (Test-Path -LiteralPath $snapshotFixture.Root)) {
    throw "Owned snapshot quarantine cleanup left residue."
}
Pass -Name "owned snapshot quarantine cleanup"

$reparseFixture = Join-Path $repositoryRoot ("deploy\staging\.custody-reparse-test-" + [Guid]::NewGuid().ToString("N"))
$reparseTarget = "$reparseFixture-target"
$junction = Join-Path $reparseFixture "redirect"
try {
    [IO.Directory]::CreateDirectory($reparseFixture) | Out-Null
    [IO.Directory]::CreateDirectory($reparseTarget) | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $reparseTarget "member.bin"), $probeBytes)
    New-Item -ItemType Junction -Path $junction -Target $reparseTarget | Out-Null
    Assert-Throws -Action {
        Read-StableRegularFileBytes -Path (Join-Path $junction "member.bin") `
            -MaximumBytes 64 -Label "Hostile snapshot member" | Out-Null
    } -Pattern "reparse point" -Name "snapshot junction substitution"
}
finally {
    if (Test-Path -LiteralPath $junction) {
        $junctionItem = Get-Item -LiteralPath $junction -Force
        if (($junctionItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -or
            -not $junction.StartsWith($reparseFixture + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Reparse fixture cleanup identity is unsafe."
        }
        [IO.Directory]::Delete($junction)
    }
    $targetFile = Join-Path $reparseTarget "member.bin"
    if (Test-Path -LiteralPath $targetFile) { [IO.File]::Delete($targetFile) }
    if (Test-Path -LiteralPath $reparseTarget) { [IO.Directory]::Delete($reparseTarget) }
    if (Test-Path -LiteralPath $reparseFixture) { [IO.Directory]::Delete($reparseFixture) }
}

$predecessorManifest = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot "deploy\site-deployment-manifest.v1.json") | ConvertFrom-Json
$predecessorCommit = [string]$predecessorManifest.source_commit
$documentsByRole = @{}
foreach ($descriptor in @($authority.predecessor.documents)) {
    $spec = "{0}:{1}" -f $predecessorCommit, ([string]$descriptor.path).TrimStart("/")
    $bytes = Get-GitBlobBytes -Spec $spec
    Assert-PredecessorDocumentBytes -Bytes $bytes -Descriptor $descriptor -Authority $authority
    $documentsByRole[[string]$descriptor.role] = ConvertFrom-StrictUtf8Json -Bytes $bytes -Label ([string]$descriptor.role)
}
Pass -Name "exact immutable predecessor closure"

$newer = $documentsByRole["release-marker"].PSObject.Copy()
$newer.release_id = "mirust.com@2.6.2"
$newer.version = "2.6.2"
Assert-Throws -Action {
    Assert-PredecessorSemantics -Document $newer -Role "release-marker" -Authority $authority
} -Pattern "newer, divergent" -Name "newer public predecessor"

$divergent = $documentsByRole["release-history"].PSObject.Copy()
$divergent.current_release_id = "mirust.com@2.5.9"
Assert-Throws -Action {
    Assert-PredecessorSemantics -Document $divergent -Role "release-history" -Authority $authority
} -Pattern "newer, divergent" -Name "divergent public history"

$malformedBytes = [Text.UTF8Encoding]::new($false).GetBytes("{`"schema`":`n")
$malformedDescriptor = [pscustomobject]@{
    role = "release-marker"
    path = "/.well-known/site-release.json"
    bytes = $malformedBytes.Length
    sha256 = Get-BytesSha256 -Bytes $malformedBytes
    schema = "uaix.site_release.v1"
}
Assert-Throws -Action {
    Assert-PredecessorDocumentBytes -Bytes $malformedBytes -Descriptor $malformedDescriptor -Authority $authority
} -Pattern "malformed JSON" -Name "malformed public predecessor"

$substituted = Get-GitBlobBytes -Spec ("{0}:.well-known/site-release.json" -f $predecessorCommit)
$substituted[10] = $substituted[10] -bxor 1
Assert-Throws -Action {
    Assert-PredecessorDocumentBytes -Bytes $substituted -Descriptor $authority.predecessor.documents[0] -Authority $authority
} -Pattern "byte identity mismatch" -Name "substituted predecessor bytes"

$redirect = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::Found)
$redirect.RequestMessage = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, "https://mirust.com/.well-known/site-release.json")
$redirect.Headers.Location = [Uri]"https://www.mirust.com/.well-known/site-release.json"
$redirect.Content = [Net.Http.ByteArrayContent]::new([byte[]]::new(354))
$redirect.Content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new("application/json")
try {
    Assert-Throws -Action {
        Assert-UnambiguousHttpResponse -Response $redirect -ExpectedUri $redirect.RequestMessage.RequestUri -ExpectedBytes 354
    } -Pattern "redirected, cached ambiguously" -Name "redirected predecessor response"
}
finally { $redirect.Dispose() }

$cached = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::OK)
$cached.RequestMessage = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, "https://mirust.com/.well-known/site-release.json")
$cached.Headers.TryAddWithoutValidation("Age", "12") | Out-Null
$cached.Content = [Net.Http.ByteArrayContent]::new([byte[]]::new(354))
$cached.Content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new("application/json")
try {
    Assert-Throws -Action {
        Assert-UnambiguousHttpResponse -Response $cached -ExpectedUri $cached.RequestMessage.RequestUri -ExpectedBytes 354
    } -Pattern "redirected, cached ambiguously" -Name "cached predecessor response"
}
finally { $cached.Dispose() }

$script:remoteFixture = @{}
$script:removedFixturePaths = @()
$script:movedFixturePaths = @()
function Get-RemoteIdentity {
    param([Parameter(Mandatory)][string]$RemotePath)
    if (-not $script:remoteFixture.ContainsKey($RemotePath)) {
        return [pscustomobject]@{ status = "absent"; bytes = $null; sha256 = $null; content = $null }
    }
    return $script:remoteFixture[$RemotePath]
}
function Send-RemoteBytesOnce {
    param([byte[]]$Bytes, [string]$RemotePath, [string]$Sha256)
    if ((Get-RemoteIdentity -RemotePath $RemotePath).status -cne "absent" -or
        (Get-BytesSha256 -Bytes $Bytes) -cne $Sha256) {
        throw "fixture upload mismatch"
    }
    $script:remoteFixture[$RemotePath] = [pscustomobject]@{
        status = "present"; bytes = $Bytes.Length; sha256 = $Sha256; content = [byte[]]$Bytes
    }
}
function Move-RemoteFileExact {
    param([string]$RemotePath, [string]$NewLeafName, [int64]$Bytes, [string]$Sha256)
    $source = Get-RemoteIdentity -RemotePath $RemotePath
    if (-not (Test-ExactIdentity -Identity $source -Bytes $Bytes -Sha256 $Sha256)) { throw "fixture source mismatch" }
    $parts = Get-RemoteParentAndLeaf -RemotePath $RemotePath
    $destination = if ($parts.Parent) { "$($parts.Parent)/$NewLeafName" } else { $NewLeafName }
    if ((Get-RemoteIdentity -RemotePath $destination).status -cne "absent") { throw "fixture destination occupied" }
    $script:remoteFixture.Remove($RemotePath)
    $script:remoteFixture[$destination] = $source
    $script:movedFixturePaths += $RemotePath
}
function Remove-RemoteFileExact {
    param([string]$RemotePath, [int64]$Bytes, [string]$Sha256)
    $source = Get-RemoteIdentity -RemotePath $RemotePath
    if (-not (Test-ExactIdentity -Identity $source -Bytes $Bytes -Sha256 $Sha256)) { throw "fixture delete mismatch" }
    $script:remoteFixture.Remove($RemotePath)
    $script:removedFixturePaths += $RemotePath
}
function New-FixtureJournalEntry {
    param([string]$Path, [string]$Nonce, [byte[]]$BeforeContent, [byte[]]$DesiredContent)
    return [pscustomobject]@{
        Path = $Path
        DesiredBytes = $DesiredContent.Length
        DesiredSha256 = Get-BytesSha256 -Bytes $DesiredContent
        BeforeStatus = "present"
        BeforeBytes = $BeforeContent.Length
        BeforeSha256 = Get-BytesSha256 -Bytes $BeforeContent
        BeforeContent = [byte[]]$BeforeContent
        Auxiliary = Get-RemoteAuxiliaryPaths -RelativePath $Path -Nonce $Nonce
        Mutated = $true
        State = "published"
    }
}

$oldBytes = [Text.UTF8Encoding]::new($false).GetBytes("old-state")
$newBytes = [Text.UTF8Encoding]::new($false).GetBytes("new-state")
$oldSha = Get-BytesSha256 -Bytes $oldBytes
$newSha = Get-BytesSha256 -Bytes $newBytes
$entry = New-FixtureJournalEntry -Path "llms.txt" -Nonce "fixture" `
    -BeforeContent $oldBytes -DesiredContent $newBytes
$script:remoteFixture["llms.txt"] = [pscustomobject]@{
    status = "present"; bytes = $newBytes.Length; sha256 = $newSha; content = $newBytes
}
Restore-DeploymentJournalEntry -Entry $entry
if (-not (Test-ExactIdentity -Identity (Get-RemoteIdentity "llms.txt") `
        -Bytes $oldBytes.Length -Sha256 $oldSha)) {
    throw "Rollback did not restore exact locally journaled predecessor bytes."
}
Pass -Name "local predecessor-byte rollback"

$script:remoteFixture = @{}
$script:removedFixturePaths = @()
$absentEntry = [pscustomobject]@{
    Path = "new-route.txt"
    DesiredBytes = $newBytes.Length
    DesiredSha256 = $newSha
    BeforeStatus = "absent"
    BeforeBytes = [int64]0
    BeforeSha256 = $null
    BeforeContent = $null
    Auxiliary = Get-RemoteAuxiliaryPaths -RelativePath "new-route.txt" -Nonce "absent"
    Mutated = $true
    State = "published"
}
$script:remoteFixture[$absentEntry.Path] = [pscustomobject]@{
    status = "present"; bytes = $newBytes.Length; sha256 = $newSha; content = $newBytes
}
$script:remoteFixture[$absentEntry.Auxiliary.StagePath] = [pscustomobject]@{
    status = "present"; bytes = $newBytes.Length; sha256 = $newSha; content = $newBytes
}
Restore-DeploymentJournalEntry -Entry $absentEntry
if ((Get-RemoteIdentity -RemotePath $absentEntry.Path).status -cne "absent" -or
    (Get-RemoteIdentity -RemotePath $absentEntry.Auxiliary.StagePath).status -cne "absent") {
    throw "Rollback did not restore an absent predecessor and remove its staged residue."
}
Pass -Name "absent predecessor rollback"

$script:remoteFixture = @{}
$script:removedFixturePaths = @()
$script:movedFixturePaths = @()
$journal = [Collections.ArrayList]::new()
foreach ($path in @("llms.txt", ".well-known/site-release.json")) {
    $item = New-FixtureJournalEntry -Path $path -Nonce "release" `
        -BeforeContent $oldBytes -DesiredContent $newBytes
    [void]$journal.Add($item)
    $script:remoteFixture[$path] = [pscustomobject]@{
        status = "present"; bytes = $newBytes.Length; sha256 = $newSha; content = $newBytes
    }
}
Invoke-ReleaseRollback -Journal $journal
if ($script:movedFixturePaths[0] -cne ".well-known/site-release.rollback-release.json" -or
    -not (Test-ExactIdentity -Identity (Get-RemoteIdentity "llms.txt") -Bytes $oldBytes.Length -Sha256 $oldSha) -or
    -not (Test-ExactIdentity -Identity (Get-RemoteIdentity ".well-known/site-release.json") `
        -Bytes $oldBytes.Length -Sha256 $oldSha)) {
    throw "Release-wide rollback did not restore the marker first and exact predecessor bytes."
}
Pass -Name "post-marker release-wide exact rollback"

$miniManifest = [pscustomobject]@{
    files = @(
        [pscustomobject]@{
            path = "llms.txt"
            expected_before = [pscustomobject]@{ status = "present"; bytes = $oldBytes.Length; sha256 = $oldSha }
        },
        [pscustomobject]@{
            path = ".well-known/site-release.json"
            expected_before = [pscustomobject]@{ status = "present"; bytes = $oldBytes.Length; sha256 = $oldSha }
        }
    )
    retired_paths = @([pscustomobject]@{ path = "workspace.uai"; expected_before = [pscustomobject]@{ status = "absent" } })
}
Assert-ManifestRemoteBeforeState -Manifest $miniManifest -Nonce "release"
Pass -Name "complete active and retired rollback proof"

$script:remoteFixture["workspace.uai"] = [pscustomobject]@{
    status = "present"; bytes = $newBytes.Length; sha256 = $newSha; content = $newBytes
}
Assert-Throws -Action {
    Assert-ManifestRemoteBeforeState -Manifest $miniManifest -Nonce "release"
} -Pattern "authenticated retirement" -Name "retired path rollback drift"

if ($script:passed -ne 31) { throw "Expected 31 custody checks; observed $script:passed." }
if ($createdStagingParent) {
    if (@(Get-ChildItem -LiteralPath $stagingParent -Force).Count -ne 0) {
        throw "Test-created deployment staging parent is not empty."
    }
    [IO.Directory]::Delete($stagingParent)
}
Write-Host "RESULT 31/31 deployment-custody checks passed"
