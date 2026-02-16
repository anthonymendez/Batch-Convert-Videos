<#
    Video Encoder Script
    Copyright (C) 2026 Anthoyn Mendez

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
#>
# --- Configuration ---
$SourceFolder = "Z:\General\videoprojects\Recordings"
$LogFile = "C:\Users\Anthony\Videos\encoding_log.txt"
$OutputExtension = ".mp4" 
$TargetHeight = 1080
$Encoder = "av1_nvenc"    
$CQ = 26 
$Preset = "p7"
$DurationTolerance = 5 

# Supported extensions
$VideoExtensions = @(".mp4", ".mkv", ".avi", ".mov", ".flv", ".wmv")

# --- Helper Function: Logging ---
function Write-Log {
    param ($Message, $Color="White")
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogMsg = "[$TimeStamp] $Message"
    Write-Host $LogMsg -ForegroundColor $Color
    Add-Content -Path $LogFile -Value $LogMsg
}

# --- Helper Function: Find EDL with Fuzzy Matching ---
function Get-BestMatchingEDL {
    param ($VideoFile)
    
    $Dir = $VideoFile.DirectoryName
    $Base = $VideoFile.BaseName
    
    # 1. Try Exact Match First
    $ExactPath = Join-Path $Dir "$Base.edl"
    if (Test-Path $ExactPath) { return $ExactPath }

    # 2. Fuzzy Match: Find EDL with the Longest Common Prefix
    # This handles "Video_120000.mkv" matching "Video_120003.edl"
    $AllEdls = Get-ChildItem -Path $Dir -Filter "*.edl"
    
    $BestMatch = $null
    $BestScore = 0
    
    foreach ($Edl in $AllEdls) {
        $EdlName = $Edl.BaseName
        $MatchCount = 0
        $MinLen = [math]::Min($Base.Length, $EdlName.Length)
        
        # Count identical characters from the start
        for ($i = 0; $i -lt $MinLen; $i++) {
            $BaseChar = $Base[$i]
            $EdlChar = $EdlName[$i]
            if ($Base[$i] -eq $EdlName[$i]) {
                $MatchCount++
            }
        }
        
        # Criteria: Must match at least 80% of the filename to be considered safe
        # We pick the one with the HIGHEST match count (closest timestamp)
        $PercentMatch = $MatchCount / $Base.Length
        
        if ($PercentMatch -gt 0.8 -and $MatchCount -gt $BestScore) {
            $BestScore = $MatchCount
            $BestMatch = $Edl.FullName
        }
    }

    return $BestMatch
}

# --- Helper Function: Parse Timecode ---
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
Write-Log "Starting Batch Processing (Fuzzy EDL Match)..." "Cyan"

$Files = Get-ChildItem -Path $SourceFolder -Recurse | Where-Object { $VideoExtensions -contains $_.Extension.ToLower() }

foreach ($File in $Files) {
    if ($File.Name -match "^(OLD_|TMP_)") { continue }

    $RelPath = $File.FullName.Replace($SourceFolder, "")
    Write-Host "`n------------------------------------------------"
    Write-Log "Processing: $RelPath" "Cyan"

    # 1. Analyze Source File
    try {
        $SourceProbe = ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,height,r_frame_rate -show_entries format=duration,nb_streams -of json "$($File.FullName)" | ConvertFrom-Json
        $SourceAudioCount = (ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$($File.FullName)" | Measure-Object).Count
    } catch {
        Write-Log "  [Error] Could not probe source file. Skipping." "Red"
        continue
    }

    $SourceCodec = $SourceProbe.streams.codec_name
    $SourceHeight = $SourceProbe.streams.height
    $SourceDuration = [math]::Round([double]$SourceProbe.format.duration)
    
    $FpsRaw = $SourceProbe.streams.r_frame_rate
    $Num,$Den = $FpsRaw.Split('/')
    $FrameRate = [double]$Num / [double]$Den

    # 2. Find EDL (Fuzzy or Exact)
    $EdlFile = Get-BestMatchingEDL -VideoFile $File
    $MetadataFile = Join-Path $File.DirectoryName ("TMP_Chapters_" + $File.BaseName + ".txt")
    $HasChapters = $false

    if ($EdlFile -and (Test-Path $EdlFile)) {
        Write-Log "  [Info] EDL Found: $(Split-Path $EdlFile -Leaf)" "Yellow"
        
        $EdlContent = Get-Content $EdlFile
        $MetadataContent = @(";FFMETADATA1")
        $Pattern = "\d+\s+.*\s+(\d{2}:\d{2}:\d{2}[:;]\d{2})\s+(\d{2}:\d{2}:\d{2}[:;]\d{2})$"
        $ChapterIndex = 1
        
        for ($i=0; $i -lt $EdlContent.Count; $i++) {
            $Line = $EdlContent[$i]
            if ($Line -match $Pattern) {
                $StartTC = $Matches[1]
                $EndTC = $Matches[2]
                
                $Title = "Chapter $ChapterIndex"
                if (($i + 1) -lt $EdlContent.Count) {
                    $NextLine = $EdlContent[$i+1]
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
    } else {
        Write-Log "  [Info] No matching EDL found." "DarkGray"
    }

    # 3. Check if conversion is needed
    if ($SourceCodec -eq "av1" -and $SourceHeight -eq $TargetHeight) {
        Write-Log "  [Skip] File is already AV1 and 1080p." "Green"
        if ($HasChapters) { Remove-Item $MetadataFile -ErrorAction SilentlyContinue }
        continue
    }

    $TempOutput = Join-Path $File.DirectoryName ("TMP_" + $File.BaseName + $OutputExtension)

    # 4. Construct FFmpeg Arguments
    $FFmpegArgs = @("-i", "`"$($File.FullName)`"")

    if ($HasChapters) {
        $FFmpegArgs += ("-i", "`"$MetadataFile`"", "-map_metadata", "1")
    }

    $FFmpegArgs += (
        "-map", "0:V:0",   
        "-map", "0:a?",
        "-map", "0:s?",    
        "-c:v", $Encoder, "-preset", $Preset, "-rc:v", "vbr", "-cq:v", $CQ, "-b:v", "0",
        "-vf", "scale=-2:$TargetHeight", 
        "-c:a", "aac", "-b:a", "320k",
        "-c:s", "copy",
        "-y", "`"$TempOutput`""  # <--- Added quotes here too
    )

    $StartTime = Get-Date
    $Process = Start-Process -FilePath "ffmpeg" -ArgumentList $FFmpegArgs -Wait -NoNewWindow -PassThru
    $EndTime = Get-Date
    
    if ($HasChapters) { Remove-Item $MetadataFile -ErrorAction SilentlyContinue }

    # 5. VERIFICATION STAGE
    if ($Process.ExitCode -eq 0) {
        try {
            $DestProbe = ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,height -show_entries format=duration -of json "$TempOutput" | ConvertFrom-Json
            $DestAudioCount = (ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$TempOutput" | Measure-Object).Count
            $DestChapterCount = (ffprobe -v error -show_chapters -of json "$TempOutput" | ConvertFrom-Json).chapters.Count

            $DestCodec = $DestProbe.streams.codec_name
            $DestHeight = $DestProbe.streams.height
            $DestDuration = [math]::Round([double]$DestProbe.format.duration)
            
            $ValidCodec = $DestCodec -eq "av1"
            $ValidHeight = $DestHeight -eq $TargetHeight
            $ValidDuration = [math]::Abs($SourceDuration - $DestDuration) -le $DurationTolerance
            $ValidAudio = $SourceAudioCount -eq $DestAudioCount

            if ($ValidCodec -and $ValidHeight -and $ValidDuration -and $ValidAudio) {
                $TimeTaken = New-TimeSpan -Start $StartTime -End $EndTime
                $ChapterMsg = if ($HasChapters) { " | Chapters: $DestChapterCount" } else { "" }
                Write-Log "  [Success] Verified AV1 1080p | Audio: $SourceAudioCount -> $DestAudioCount$ChapterMsg" "Green"
                
                $OldBackupName = "OLD_" + $File.Name
                $OldBackupPath = Join-Path $File.DirectoryName $OldBackupName
                if (Test-Path $OldBackupPath) { Remove-Item $OldBackupPath -Force }

                Rename-Item -Path $File.FullName -NewName $OldBackupName
                $NewFinalName = $File.BaseName + $OutputExtension
                Rename-Item -Path $TempOutput -NewName $NewFinalName
            }
            else {
                Write-Log "  [FAILURE] Verification Failed! Keeping original." "Red"
                if (-not $ValidAudio) { Write-Log "  Audio Mismatch ($SourceAudioCount vs $DestAudioCount)" "Red" }
                if (Test-Path $TempOutput) { Remove-Item $TempOutput }
            }

        } catch {
            Write-Log "  [Error] Probe failed." "Red"
            if (Test-Path $TempOutput) { Remove-Item $TempOutput }
        }
    } else {
        Write-Log "  [Error] FFmpeg crashed." "Red"
        if (Test-Path $TempOutput) { Remove-Item $TempOutput }
    }
}