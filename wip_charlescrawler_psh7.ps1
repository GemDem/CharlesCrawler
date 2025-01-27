param(
    [parameter(Mandatory=$true, Position=0)]
    [String]$Target,
    [parameter(Mandatory=$false)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$mph = 10,
    [parameter(Mandatory=$false)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$mps = 3,
    [parameter(Mandatory=$false)]
    [ValidateSet("file", "dir")]
    [string]$m = "dir",
    [parameter(Mandatory=$false)]
    [switch]$q,
    [parameter(Mandatory=$false)]
    [string]$d,
    [parameter(Mandatory=$false)]
    [ValidateRange(0, [int]::MaxValue)]
    [int]$A = 0,
    [parameter(Mandatory=$false)]
    [ValidateRange(0, [int]::MaxValue)]
    [int]$B = 0,
    [parameter(Mandatory=$false)]
    [ValidateRange(0, [int]::MaxValue)]
    [int]$mt = 0,
    [parameter(ValueFromRemainingArguments=$true)]
    [string[]]$OtherArgs
)

$banner = @"
   ____ _                _              ____                    _               
  / ___| |__   __ _ _ __| | ___  ___   / ___|_ __ __ ___      _| | ___ _ __   _ 
 | |   | '_ \ / _\` | '__| |/ _ \/ __| | |   | '__/ _\` \ \ /\ / / |/ _ \ '__| (_)
 | |___| | | | (_| | |  | |  __/\__ \ | |___| | | (_| |\ V  V /| |  __/ |     _ 
  \____|_| |_|\__,_|_|  |_|\___||___/  \____|_|  \__,_| \_/\_/ |_|\___|_|    (_)
  ____  _                        _         ____                    _            
 / ___|| |__   __ _ _ __ ___    | | ___   / ___|_ __ __ ___      _| | ___ _ __  
 \___ \| '_ \ / _\` | '__/ _ \   | |/ _ \ | |   | '__/ _\` \ \ /\ / / |/ _ \ '__| 
  ___) | | | | (_| | | |  __/_  | |  __/ | |___| | | (_| |\ V  V /| |  __/ |    
 |____/|_| |_|\__,_|_|  \___( ) |_|\___|  \____|_|  \__,_| \_/\_/ |_|\___|_|    
                            |/                                                  
"@

Write-Host $banner

# Check if help is requested
if ($OtherArgs -contains "-h" -or $args -contains "--help") {
    @"
Usage: .\charlescrawler.ps1 <target_String> [-mph <Int32>] [-mps <Int32>] [-m <String>] [-d <String>] [-A <Int32>] [-B <Int32>] [-mt <Int32>]

Parameters:
<target_String>                 Required. IP address or FQDN or Path to file containing target servers or single target server name
-mph  Optional. Maximum Parallel Hosts to scan at a time (Default: 10)
-mps  Optional. Maximum Parallel Shares to scan per host (Default: 3)
-m    Optional. Search mode: 'file' or 'dir'. File mode will search matches inside the files. Dir mode will search for file names. (Default: dir)
-d    Optional. Specify the domain (e.g., domain.local) to include in search words.
-q    Optional. Quick mode will be less exhaustive (eg. less file types, less words in files, less file names). (Default: false)
-A    Optional. Number of lines to display after each match (Default: 0)
-B    Optional. Number of lines to display before each match (Default: 0)
-mt   Optional. Maximum time in seconds to spend scanning each share. 0 means unlimited (Default: 0)

Examples:
.\test2.ps1 targets.txt
.\test2.ps1 server01.com -mph 8 -mps 5 -d domain.local
.\test2.ps1 10.0.0.1 -mph 10 -mps 3 -m file -d domain.local -A 2 -B 2 -mt 300
"@ | Write-Host
    exit
}


# Initialize hashtable to store server shares
$serverShares = @{}

$quick = $q

if ($quick) {
    Write-Host "[*] Quick mode enabled" -ForegroundColor Blue
}

# todo : add xlsx/pptx support
# todo : everything is saved in hashtable = big memory usage ?
# todo : the save in file during the scan is not up to date

# todo : skip admin if c : to be tested in real world
# todo : trunk long extraced lines : to be tested in real world
# todo : save in file during scan : todo find a better way to do it

# Initialize search filters

$ext = @(
    "*.bat", "*.ps1", "*.sh", "*.txt", "*.conf", "*.init", "*.json", "*.docx", "*.msg"
    if (-not $quick) {
        "*.cnf", "*.config", "*.xml", "*.yaml", "*.inf", "*.url", "*.ini", "*.yml", "*.cfg", "*.one", "*.docx", "*.msg"
    }
)

$words = if ($quick) {
    @('password', 'secret', 'mdp', 'pass', 'credential', 'mot de passe') | ForEach-Object {
        "$_ :", "$_\:", "$_ =", "$_=" 
    }
} else {
    "pass", "credential", "mot de passe", "mdp" #todo replace domain.local with domain
}

if ($d) {
    $words += "@$d", ("$($d.Split('.')[0].ToUpper())\\")
    Write-Host "[*] Domain added to searched strings :"@$d ","("$($d.Split('.')[0].ToUpper())\\") -ForegroundColor Blue
}


$name = @(
    "*password*", "*mot de passe*", "*.kdbx"
    if (-not $quick) {
        "*mdp*", "*code*", "*secret*", "*cred*", "*key*", "*vault*"
    }
)

# Get targets list
$targets = if (Test-Path $Target) {
    $targetsList = Get-Content $Target
    Write-Host "[*] Reading targets from file: $Target ($(($targetsList).Count) targets listed)" -ForegroundColor Blue
    $targetsList
} else {
    Write-Host "[*] Single target provided: $Target" -ForegroundColor Blue
    @($Target)
}

# Create synced hashtable for results
$shareEnumerationResults = [System.Collections.Hashtable]::Synchronized(@{})
$targets | ForEach-Object { $shareEnumerationResults[$_] = @{} }

# Start parallel jobs
$shareEnumerationJobs = $targets | ForEach-Object -ThrottleLimit $mph -AsJob -Parallel {
    $Server = $_
    $syncCopy = $using:shareEnumerationResults
    $process = $syncCopy[$Server] = @{
        Server = $Server
        Status = "Checking connectivity"
        Complete = $false 
        Output = @()
        Shares = @()
        Reachable = $false
    }

    # Check if target is reachable
    if (-not (Test-Connection -ComputerName $Server -Count 1 -Quiet -TimeoutSeconds 2)) {
        $process.Output += "[-] [$Server] Target not reachable"
        $process.Status = "Not reachable"
        $process.Complete = $true
        return
    }

    # Check if SMB port is open
    $tcpClient = New-Object System.Net.Sockets.TcpClient
    $connectionResult = $tcpClient.BeginConnect($Server, 445, $null, $null)
    $waitResult = $connectionResult.AsyncWaitHandle.WaitOne(2000) # 2 seconds timeout
    
    if (-not $waitResult) {
        $process.Output += "[-] [$Server] SMB port not accessible (timeout)"
        $process.Status = "SMB not accessible" 
        $process.Complete = $true
        $tcpClient.Close()
        return
    }
    
    try {
        $tcpClient.EndConnect($connectionResult)
    } catch {
        $process.Output += "[-] [$Server] SMB port not accessible"
        $process.Status = "SMB not accessible"
        $process.Complete = $true
        return
    } finally {
        $tcpClient.Close()
    }
    
    $process.Status = "Enumerating shares"
    $process.Output += "[+] [$Server] Target is reachable, Enumerating shares..."
    $process.Reachable = $true
    
    try {
        # Try to list SMB shares
        $net_view_result = (net.exe view \\$Server /all) -split '\n'

        $shares = $net_view_result[7..($net_view_result.Count-3)] | ForEach-Object { 
            $_.split([string[]]@("  "), [StringSplitOptions]::RemoveEmptyEntries)[0]
        }

        if ($shares) {
            $process.Output += "[+] [$Server] Found $($shares.Count) shares:"
            $process.Output += $shares | ForEach-Object { "[+] [$Server] $_" }
            $process.Shares = $shares
        } else {
            $process.Output += "[-] [$Server] No shares found"
        }
    }
    catch {
        $process.Output += "[-] [$Server] Error accessing SMB shares: $($_.Exception.Message)"
        $process.Status = "Error"
    }
    finally {
        $process.Status = "Complete"
        $process.Complete = $true
    }
}

[Console]::TreatControlCAsInput = $true
$Host.UI.RawUI.FlushInputBuffer()

# Monitor progress
$totalCount = $targets.Count
while ($shareEnumerationJobs.State -eq 'Running') {
    # Get completed count more efficiently using measure
    $completedCount = ($shareEnumerationResults.Values | Where-Object {$_.Complete -eq $true} | Measure-Object).Count
    
    # Process outputs in batches
    $shareEnumerationResults.GetEnumerator() | Where-Object {$_.Value.Output} | ForEach-Object {
        $server = $_.Key
        $outputs = $_.Value.Output
        
        if ($outputs) {
            # Process all outputs at once using switch for pattern matching
            $outputs | ForEach-Object {
                switch -Regex ($_) {
                    '^\[\+\]' { Write-Host $_ -ForegroundColor Green; break }
                    '^\[-\]' { Write-Host $_ -ForegroundColor Red; break }
                    default { Write-Host $_ -ForegroundColor Blue }
                }
            }
            $shareEnumerationResults[$server].Output = @()
        }
    }
    
    $percentage = [Math]::Min(($completedCount / $totalCount) * 100 + 1, 100)
    $seconds = ($totalCount - $completedCount) / $mph
    Write-Progress -Activity "Listing shares" -Status "$completedCount out of $totalCount done" -PercentComplete $percentage -SecondsRemaining $seconds -Id 0

    # Check for CTRL-C
    if ($Host.UI.RawUI.KeyAvailable -and ($Key = $Host.UI.RawUI.ReadKey("AllowCtrlC,NoEcho,IncludeKeyUp"))) {
        if ([int]$Key.Character -eq 3) {
            Write-Host "[-] [System] CTRL-C - Shutting down jobs." -ForegroundColor Red
            Stop-Job -Job $shareEnumerationJobs
            Remove-Job -Job $shareEnumerationJobs -Force
            [Console]::TreatControlCAsInput = $false
            exit
        }
        $Host.UI.RawUI.FlushInputBuffer()
    }
    Start-Sleep -Seconds 0.1
}

# Store results in serverShares and process remaining outputs
$shareEnumerationResults.GetEnumerator() | ForEach-Object {
    $serverShares[$_.Key] = $_.Value.Shares

    # Process any remaining outputs using switch for pattern matching
    if ($_.Value.Output) {
        $_.Value.Output | ForEach-Object {
            switch -Regex ($_) {
                '^\[\+\]' { Write-Host $_ -ForegroundColor Green; break }
                '^\[-\]' { Write-Host $_ -ForegroundColor Red; break }
                default { Write-Host $_ -ForegroundColor Blue }
            }
        }
        $_.Value.Output = @()
    }
}

Write-Progress -Activity "Listing shares" -Completed -Id 0

Write-Host "[*] All scans completed" -ForegroundColor Blue

# Clean up jobs (not sure if this is needed)
$shareEnumerationJobs | Remove-Job -Force -ErrorAction SilentlyContinue


# Create synced hashtable for share contents
$shareContents = @{}
$serverShares.Keys | ForEach-Object {
    $shareContents[$_] = @{
        "isReachable" = [bool]$serverShares[$_]
        "Output" = @()
    }
}

$synchronizedShareContents = [System.Collections.Hashtable]::Synchronized($shareContents)

# Create progress tracking hashtable
$progressOrigin = @{}
$serverShares.Keys | ForEach-Object -Begin { $id = 1 } -Process { 
    $progressOrigin[$_] = @{
        Id = $id++
        SharesCompleted = 0
        TotalShares = $serverShares[$_].Count
        Status = "Pending"
    }
}

$syncProgress = [System.Collections.Hashtable]::Synchronized($progressOrigin)

Write-Host "[*] Scanning shares for credentials..." -ForegroundColor Blue

# Process servers in parallel
$shareEnumerationServerJobs = $serverShares.Keys | ForEach-Object -ThrottleLimit $mph -AsJob -Parallel {
    $server = $_
    $syncCopy = $using:synchronizedShareContents
    $serverContents = $syncCopy[$server]
    $shares = ($using:serverShares)[$server]
    $maxParallelShares = $using:mps
    $progressCopy = ($using:syncProgress)[$server]
    $mode, $ext, $words, $name, $A, $B, $mt = $using:m, $using:ext, $using:words, $using:name, $using:A, $using:B, $using:mt
    
    $progressCopy.Status = "Processing"

    # Process shares for this server in parallel
    $shares | ForEach-Object -ThrottleLimit $maxParallelShares -TimeoutSeconds $mt -Parallel {
        $share = $_
        $serverContentsCopy = $using:serverContents
        $serverName = $using:server
        $progress = $using:progressCopy
        $path = "\\$serverName\$share"

        # Skip Admin$ share if C$ exists in shares list, to be tested in real world
        if ($share -eq "Admin$" -and ($using:shares -contains "C$")) {
            $serverContentsCopy[$share] = @{
                status = "Skipped since C$ exists"
            }
            $serverContentsCopy.Output += "[*] [$serverName] Skipping Admin$ share since C$ exists"
            $progress.SharesCompleted++
            return
        }

        $fileMatcherScriptBlock = {
            $matchedLine = $_.Line

            # Decode quoted-printable if file is .msg
            if ($_.Path -like "*.msg") {
                $matchedLine = $matchedLine -replace '=\r?\n', ''
                $matchedLine = [regex]::Replace($matchedLine, '=([0-9A-F]{2})', {
                    param($match)
                    [char][convert]::ToInt32($match.Groups[1].Value, 16)
                })
            }

            foreach($word in $using:words) {
                $matchedLine = $matchedLine -replace "($word)", "¤`$1¤"
            }
            
            # Truncate long lines with multiple matches
            $truncatedLine = ""
            $lineMatches = [regex]::Matches($matchedLine, '¤.*?¤')
            $lastEnd = 0
            for($i = 0; $i -lt $lineMatches.Count; $i++) {
                $match = $lineMatches[$i]
                $start = $match.Index
                
                if($start - $lastEnd -ge 0) {
                    if($start - $lastEnd -le 50) {
                        $truncatedLine += $matchedLine.Substring($lastEnd, $start - $lastEnd)
                    } else {
                        $truncatedLine += $matchedLine.Substring($lastEnd, 50)
                        $truncatedLine += " [...] "
                    }
                }
                
                $truncatedLine += $matchedLine.Substring($start, $match.Length)
                $lastEnd = $start + $match.Length
            }
            if($matchedLine.Length - $lastEnd -le 50) {
                $truncatedLine += $matchedLine.Substring($lastEnd)
            }

            # Add Before lines if they exist
            if ($_.Context.PreContext) {
                $path = $_.Path
                $lineNumber = $_.LineNumber
                $serverContentsCopy.Output += $_.Context.PreContext | ForEach-Object {
                    "[+] [$serverName][$share] ${path}:${lineNumber}:$_"
                }
            }
            if ($processedFile) {
                $serverContentsCopy.Output += "[+] [$serverName][$share] $($processedFile):$($_.LineNumber):$truncatedLine"
            }
            else {
                $serverContentsCopy.Output += "[+] [$serverName][$share] $($_.Path):$($_.LineNumber):$truncatedLine"
            }

            # Add After lines if they exist
            if ($_.Context.PostContext) {
                $path = $_.Path
                $lineNumber = $_.LineNumber
                $serverContentsCopy.Output += $_.Context.PostContext | ForEach-Object {
                    "[+] [$serverName][$share] ${path}:${lineNumber}:$_"
                }
            }

            if (!$fileMatches.ContainsKey($_.Path)) {
                $fileMatches[$_.Path] = @{
                    matches = @()
                }
            }
            $fileMatches[$_.Path].matches += @{
                Line = $_.Line
                LineNumber = $_.LineNumber 
                PreContext = $_.Context.PreContext
                PostContext = $_.Context.PostContext
                id = $id++
            }
        }

        try {
            if($using:mode -eq "file") {
                # Get matching files and process in one pipeline
                $fileMatches = @{}
                Get-ChildItem $path -Recurse -Include $using:ext -ErrorAction SilentlyContinue | ForEach-Object {
                    if ($_.Extension -eq ".docx") {
                        $processedFile  = $_
                        try {
                            $zipFile = [System.IO.Compression.ZipFile]::OpenRead($_)
                            $xmlDoc = $null
                            foreach ($entry in $zipFile.Entries) {
                                if ($entry.FullName -eq "word/document.xml") {
                                    $stream = $entry.Open()
                                    $reader = New-Object System.IO.StreamReader($stream)
                                    $xmlDoc = $reader.ReadToEnd()
                                    $reader.Close()
                                }
                            }
                            $zipFile.Dispose()
                            $xml = [xml]$xmlDoc
                            $xml.document.body.InnerText | Select-String $using:words -Context $using:B,$using:A |
                            ForEach-Object -Begin { $id = 1 } -Process $fileMatcherScriptBlock
                            $processedFile = $null
                        }
                        catch {
                            $serverContentsCopy.Output += "[-] [$serverName][$share] Error processing docx file $($processedFile.FullName)" 
                        }
                        return
                    }
                    else {  
                        $_ | Select-String $using:words -Context $using:B,$using:A |
                        ForEach-Object -Begin { $id = 1 } -Process $fileMatcherScriptBlock
                    }
                    
                } 

                $serverContentsCopy[$share] = @{
                    status = "Success"
                    files = $fileMatches
                }
            }
            else {
                # Get files matching name pattern
                $fileMatches = @{}
                Get-ChildItem $path -Recurse -Include $using:name -ErrorAction SilentlyContinue |
                    Select-Object FullName, Name, Length, LastWriteTime | 
                    ForEach-Object -Begin { $id = 1 } -Process {
                        $serverContentsCopy.Output += "[+] [$serverName][$share] $($_.Name) - Size: $($_.Length) - LastWrite: $($_.LastWriteTime)"
                        
                        $fileMatches[$_.FullName] = @{
                            Name = $_.Name
                            Length = $_.Length
                            LastWriteTime = $_.LastWriteTime
                            id = $id++
                        }
                    }
                
                $serverContentsCopy[$share] = @{
                    status = "Success"
                    files = $fileMatches
                }
            }
        }
        catch {
            $serverContentsCopy[$share] = @{
                status = "Access Denied"
                error = $_.Exception.Message
            }
            $serverContentsCopy.Output += "[-] [$serverName][$share] Error: $($_.Exception.Message)"
        }
        finally {
            $progress.SharesCompleted++
        }
    }
    $progressCopy.Status = "Complete"
}

# Monitor progress while jobs are running
while ($shareEnumerationServerJobs.State -contains "Running") {
    foreach ($server in $syncProgress.Keys) {
        $progress = $syncProgress[$server]
        $serverShareInfo = $synchronizedShareContents[$server]

        # Process any new outputs
        if ($serverShareInfo.Output) {
            $serverShareInfo.Output | ForEach-Object {
                switch -Regex ($_) {
                    '^\[\+\]' {
                        if ($_ -match '¤.*¤') {
                            $parts = $_ -split '¤'
                            for ($i = 0; $i -lt $parts.Length; $i++) {
                                if ($i % 2 -eq 0) {
                                    # Even indices (including 0) are normal text
                                    Write-Host $parts[$i] -NoNewline -ForegroundColor Green
                                } else {
                                    # Odd indices are highlighted text
                                    Write-Host $parts[$i] -NoNewline -ForegroundColor Red
                                }
                            }
                            Write-Host "" # Add newline at the end
                        } else {
                            Write-Host $_ -ForegroundColor Green
                        }
                    }
                    '^\[-\]' { Write-Host $_ -ForegroundColor Red }
                    default { Write-Host $_ -ForegroundColor Blue }
                }
            }
            $serverShareInfo.Output = @()
        }

        # Update progress
        if ($progress.Status -eq "Complete") {
            Write-Progress -Activity "Processing $server" -Status "Complete" -Id $progress.Id -Completed
        }
        elseif ($progress.Status -eq "Processing") {
            if ($progress.TotalShares -eq 0) {
                Write-Progress -Activity "Processing $server" -Status "No shares found" -Id $progress.Id -Completed
            } else {
                Write-Progress -Activity "Processing $server" `
                             -Status "$($progress.SharesCompleted) out of $($progress.TotalShares) shares processed" `
                             -PercentComplete ([Math]::Min(100, ($progress.SharesCompleted / $progress.TotalShares) * 100 + 1)) `
                             -Id $progress.Id
            }
        }

        # Check for CTRL+C
        if ($Host.UI.RawUI.KeyAvailable -and ($Key = $Host.UI.RawUI.ReadKey("AllowCtrlC,NoEcho,IncludeKeyUp"))) {
            if ([int]$Key.Character -eq 3) {
                Write-Host "[-] [System] CTRL-C - Shutting down jobs." -ForegroundColor Red
                Stop-Job -Job $shareEnumerationServerJobs
                Remove-Job -Job $shareEnumerationServerJobs -Force
                [Console]::TreatControlCAsInput = $false
                exit
            }
            $Host.UI.RawUI.FlushInputBuffer()
        }
    }
    Start-Sleep -Seconds 0.1
    # Backup progress to JSON every minute : todo find a better way to do it
    $currentTime = Get-Date
    if (-not (Get-Variable -Name LastJsonSave -ErrorAction SilentlyContinue) -or 
        ($currentTime - $LastJsonSave).TotalMinutes -ge 1) {
        
        Write-Host "[*] Saving progress to JSON..." -ForegroundColor Blue
        $synchronizedShareContents | ConvertTo-Json -Depth 100 | 
            Out-File -FilePath "output_backup_$($currentTime.ToString("yyyy_MM_dd_HH_mm")).json"
        
        $LastJsonSave = $currentTime
    }
}

# Clean up jobs
$shareEnumerationServerJobs | Remove-Job -Force -ErrorAction SilentlyContinue

# Process any remaining outputs using switch for pattern matching
$synchronizedShareContents.Values | Where-Object { $_.Output } | ForEach-Object {
    $_.Output | ForEach-Object {
        switch -Regex ($_) {
            '^\[\+\]' {
                if ($_ -match '¤.*¤') {
                    $parts = $_ -split '¤'
                    for ($i = 0; $i -lt $parts.Length; $i++) {
                        if ($i % 2 -eq 0) {
                            # Even indices (including 0) are normal text
                            Write-Host $parts[$i] -NoNewline -ForegroundColor Green
                        } else {
                            # Odd indices are highlighted text
                            Write-Host $parts[$i] -NoNewline -ForegroundColor Red
                        }
                    }
                    Write-Host "" # Add newline at the end
                } else {
                    Write-Host $_ -ForegroundColor Green
                }
            }
            '^\[-\]' { Write-Host $_ -ForegroundColor Red }
            default { Write-Host $_ -ForegroundColor Blue }
        }
    }
    $_.Output = @()
}

Write-Host "`n[*] Scan complete" -ForegroundColor Green

Write-Host "`n[*] Generating JSON output..." -ForegroundColor Green

$synchronizedShareContents | ConvertTo-Json -Depth 100 | Out-File -FilePath "output.json"	

Write-Host "`n[*] Done" -ForegroundColor Green


