Param(
	[parameter(Mandatory=$false)]
	[ValidateSet("less","more")]
	[String[]]$c,
	[parameter(Mandatory=$false)]
	[ValidateSet("dir","file")]
	[String[]]$m,
	[parameter(Mandatory=$false)]
	[ValidateRange(1, [int]::MaxValue)]
	[int] $t,
	[parameter(Mandatory=$false)]
	[switch]$h
   )
   
write-host "   ____ _                _              ____                    _               "
write-host "  / ___| |__   __ _ _ __| | ___  ___   / ___|_ __ __ ___      _| | ___ _ __   _ "
write-host " | |   | '_ \ / _\` | '__| |/ _ \/ __| | |   | '__/ _\` \ \ /\ / / |/ _ \ '__| (_)"
write-host " | |___| | | | (_| | |  | |  __/\__ \ | |___| | | (_| |\ V  V /| |  __/ |     _ "
write-host "  \____|_| |_|\__,_|_|  |_|\___||___/  \____|_|  \__,_| \_/\_/ |_|\___|_|    (_)"
write-host "  ____  _                        _         ____                    _            "
write-host " / ___|| |__   __ _ _ __ ___    | | ___   / ___|_ __ __ ___      _| | ___ _ __  "
write-host " \___ \| '_ \ / _\` | '__/ _ \   | |/ _ \ | |   | '__/ _\` \ \ /\ / / |/ _ \ '__| "
write-host "  ___) | | | | (_| | | |  __/_  | |  __/ | |___| | | (_| |\ V  V /| |  __/ |    "
write-host " |____/|_| |_|\__,_|_|  \___( ) |_|\___|  \____|_|  \__,_| \_/\_/ |_|\___|_|    "
write-host "                            |/                                                  "

if ($h)
{
	write-host ""
	write-host "usage : ./charlescrawler.ps1 -c (less|more) -m (dir|file) -t <int>"
	write-host ""
	write-host "	-c : Completeness (less or more, default = less)."
	write-host "		less = search less things = less match and false positive, faster"
	write-host "		more = search more things = more match and false positive, longer"
	write-host ""
	write-host "	-m : mode (dir or file, default = dir)."
	write-host "		dir = search files wth name matching key words"
	write-host "		file = search key words in each files"
	write-host ""
	write-host "	-t : Number of threads (int, default = 50)."
	write-host ""
	write-host "Examples :"
	write-host "	./charlescrawler.ps1 : will run with fast speed, dir mode and 50 threads"
	write-host "	./charlescrawler.ps1 -t 32 : will run with fast speed, dir mode and 32 threads"
	write-host "	./charlescrawler.ps1 -c more -m file -t 100 : will run with more completeness, file mode and 100 threads"
	write-host ""
	Exit
}

if ($c -eq $null) {
	write-host "Running with default completeness : c = less."
	$c = "less"
}
else {
	write-host "Running with completeness set to :"$c
}

if ($m -eq $null) {
	write-host "Running with default search mode : m = dir."
	$m = "dir"
}
else {
	write-host "Running with search mode set to :"$m
}

if ($t -eq 0) {
	write-host "Running with default threads number : t = 50."
	$t = 50
}
else {
	write-host "Running with threads number set to :"$t
}

$MaxRunspaces = $t
$outputPath = (Get-Location).Path
$currDate = Get-Date -Format "dddd_MM-dd-yyyy_HH\hmm\mss"
New-Item -Path $outputPath -Name $currDate -ItemType "directory" | Out-Null
$outputPath = $outputPath+"\"+$currDate

$config = $outputPath, $c, $m

$Worker = {
    Param($Server, $config)
    
	$outputPath = $config[0]
	$completeness = $config[1]
	$mode = $config[2]
	
	$null > $outputPath"\"$Server".txt"
	
	$share_list = (net.exe view \\$Server /all) -split '\n'
	
	$ext = "*.bat", "*.ps1", "*.sh", "*.txt", "*.conf", "*.init", "*.json"
	$words = "password", "mot de passe"
	$name = "*password*", "*mot de passe*"

	if($completeness -eq "more")
	{
		$ext = "*.bat", "*.ps1", "*.sh", "*.txt", "*.cnf", "*.config", "*.xml", "*.yaml", "*.conf", "*.inf", "*.url", "*.init", "*.ini", "*.json", "*.yml", "*.cfg", "*.one"
		$words = "pass", "credential", "mot de passe", "DOMAIN\\", "@domain.local", "mdp"
		$name = "*password*", "*mdp*", "*mot de passe*", "*code*", "*secret*", "*cred*"
	}
	
	if ($share_list -Match $Server)
	{
		for ($i = 7; $i -lt $share_list.Count-2; $i++) { 
			$share = $($share_list[$i].split([string[]]@("  "), [System.StringSplitOptions]::RemoveEmptyEntries)[0])
			&{
				if($mode -eq "file")
				{
					Get-ChildItem "\\$($Server)\$($share)\" -recurse -include $ext | Select-String $words -List | Tee-Object -FilePath $outputPath"\"$Server".txt" -Append | Write-host
				}
				else
				{
					
					Get-ChildItem "\\$($Server)\$($share)\" -recurse -include $name | select -ExpandProperty FullName | Tee-Object -FilePath $outputPath"\"$Server".txt" -Append | Write-host
				}
			} 2> $null
		}
		
	}
	
	Move-Item -Path  $outputPath"\"$Server".txt" -Destination  $outputPath"\done_"$Server".txt"

}

$SessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$RunspacePool = [RunspaceFactory]::CreateRunspacePool(1, $MaxRunspaces, $SessionState, $Host)
$RunspacePool.Open()
$Jobs = New-Object System.Collections.ArrayList

Get-Content "server_list" | %{
    $PowerShell = [powershell]::Create()
	$PowerShell.RunspacePool = $RunspacePool
    $PowerShell.AddScript($Worker).AddArgument($_).AddArgument($config) | Out-Null    
    $JobObj = New-Object -TypeName PSObject -Property @{
		Runspace = $PowerShell.BeginInvoke()
		PowerShell = $PowerShell  
    }

    $Jobs.Add($JobObj) | Out-Null
}

[Console]::TreatControlCAsInput = $True
Start-Sleep -Seconds 1
$Host.UI.RawUI.FlushInputBuffer()

while ($Jobs.Runspace.IsCompleted -contains $false) {
	If ($Host.UI.RawUI.KeyAvailable -and ($Key = $Host.UI.RawUI.ReadKey("AllowCtrlC,NoEcho,IncludeKeyUp"))) {
		If ([Int]$Key.Character -eq 3) {
			Write-Host ""
			Write-Warning "CTRL-C - Shutting down jobs."
			$Jobs.Runspace | ForEach { $_.AsyncWaitHandle.Close() }
			$RunspacePool.Close()
			$RunspacePool.Dispose()
			[Console]::TreatControlCAsInput = $False
		}
		$Host.UI.RawUI.FlushInputBuffer()
	}
}
