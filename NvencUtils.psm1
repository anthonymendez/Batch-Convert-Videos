function Get-NVENCSessions {
    <#
    .SYNOPSIS
        Returns the max concurrent NVENC sessions for a given NVIDIA GPU name.
    .EXAMPLE
        Get-NVENCSessions -GpuName "NVIDIA GeForce RTX 5090"
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$GpuName
    )

    # 1. High-Fidelity Data Map (Based on your provided table)
    $LookupTable = @(
        @{ Name = "RTX 5090"; Sessions = 12; Chips = 3 }
        @{ Name = "RTX 5080"; Sessions = 12; Chips = 2 }
        @{ Name = "RTX 5070 Ti"; Sessions = 12; Chips = 2 }
        @{ Name = "RTX 5070"; Sessions = 12; Chips = 1 }
        @{ Name = "RTX 5060"; Sessions = 12; Chips = 1 }
        @{ Name = "RTX 5050"; Sessions = 12; Chips = 1 }
        @{ Name = "RTX 4090"; Sessions = 12; Chips = 2 }
        @{ Name = "RTX 4080"; Sessions = 12; Chips = 2 }
        @{ Name = "RTX 4070 Ti"; Sessions = 12; Chips = 2 }
        @{ Name = "RTX 4070"; Sessions = 12; Chips = 1 }
        @{ Name = "RTX 4060"; Sessions = 12; Chips = 1 }
        @{ Name = "RTX 4050"; Sessions = 12; Chips = 1 }
        @{ Name = "GTX 1080 Ti"; Sessions = 12; Chips = 2 }
        @{ Name = "GTX 1080"; Sessions = 12; Chips = 2 }
        @{ Name = "GTX 1070"; Sessions = 12; Chips = 2 }
        @{ Name = "GTX 1060"; Sessions = 12; Chips = 1 }
        @{ Name = "Titan V"; Sessions = 12; Chips = 3 }
        @{ Name = "GT 1030"; Sessions = 0; Chips = 0 }
        @{ Name = "MX"; Sessions = 0; Chips = 0 }
    ) | ForEach-Object { [pscustomobject]$_ }

    # 2. Cleanup input string (removes common prefixes/suffixes from nvidia-smi)
    $CleanInput = $GpuName -replace "NVIDIA ", "" -replace "GeForce ", ""

    # 3. Fuzzy match logic: Find the most specific match (longest string match)
    $Match = $LookupTable | Where-Object { $CleanInput -like "*$($_.Name)*" } | 
    Sort-Object { $_.Name.Length } -Descending | Select-Object -First 1

    if ($Match) {
        return $Match.Sessions
    }
    else {
        Write-Warning "GPU '$GpuName' not found in lookup table. Defaulting to standard consumer limit."
        return 8 # Modern driver default for unlisted cards
    }
}

# Optional: Function to auto-detect and return sessions for local hardware
function Get-LocalGPUSessions {
    try {
        # Query just the name and use Select-Object to skip the "name" header line
        $smi = (nvidia-smi --query-gpu=name --format=csv) | Select-Object -Skip 1
        if (-not $smi) { throw "No GPU output" }

        foreach ($line in $smi) {
            # Trim whitespace to ensure clean matching
            $gpuName = $line.Trim()
            $sessions = Get-NVENCSessions -GpuName $gpuName
            
            [pscustomobject]@{
                GPU         = $gpuName
                MaxSessions = $sessions
            }
        }
    }
    catch {
        Write-Error "nvidia-smi failed or no NVIDIA GPU detected. Ensure NVIDIA drivers are installed."
    }
}

# Returns the max amount of NVENC sessions for the local GPU minus 1 or 2 for safety.
# If sessions is 0, returns 1.
# If sessions is 1, returns 1.
# If sessions is 2, returns 1.
# If sessions is 3, returns 2.
# etc.
function Get-LocalGPUSessionsMinusOneOrTwo {
    $sessions = Get-LocalGPUSessions
    return [math]::Max($sessions.MaxSessions - 1, 1)
}

Export-ModuleMember -Function `
    Get-NVENCSessions, `
    Get-LocalGPUSessions, `
    Get-LocalGPUSessionsMinusOneOrTwo
