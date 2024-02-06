[CmdletBinding()]
param(
    [hashtable]$SampleSet,
    [string[]]$Configurations = @(if ([string]::IsNullOrEmpty($env:WDS_Configuration)) { "Debug" } else { $env:WDS_Configuration }),
    [string[]]$Platforms = @(if ([string]::IsNullOrEmpty($env:WDS_Platform)) { "x64" } else { $env:WDS_Platform }),
    $LogFilesDirectory = (Get-Location),
    [string]$ReportFileName = $(if ([string]::IsNullOrEmpty($env:WDS_ReportFileName)) { "_overview" } else { $env:WDS_ReportFileName }),
    [int]$ThrottleLimit = 0
)

$root = Get-Location
$ThrottleFactor = 5
$LogicalProcessors = (Get-CIMInstance -Class 'CIM_Processor' -Verbose:$false).NumberOfLogicalProcessors

if ($ThrottleLimit -eq 0) {
    $ThrottleLimit = $ThrottleFactor * $LogicalProcessors
}

$Verbose = $false
if ($PSBoundParameters.ContainsKey('Verbose')) {
    $Verbose = $PsBoundParameters.Get_Item('Verbose')
}

New-Item -ItemType Directory -Force -Path $LogFilesDirectory | Out-Null
$reportFilePath = Join-Path $LogFilesDirectory "$ReportFileName.htm"
$reportCsvFilePath = Join-Path $LogFilesDirectory "$ReportFileName.csv"


Remove-Item  -Recurse -Path $LogFilesDirectory 2>&1 | Out-Null
New-Item -ItemType Directory -Force -Path $LogFilesDirectory | Out-Null

$oldPreference = $ErrorActionPreference
$ErrorActionPreference = "stop"
try {
    # Check that msbuild can be called before trying anything.
    Get-Command "msbuild" | Out-Null
}
catch {
    Write-Host "`u{274C} msbuild cannot be called from current environment. Check that msbuild is set in current path (for example, that it is called from a Visual Studio developer command)."
    Write-Error "msbuild cannot be called from current environment."
    exit 1
}
finally {
    $ErrorActionPreference = $oldPreference
}

#
# Determine build environment: 'GitHub', 'NuGet', 'EWDK', or 'WDK'.  Only used to determine build number.
# Determine build number (used for exclusions based on build number).  Five digits.  Say, '22621'.
#
$build_environment=""
$build_number=0
#
# WDK NuGet will require presence of a folder 'packages'
#
#
# Hack: In GitHub we do not have an environment variable where we can see WDK build number, so we have it hard coded.
#
if (-not $env:GITHUB_REPOSITORY -eq '') {
    $build_environment="GitHub"
    $build_number=22621
}
#
# Hack: If user has hydrated nuget packages, then use those. That will be indicated by presence of a folder named .\packages.
#
elseif(Test-Path(".\packages")) {
    $build_environment=("NuGet")
    $build_number=26052
}
#
# EWDK sets environment variable BuildLab.  For example 'ni_release_svc_prod1.22621.2428'.
#
elseif($env:BuildLab -match '(?<branch>[^.]*).(?<build>[^.]*).(?<qfe>[^.]*)') {
    $build_environment=("EWDK."+$Matches.branch+"."+$Matches.build+"."+$Matches.qfe)
    $build_number=$Matches.build
}
#
# WDK sets environment variable UCRTVersion.  For example '10.0.22621.0'.
#
elseif ($env:UCRTVersion -match '10.0.(?<build>.*).0') {
    $build_environment="WDK"
    $build_number=$Matches.build
}
else {

    # Dump all environment variables so as to help debug error:
    Write-Output "Environment variables {"
    gci env:* | sort-object name
    Write-Output "Environment variables }"

    Write-Error "Could not determine build environment."
    exit 1
}

#
# InfVerif_AdditionalOptions
#
# Samples must build cleanly and even without warnings.
#
# An exception is for infverif where specific warnings are acceptable.  Those
# specific warnings indicates issues intentially present in the samples, that
# anyone that clones the samples must fix as part of productizing a driver.
# 
# In 22621 those warnings are: /sw1284 /sw1285 /sw1293 /sw2083 /sw2086
# 
# After 22621 those warnings are put under a common flag: /samples
#
# Additionally after 22621 we have to temporarily suppress /sw1402 due to one specific sample "biometrics".
#
$InfVerif_AdditionalOptions=($build_number -le 22621 ? "/sw1284 /sw1285 /sw1293 /sw2083 /sw2086" : "/samples /sw1402")

#
# Determine exclusions.  
#
# Exclusions are loaded from .\exclusions.csv.
# Each line has form:
#   Path,Configurations,MinBuild,MaxBuild,Reason
# Where:
#   Path: Is the path to folder containing solution(s) using backslashes. For example: 'audio\acx\samples\audiocodec\driver' .
#   Configurations: Are the configurations to exclude.  For example: '*|arm64' .
#   MinBuild: Is the minimum WDK/EWDK build number the exclusion is applicable for.  For example: '22621' .
#   MaxBuild: Is the maximum WDK/EWDK build number the exclusion is applicable for.  For example: '26031' .
#   Reason: Is plain text documenting the reason for the exclusion. For example: 'error C1083: Cannot open include file: 'acx.h': No such file or directory' .
#
$exclusionConfigurations = @{}
$exclusionReasons = @{}
Import-Csv 'exclusions.csv' | ForEach-Object {
    $excluded_driver=$_.Path.Replace($root, '').Trim('\').Replace('\', '.').ToLower()
    $excluded_configurations=($_.configurations -eq '' ? '*' : $_.configurations)
    $excluded_minbuild=($_.MinBuild -eq '' ? 00000 : $_.MinBuild)
    $excluded_maxbuild=($_.MaxBuild -eq '' ? 99999 : $_.MaxBuild)
    if (($excluded_minbuild -le $build_number) -and ($build_number -le $excluded_maxbuild) )
    {
        $exclusionConfigurations[$excluded_driver] = $excluded_configurations
        $exclusionReasons[$excluded_driver] = $_.Reason
        Write-Verbose "Exclusion.csv entry applied for '$excluded_driver' for configuration '$excluded_configurations'."
    }
    else
    {
        Write-Verbose "Exclusion.csv entry not applied for '$excluded_driver' due to build number."
    }
}

$jresult = @{
    SolutionsBuilt       = 0
    SolutionsSucceeded   = 0
    SolutionsExcluded    = 0
    SolutionsUnsupported = 0
    SolutionsFailed      = 0
    Results              = @()
    FailSet              = @()
    lock                 = [System.Threading.Mutex]::new($false)
}

$SolutionsTotal = $sampleSet.Count * $Configurations.Count * $Platforms.Count

Write-Output ("Build Environment:          " + $build_environment)
Write-Output ("Build Number:               " + $build_number)
Write-Output ("Samples:                    " + $sampleSet.Count)
Write-Output ("Configurations:             " + $Configurations.Count + " (" + $Configurations + ")")
Write-Output ("Platforms:                  " + $Platforms.Count + " (" + $Platforms + ")")
Write-Output "InfVerif_AdditionalOptions: $InfVerif_AdditionalOptions"
Write-Output "Combinations:               $SolutionsTotal"
Write-Output "LogicalProcessors:          $LogicalProcessors"
Write-Output "ThrottleFactor:             $ThrottleFactor"
Write-Output "ThrottleLimit:              $ThrottleLimit"
Write-Output "WDS_WipeOutputs:            $env:WDS_WipeOutputs"
Write-Output ("Disk Remaining (GB):        " + (((Get-Volume ($DriveLetter = (Get-Item ".").PSDrive.Name)).SizeRemaining / 1GB)))
Write-Output ""
Write-Output "T: Combinations"
Write-Output "B: Built"
Write-Output "R: Build is running currently"
Write-Output "P: Build is pending an available build slot"
Write-Output ""
Write-Output "S: Built and result was 'Succeeded'"
Write-Output "E: Built and result was 'Excluded'"
Write-Output "U: Built and result was 'Unsupported' (Platform and Configuration combination)"
Write-Output "F: Built and result was 'Failed'"
Write-Output ""
Write-Output "Building all combinations..."

$Results = @()

$sw = [Diagnostics.Stopwatch]::StartNew()

$SampleSet.GetEnumerator() | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
    $LogFilesDirectory = $using:LogFilesDirectory
    $exclusionConfigurations = $using:exclusionConfigurations
    $exclusionReasons = $using:exclusionReasons
    $Configurations = $using:Configurations
    $Platforms = $using:Platforms
    $InfVerif_AdditionalOptions = $using:InfVerif_AdditionalOptions
    $Verbose = $using:Verbose

    $sampleName = $_.Key
    $directory = $_.Value

    $ResultElement = new-object psobject
    Add-Member -InputObject $ResultElement -MemberType NoteProperty -Name Sample -Value "$sampleName"

    foreach ($configuration in $Configurations) {
        foreach ($platform in $Platforms) {
            $thisunsupported = 0
            $thisfailed = 0
            $thisexcluded = 0
            $thissucceeded = 0
            $thisresult = "Not run"
            $thisfailset = @()

            if ($exclusionConfigurations.ContainsKey($sampleName) -and ($exclusionConfigurations[$sampleName].Split(';') | Where-Object { "$configuration|$platform" -like $_ })) {
                # Verbose
                Write-Verbose "[$sampleName $configuration|$platform] `u{23E9} Excluded and skipped. Reason: $($exclusionReasons[$sampleName])"
                $thisexcluded += 1
                $thisresult = "Excluded"
            }
            else {
                .\Build-Sample -Directory $directory -SampleName $sampleName -LogFilesDirectory $LogFilesDirectory -Configuration $configuration -Platform $platform -InfVerif_AdditionalOptions $InfVerif_AdditionalOptions -Verbose:$Verbose
                if ($LASTEXITCODE -eq 0) {
                    $thissucceeded += 1
                    $thisresult = "Succeeded"
                }
                elseif ($LASTEXITCODE -eq 1) {
                    $thisfailset += "$sampleName $configuration|$platform"
                    $thisfailed += 1
                    $thisresult = "Failed"
                }
                else {
                    # ($LASTEXITCODE -eq 2)
                    $thisunsupported += 1
                    $thisresult = "Unsupported"
                }
            }
            Add-Member -InputObject $ResultElement -MemberType NoteProperty -Name "$configuration|$platform" -Value "$thisresult"

            $null = ($using:jresult).lock.WaitOne()
            try {
                ($using:jresult).SolutionsBuilt += 1
                ($using:jresult).SolutionsSucceeded += $thissucceeded
                ($using:jresult).SolutionsExcluded += $thisexcluded
                ($using:jresult).SolutionsUnsupported += $thisunsupported
                ($using:jresult).SolutionsFailed += $thisfailed
                ($using:jresult).FailSet += $thisfailset
                $SolutionsTotal = $using:SolutionsTotal
                $ThrottleLimit = $using:ThrottleLimit
                $SolutionsBuilt = ($using:jresult).SolutionsBuilt
                $SolutionsRemaining = $SolutionsTotal - $SolutionsBuilt
                $SolutionsRunning = if ($SolutionsRemaining -ge $ThrottleLimit) { $ThrottleLimit } else { $SolutionsRemaining }
                $SolutionsPending = if ($SolutionsRemaining -ge $ThrottleLimit) { ($SolutionsRemaining - $ThrottleLimit) } else { 0 }
                $SolutionsBuiltPercent = [Math]::Round(100 * ($SolutionsBuilt / $using:SolutionsTotal))
                $TBRP = "T:" + ($SolutionsTotal) + "; B:" + (($using:jresult).SolutionsBuilt) + "; R:" + ($SolutionsRunning) + "; P:" + ($SolutionsPending)
                $rstr = "S:" + (($using:jresult).SolutionsSucceeded) + "; E:" + (($using:jresult).SolutionsExcluded) + "; U:" + (($using:jresult).SolutionsUnsupported) + "; F:" + (($using:jresult).SolutionsFailed)
                Write-Progress -Activity "Building combinations" -Status "$SolutionsBuilt of $using:SolutionsTotal combinations built ($SolutionsBuiltPercent%) | $TBRP | $rstr" -PercentComplete $SolutionsBuiltPercent
            }
            finally {
                ($using:jresult).lock.ReleaseMutex()
            }
        }
    }
    $null = ($using:jresult).lock.WaitOne()
    try {
        ($using:jresult).Results += $ResultElement
    }
    finally {
        ($using:jresult).lock.ReleaseMutex()
    }
}

$sw.Stop()

if ($jresult.FailSet.Count -gt 0) {
    Write-Output "Some combinations were built with errors:"
    $jresult.FailSet = $jresult.FailSet | Sort-Object
    foreach ($failedSample in $jresult.FailSet) {
        $failedSample -match "^(.*) (\w*)\|(\w*)$" | Out-Null
        $failName = $Matches[1]
        $failConfiguration = $Matches[2]
        $failPlatform = $Matches[3]
        Write-Output "Build errors in Sample $failName; Configuration: $failConfiguration; Platform: $failPlatform {"
        Get-Content "$LogFilesDirectory\$failName.$failConfiguration.$failPlatform.err" | Write-Output
        Write-Output "} $failedSample"
    }
    Write-Error "Some combinations were built with errors."
}

# Display timer statistics to host
$min = $sw.Elapsed.Minutes
$seconds = $sw.Elapsed.Seconds

$SolutionsSucceeded = $jresult.SolutionsSucceeded
$SolutionsExcluded = $jresult.SolutionsExcluded
$SolutionsUnsupported = $jresult.SolutionsUnsupported
$SolutionsFailed = $jresult.SolutionsFailed
$Results = $jresult.Results

Write-Output ""
Write-Output "Built all combinations."
Write-Output ""
Write-Output "Elapsed time:         $min minutes, $seconds seconds."
Write-Output ("Disk Remaining (GB):  " + (((Get-Volume ($DriveLetter = (Get-Item ".").PSDrive.Name)).SizeRemaining / 1GB)))
Write-Output ("Samples:              " + $sampleSet.Count)
Write-Output ("Configurations:       " + $Configurations.Count + " (" + $Configurations + ")")
Write-Output ("Platforms:            " + $Platforms.Count + " (" + $Platforms + ")")
Write-Output "Combinations:         $SolutionsTotal"
Write-Output "Succeeded:            $SolutionsSucceeded"
Write-Output "Excluded:             $SolutionsExcluded"
Write-Output "Unsupported:          $SolutionsUnsupported"
Write-Output "Failed:               $SolutionsFailed"
Write-Output "Log files directory:  $LogFilesDirectory"
Write-Output "Overview report:      $reportFilePath"
Write-Output ""

$Results | Sort-Object { $_.Sample } | ConvertTo-Csv | Out-File $reportCsvFilePath
$Results | Sort-Object { $_.Sample } | ConvertTo-Html -Title "Overview" | Out-File $reportFilePath
Invoke-Item $reportFilePath
