<#
    Video Encoder Script
    Copyright (C) 2026 Anthony Mendez

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
#>
# --- Example Calls ---
# `.\videosToAv1WithMarkers.ps1`
# Calls with default arguments.
# `.\videosToAv1WithMarkers.ps1 -MaxEncodes`
# --- Configuration ---
# Accept command line arguments for the source folder and log file.
# If no arguments, default to the following values.
param (
    [string]$SourceFolder = "Z:\General\videoprojects\Recordings",
    [string]$LogFile = "C:\Users\Anthony\Videos\encoding_log.txt",
    [int]$MaxEncodes = -1
)

Import-Module "$PSScriptRoot\NvencUtils.psm1" -Force

$OutputExtension = ".mp4"
$TargetHeight = 1080
$Encoder = "av1_nvenc"
$CQ = 26
$Preset = "p7"
$DurationTolerance = 5
# If MaxEncodes is still -1, use Get-LocalGPUSessionsMinusOneOrTwo instead.
$EncoderSessionLimit = if ($MaxEncodes -eq -1) { Get-LocalGPUSessionsMinusOneOrTwo } else { $MaxEncodes }

# Supported extensions
$VideoExtensions = @(".mp4", ".mkv", ".avi", ".mov", ".flv", ".wmv", ".webm")

# --- Helper Function: Logging ---
function Write-Log {
    param ($Message, $Color = "White")
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogMsg = "[$TimeStamp] [Thread:$($([System.Threading.Thread]::CurrentThread.ManagedThreadId))] $Message"
            
    # Simple console output (thread-safe-ish by default)
    # Use a synchronized wrapper for file writing if possible, strictly speaking Add-Content is not fully atomic across processes/runspaces without locking, 
    # but for low volume it usually works. We'll add a simple retry.
    Write-Host $LogMsg -ForegroundColor $Color
    
    # Retry logic for file contention
    $MaxRetries = 5
    $RetryCount = 0
    while ($RetryCount -lt $MaxRetries) {
        try {
            Add-Content -Path $LogFile -Value $LogMsg -ErrorAction Stop
            break
        }
        catch {
            Start-Sleep -Milliseconds (Get-Random -Minimum 50 -Maximum 200)
            $RetryCount++
        }
    }
}

function Get-BestMatchingEDL {
    param ($VideoFile)
            
    $Dir = $VideoFile.DirectoryName
    $Base = $VideoFile.BaseName
            
    # 1. Try Exact Match First
    $ExactPath = Join-Path $Dir "$Base.edl"
    if (Test-Path $ExactPath) { return $ExactPath }
        
    # 2. Fuzzy Match: Find EDL with the Longest Common Prefix
    $AllEdls = Get-ChildItem -Path $Dir -Filter "*.edl"
            
    $BestMatch = $null
    $BestScore = 0
            
    foreach ($Edl in $AllEdls) {
        $EdlName = $Edl.BaseName
        $MatchCount = 0
        $MinLen = [math]::Min($Base.Length, $EdlName.Length)
                
        # Count identical characters from the start
        for ($i = 0; $i -lt $MinLen; $i++) {
            if ($Base[$i] -eq $EdlName[$i]) {
                $MatchCount++
            }
        }
                
        $PercentMatch = $MatchCount / $Base.Length
                
        if ($PercentMatch -gt 0.8 -and $MatchCount -gt $BestScore) {
            $BestScore = $MatchCount
            $BestMatch = $Edl.FullName
        }
    }
        
    return $BestMatch
}

function Convert-TimecodeToNs {
    param ($Timecode, $FrameRate)
    if ($Timecode -match "(?<h>\d{2}):(?<m>\d{2}):(?<s>\d{2})[:;](?<f>\d{2})") {
        $TotalSeconds = ([int]$Matches.h * 3600) + ([int]$Matches.m * 60) + [int]$Matches.s
        $Frames = [int]$Matches.f
        $RealSeconds = $TotalSeconds + ($Frames / $FrameRate)
        return [math]::Round($RealSeconds * 1000)
    }
    return 0
}

# --- Main Script ---
function Main {
    param (
        [string]$SourceFolder,
        [string]$LogFile,
        [int]$MaxEncodes
    )
    Write-Log "Encoder Session Limit: $EncoderSessionLimit" "Cyan"
    Write-Log "Starting Batch Processing (Fuzzy EDL Match)..." "Cyan"

    $Files = Get-ChildItem -Path $SourceFolder -Recurse | Where-Object { $VideoExtensions -contains $_.Extension.ToLower() }

    # Filter out OLD_ and TMP_ files before entering parallel block
    $FilesToProcess = $Files | Where-Object { $_.Name -notmatch "^(OLD_|TMP_)" }

    if ($FilesToProcess.Count -eq 0) {
        Write-Log "No files found to process." "Yellow"
        return
    }

    $WriteLogDefStr = ${function:Write-Log}.ToString()
    $GetEdlDefStr = ${function:Get-BestMatchingEDL}.ToString()
    $ConvertTimeDefStr = ${function:Convert-TimecodeToNs}.ToString()

    # Run in parallel
    $FilesToProcess | ForEach-Object -Parallel {
        $LogFile = $using:LogFile

        # Load functions from the main script as strings and create script blocks
        $WriteLogDef = [scriptblock]::Create($using:WriteLogDefStr)
        $GetEdlDef = [scriptblock]::Create($using:GetEdlDefStr)
        $ConvertTimeDef = [scriptblock]::Create($using:ConvertTimeDefStr)

        # Re-create them in the local parallel runspace
        New-Item -Path function:Write-Log -Value $WriteLogDef -Force | Out-Null
        New-Item -Path function:Get-BestMatchingEDL -Value $GetEdlDef -Force | Out-Null
        New-Item -Path function:Convert-TimecodeToNs -Value $ConvertTimeDef -Force | Out-Null

        $File = $_
        
        # --- Function Definitions (Must be redefined in parallel runspace) ---

        $RelPath = $File.FullName.Replace($using:SourceFolder, "")
        # Note: Newlines in Write-Host might be messy in parallel, but keeping as is.
        Write-Log "Processing: $RelPath" "Cyan"

        # 1. Analyze Source File
        try {
            $SourceProbe = ffprobe -v "error" `
                -select_streams "v:0" `
                -show_entries "stream=codec_name, height, r_frame_rate" `
                -show_entries "format=duration, nb_streams" `
                -of "json" "$($File.FullName)" | ConvertFrom-Json
            $SourceAudioCount = (ffprobe -v "error" `
                    -select_streams "a" `
                    -show_entries "stream=index" `
                    -of "csv=p=0" `
                    "$($File.FullName)" | Measure-Object).Count
        }
        catch {
            Write-Log "  [Error] Could not probe source file: $($File.Name). Skipping." "Red"
            return # Continues to next iteration in parallel loop
        }

        $SourceCodec = $SourceProbe.streams.codec_name
        $SourceHeight = $SourceProbe.streams.height
        $SourceDuration = [math]::Round([double]$SourceProbe.format.duration)
        
        $FpsRaw = $SourceProbe.streams.r_frame_rate
        $Num, $Den = $FpsRaw.Split('/')
        $FrameRate = [double]$Num / [double]$Den

        Write-Log "  [Info] $($File.Name) Source Codec: $SourceCodec" "Green"
        # Reduced logging verbosity slightly to avoid console spam from multiple threads

        # 2. Find EDL (Fuzzy or Exact)
        $EdlFile = Get-BestMatchingEDL -VideoFile $File
        $MetadataFile = Join-Path $File.DirectoryName ("TMP_Chapters_" + $File.BaseName + ".txt")
        $HasChapters = $false

        if ($EdlFile -and (Test-Path $EdlFile)) {
            Write-Log "  [Info] EDL Found for $($File.Name): $(Split-Path $EdlFile -Leaf)" "Yellow"
            
            $EdlContent = Get-Content $EdlFile
            $MetadataContent = @(";FFMETADATA1")
            $Pattern = "\d+\s+.*\s+(\d{2}:\d{2}:\d{2}[:;]\d{2})\s+(\d{2}:\d{2}:\d{2}[:;]\d{2})$"
            $ChapterIndex = 1
            
            for ($i = 0; $i -lt $EdlContent.Count; $i++) {
                $Line = $EdlContent[$i]
                if ($Line -match $Pattern) {
                    $StartTC = $Matches[1]
                    $EndTC = $Matches[2]
                    
                    $Title = "Chapter $ChapterIndex"
                    if (($i + 1) -lt $EdlContent.Count) {
                        $NextLine = $EdlContent[$i + 1]
                        if ($NextLine -match "\*\s*(LOC:|FROM CLIP NAME:)\s*(.*)") {
                            $Title = $Matches[2].Trim() -replace "^\d{2}:\d{2}:\d{2}[:;]\d{2}\s*", "" 
                        }
                    }

                    $StartMs = Convert-TimecodeToNs -Timecode $StartTC -FrameRate $FrameRate
                    $EndMs = Convert-TimecodeToNs -Timecode $EndTC -FrameRate $FrameRate

                    $MetadataContent += "[CHAPTER]"
                    $MetadataContent += "TIMEBASE=1/1000"
                    $MetadataContent += "START=$StartMs"
                    $MetadataContent += "END=$EndMs"
                    $MetadataContent += "title=$Title"
                    
                    $ChapterIndex++
                }
            }

            if ($ChapterIndex -gt 1) {
                $MetadataContent | Out-File -FilePath $MetadataFile -Encoding UTF8
                $HasChapters = $true
            }
        }

        # 3. Check if conversion is needed
        if ($SourceCodec -eq "av1" -and $SourceHeight -eq $using:TargetHeight) {
            Write-Log "  [Skip] $($File.Name) is already AV1 and 1080p." "Green"
            if ($HasChapters) { Remove-Item $MetadataFile -ErrorAction SilentlyContinue }
            return
        }

        Write-Log "  [Info] Converting $($File.Name) to AV1 1080p." "Green"

        $TempOutput = Join-Path $File.DirectoryName ("TMP_" + $File.BaseName + $using:OutputExtension)

        $Process = $null
        try {
            # 4. Construct FFmpeg Arguments
            $FFmpegArgs = @("-i", "`"$($File.FullName)`"")

            if ($HasChapters) {
                $FFmpegArgs += ("-i", "`"$MetadataFile`"", "-map_metadata", "1")
            }

            $FFmpegArgs += (
                "-map", "0:V:0",   
                "-map", "0:a?",
                "-map", "0:s?",    
                "-c:v", $using:Encoder, "-preset", $using:Preset, "-rc:v", "vbr", "-cq:v", $using:CQ, "-b:v", "0",
                "-vf", "scale=-2:$using:TargetHeight", 
                "-c:a", "aac", "-b:a", "320k",
                "-c:s", "copy",
                "-y", "`"$TempOutput`""
            )

            $StartTime = Get-Date

            # Start process without -Wait so we can capture the object immediately for cleanup if interrupted
            $Process = Start-Process -FilePath "ffmpeg" -ArgumentList $FFmpegArgs -NoNewWindow -PassThru
            
            # Wait for the process to complete
            $Process | Wait-Process
            
            $EndTime = Get-Date

            # 5. VERIFICATION STAGE
            if ($Process.ExitCode -eq 0) {
                try {
                    $DestProbe = ffprobe -v "error" `
                        -select_streams "v:0" `
                        -show_entries "stream=codec_name, height" `
                        -show_entries "format=duration" `
                        -of "json" "$TempOutput" | ConvertFrom-Json
                    $DestAudioCount = (ffprobe -v "error" `
                            -select_streams "a" `
                            -show_entries "stream=index" `
                            -of "csv=p=0" `
                            "$TempOutput" | Measure-Object).Count
                    $DestChapterCount = (ffprobe -v "error" `
                            -show_chapters `
                            -of "json" `
                            "$TempOutput" | ConvertFrom-Json).chapters.Count

                    $DestCodec = $DestProbe.streams.codec_name
                    $DestHeight = $DestProbe.streams.height
                    $DestDuration = [math]::Round([double]$DestProbe.format.duration)
                    
                    $ValidCodec = $DestCodec -eq "av1"
                    $ValidHeight = $DestHeight -eq $using:TargetHeight
                    $ValidDuration = [math]::Abs($SourceDuration - $DestDuration) -le $using:DurationTolerance
                    $ValidAudio = $SourceAudioCount -eq $DestAudioCount

                    if ($ValidCodec -and $ValidHeight -and $ValidDuration -and $ValidAudio) {
                        # Access file length via Get-Item because property might be stale on object? 
                        # $File is safe to use for read properties, but reload if size changed (unlikely for source).
                        $OldVideoFileSizeGb = [math]::Round($File.Length / 1GB, 2)
                        $NewVideoFileSizeGb = [math]::Round((Get-Item $TempOutput).Length / 1GB, 2)
                        $ReductionPerc = [math]::Round((($OldVideoFileSizeGb - $NewVideoFileSizeGb) / $OldVideoFileSizeGb) * 100, 2)
                        $TimeTaken = New-TimeSpan -Start $StartTime -End $EndTime
                        $ChapterMsg = if ($HasChapters) { " | Chapters: $DestChapterCount" } else { "" }
                        Write-Log "  [Success] Verified $($File.Name) | Audio: $SourceAudioCount -> $DestAudioCount$ChapterMsg" "Green"
                        Write-Log "  [Success] Video Size: $OldVideoFileSizeGb GB -> $NewVideoFileSizeGb GB ($ReductionPerc%)" "Green"
                        Write-Log "  [Success] Time taken: $TimeTaken" "Green"
                        
                        $OldBackupName = "OLD_" + $File.Name
                        $OldBackupPath = Join-Path $File.DirectoryName $OldBackupName
                        if (Test-Path $OldBackupPath) { Remove-Item $OldBackupPath -Force }

                        Rename-Item -Path $File.FullName -NewName $OldBackupName
                        $NewFinalName = $File.BaseName + $using:OutputExtension
                        Rename-Item -Path $TempOutput -NewName $NewFinalName
                    }
                    else {
                        Write-Log "  [FAILURE] Verification Failed for $($File.Name)! Keeping original." "Red"
                        if (-not $ValidAudio) { Write-Log "  Audio Mismatch ($SourceAudioCount vs $DestAudioCount)" "Red" }
                        # Cleanup handled in finally
                    }
                }
                catch {
                    Write-Log "  [Error] Probe failed for $($File.Name)." "Red"
                    # Cleanup handled in finally
                }
            }
            else {
                Write-Log "  [Error] FFmpeg crashed for $($File.Name)." "Red"
                # Cleanup handled in finally
            }
        }
        finally {
            # 1. Kill invalid ffmpeg process (Cancellation / Crash)
            if ($Process -and -not $Process.HasExited) {
                try {
                    Write-Log "  [Interrupted] Killing FFmpeg process for $($File.Name)..." "Red"
                    $Process | Stop-Process -Force -ErrorAction SilentlyContinue
                }
                catch {}
            }
            
            # 2. Cleanup Temp Video File
            # If $TempOutput still exists, it means we failed to reach the Rename-Item stage (Success)
            if ($TempOutput -and (Test-Path $TempOutput)) { 
                try {
                    # Add a small delay/retry for file locks
                    Start-Sleep -Milliseconds 200
                    Remove-Item $TempOutput -Force -ErrorAction SilentlyContinue 
                    if (Test-Path $TempOutput) {
                        Write-Log "  [Cleanup] Removing incomplete file: $TempOutput" "Magenta"
                        Remove-Item $TempOutput -Force -ErrorAction SilentlyContinue
                    }
                }
                catch {}
            }
            
            # 3. Cleanup Metadata File
            if ($HasChapters -and $MetadataFile -and (Test-Path $MetadataFile)) {
                Remove-Item $MetadataFile -Force -ErrorAction SilentlyContinue
            }
        }

    } -ThrottleLimit $EncoderSessionLimit
}

Main -SourceFolder $SourceFolder -LogFile $LogFile -MaxEncodes $MaxEncodes
