# Batch-Convert-Videos
Powershell script/tool that converts all video files in a directory (and child directories) to 1080p AV1 (for now). **THIS IS VIBE-CODED WITH GEMINI** since I just needed to get something up and running to save space on my NAS. I realize that there is handbrake and that can do it for me, 

## Requirements

* Powershell 5.1+
* [ffmpeg](https://www.ffmpeg.org/)

## Features

* Converts any `mp4`, `mkv`, `avi`, `mov`, `flv`, `wmv` to 1080p AV1.
* Does not convert if the file is already 1080p AV1 OR prefixed with `OLD_`.
* Default Settings: 1080p, `av1_nvenc`, CQ = 26, Encoder Preset p7 (slowest), mp4.
* Integrates EDL (video editing metadata file) data into the video files itself if the fuzzy match is close enough (80% of characters).
* Copies all video, audio, and subtitle tracks.
  * Note: audio tracks are re-encoded at 320 kbit/s. I have some issues just straight copying the audio sometimes. This is to help get around that issue.
* Validates video and audio were copied.

## TODO

Some stuff I want to get around to eventually:

* Compatible with Linux/MAC - Probably requires moving to a different language altogether. Rust maybe?
* Only re-encode audio tracks if copying fails. Maybe a short test encode for each file before doing a full encode?
* Select different options for the encoder.
* TUI or GUI.

## Background

For a few years now, I have numerous gameplay and stream sessions saved from playing games with my friends or on Twitch. All in various formats (H264, H265, AV1, 1080p, 1440p, 4k, various bitrates). Along with a short stint of marking moments in the video file with EDL files before Hybrid MP4s and chapter markers were supported in OBS.

I of course, am horrible at deleting old footage, because I never know if I'll need it for a future video project. Nowadays, I realize I don't really need 4k footage of the gameplay. I can make do with 1080p and with AV1, the quality looks fantastic still. So I asked Gemini to create this in a single day. Currently batch processing all the videos on my NAS 
