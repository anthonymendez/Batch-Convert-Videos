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
# Tests the video encoder script with the TestVideos folder.

# --- Configuration ---
$TestFolder = "./TestVideos"
$LogFile = "./TestVideos/encoding_log.txt"
$BatchScript = "./VideosToAv1WithMarkers.ps1"
$DurationTolerance = 5

# Check if TestVideo.mkv exists, if not try to restore from OLD_ORIGINAL.mkv
if (-not (Test-Path (Join-Path $TestFolder "TestVideo.mkv"))) {
    if (Test-Path (Join-Path $TestFolder "OLD_ORIGINAL.mkv")) {
        Write-Host "Restoring TestVideo.mkv from OLD_ORIGINAL.mkv..." -ForegroundColor Yellow
        Copy-Item -Path (Join-Path $TestFolder "OLD_ORIGINAL.mkv") -Destination (Join-Path $TestFolder "TestVideo.mkv") -Force
    }
    else {
        Write-Error "TestVideo.mkv and OLD_ORIGINAL.mkv are missing! Cannot run test."
        exit 1
    }
}

# Copy Original video file to OLD_ORIGINAL.mkv.
Copy-Item -Path (Join-Path $TestFolder "TestVideo.mkv") -Destination (Join-Path $TestFolder "OLD_ORIGINAL.mkv") -Force

# Run the script and wait for it to finish.
# Output the process console to current console as well.
$Process = Start-Process -FilePath "powershell" `
    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File $BatchScript -SourceFolder $TestFolder -LogFile $LogFile" `
    -PassThru `
    -Wait

# Check if the script completed successfully.
if ($Process.ExitCode -eq 0) {
    Write-Host "Script completed successfully." -ForegroundColor Green

    # Check if the log file exists.
    if (Test-Path $LogFile) {
        Write-Host "Log file created successfully." -ForegroundColor Green
    }
    else {
        Write-Host "Log file not found." -ForegroundColor Red
    }

    # Check if the new file exists.
    if (Test-Path (Join-Path $TestFolder "TestVideo.mp4")) {
        Write-Host "New file created successfully." -ForegroundColor Green
    }
    else {
        Write-Host "New file not found." -ForegroundColor Red
    }

    # Check if the old file still exists.
    if (Test-Path (Join-Path $TestFolder "TestVideo.mp4")) {
        Write-Host "Old file still exists." -ForegroundColor Red
    }
    else {
        Write-Host "Old file deleted successfully." -ForegroundColor Green
    }

    # Check if the audio tracks were copied over.
    $NewAudioCount = (ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$(Join-Path $TestFolder "TestVideo.mp4")" | Measure-Object).Count
    if ($NewAudioCount -eq $SourceAudioCount) {
        Write-Host "Audio tracks copied successfully." -ForegroundColor Green
    }
    else {
        Write-Host "Audio tracks not copied." -ForegroundColor Red
    }

    # Check if the chapters were copied over.
    $NewChapterCount = (ffprobe -v error -show_chapters -of json "$(Join-Path $TestFolder "TestVideo.mp4")" | ConvertFrom-Json).chapters.Count
    if ($NewChapterCount -eq $SourceChapterCount) {
        Write-Host "Chapters copied successfully." -ForegroundColor Green
    }
    else {
        Write-Host "Chapters not copied." -ForegroundColor Red
    }

    # Check if the duration is within tolerance.
    $NewDuration = [math]::Round([double](ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$(Join-Path $TestFolder "TestVideo.mp4")" | ConvertFrom-Json), 2)
    if ([math]::Abs($NewDuration - $SourceDuration) -le $DurationTolerance) {
        Write-Host "Duration within tolerance." -ForegroundColor Green
    }
    else {
        Write-Host "Duration not within tolerance." -ForegroundColor Red
    }
}
else {
    Write-Host "Script failed with exit code: $Process.ExitCode" -ForegroundColor Red
}

# Copy test results to folder called TestResults_${TIMESTAMP}
$TestResultName = "TestResults_$(Get-Date -Format "yyyy-MM-dd_HH-mm-ss")"
$TestResultPath = (Join-Path $TestFolder $TestResultName)
Write-Host "TestResultPath: $TestResultPath"
New-Item -Path $TestResultPath -ItemType Directory -Force

# Move all files from TestVideos to TestResults_${TIMESTAMP} except for OLD_ORIGINAL.mkv and the results folder itself
Get-ChildItem -Path $TestFolder -Exclude "OLD_ORIGINAL.mkv" | 
Where-Object { $_.Name -notlike "TestResults_*" } | 
Move-Item -Destination $TestResultPath -Force

# Restore Original video file to TestVideo.mkv.
Move-Item -Path (Join-Path $TestFolder "OLD_ORIGINAL.mkv") -Destination (Join-Path $TestFolder "TestVideo.mkv") -Force
