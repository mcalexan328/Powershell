
param (
    [Parameter(Mandatory = $true)]
    [string]$groupName,
    [string]$outputCsv = ""
)

# Define the app registration details
$tenantId = 
$appId = 
$appSecret = 

# Build authorization request
$authUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
$body = @{
    grant_type    = "client_credentials"
    client_id     = $appId
    client_secret = $appSecret
    scope         = "https://graph.microsoft.com/.default"
}

try {
    $authResponse = Invoke-RestMethod -Method Post -Uri $authUrl -Body $body
    $accessToken = $authResponse.access_token
} catch {
    Write-Error "Failed to authenticate with Microsoft Graph: $_"
    exit 1
}

$headers = @{
    Authorization = "Bearer $accessToken"
    "Content-Type" = "application/json"
}

# Get Group ID
$groupUrl = "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$groupName'"
try {
    $groupResponse = Invoke-RestMethod -Method Get -Uri $groupUrl -Headers $headers
    if (-not $groupResponse.value) {
        Write-Error "Group '$groupName' not found."
        exit 1
    }
    $groupId = $groupResponse.value[0].id
} catch {
    Write-Error "Failed to retrieve group: $_"
    exit 1
}

# Get all group members (paginated)
$devices = [System.Collections.Generic.List[PSCustomObject]]::new()
$deviceUrl = "https://graph.microsoft.com/v1.0/groups/$groupId/members"

do {
    try {
        $deviceResponse = Invoke-RestMethod -Method Get -Uri $deviceUrl -Headers $headers

        foreach ($member in $deviceResponse.value) {
            $devices.Add($member)
        }

        $deviceUrl = $deviceResponse.'@odata.nextLink'
    } catch {
        Write-Error "Failed to retrieve group members: $_"
        exit 1
    }
} while ($deviceUrl)

# Batch configuration
$batchSize = 20  # Microsoft Graph batch limit
$batchUrl = "https://graph.microsoft.com/v1.0/`$batch"
$totalDevices = $devices.Count
#$processed = 0

$deviceOwners = [System.Collections.Generic.List[PSCustomObject]]::new()

# Process devices in batches
for ($i = 0; $i -lt $totalDevices; $i += $batchSize) {
    $success = $false
    $maxtries = 0

    $currentBatch = $devices[$i..[Math]::Min($i + $batchSize - 1, $totalDevices - 1)]

    # Build batch request body
    $batchRequests = [System.Collections.Generic.List[object]]::new()
    foreach ($device in $currentBatch) {
        $batchRequests.Add([PSCustomObject]@{
            id     = $device.id
            method = "GET"
            url    = "/devices/$($device.id)"
        })
    }

    # Retry loop for batch call
    do {
        $batchBody = @{ requests = $batchRequests } | ConvertTo-Json -Depth 5
        $batchResponse = Invoke-RestMethod -Method Post -Uri $batchUrl -Headers $headers -Body $batchBody -ContentType "application/json"

        if ($batchResponse.responses.status -contains "429") {
            $sleeptimer = 120
            foreach ($badresponse in $batchResponse.responses) {
                if ($badresponse.status -eq "429") {
                    try {
                        $retryAfter = ($badresponse.body.error.message | ConvertFrom-Json).RetryAfter
                        if ($retryAfter) { $sleeptimer = $retryAfter }
                    } catch {}
                }
            }
            Start-Sleep -Seconds $sleeptimer
            $maxtries++
        }
        else { $success = $true }
    }
    while (-not $success -and $maxtries -le 5)

    # Process batch responses
    $deviceDetailsMap = @{}
    foreach ($response in $batchResponse.responses) {
        <#$processed++
        Write-Progress -Activity "Processing Devices" -Status "$processed of $totalDevices" `
            -PercentComplete (($processed / $totalDevices) * 100) #>

        if ($response.status -eq 200) {
            $device = $response.body
            $deviceDetailsMap[$device.id] = $device.displayName
        }
        else {
            Write-Warning "Failed to retrieve device info for ID=$($response.id) - Status=$($response.status)"
        }
    }

    # Now retrieve registeredOwners one-by-one
    foreach ($device in $currentBatch) {
        $deviceId = $device.id
        $displayName = $deviceDetailsMap[$deviceId]

        $ownerUrl = "https://graph.microsoft.com/v1.0/devices/$deviceId/registeredOwners"
        try {
            $ownerResponse = Invoke-RestMethod -Method Get -Uri $ownerUrl -Headers $headers

            foreach ($owner in $ownerResponse.value) {
                $deviceOwners.Add([PSCustomObject]@{
                    DeviceName = $displayName
                    OwnerName  = $owner.displayName
                    Email      = $owner.mail
                })
            }
        }
        catch {
            Write-Warning "Failed to retrieve owners for device ID $deviceId`: $_"
        }
    }
}

# Output to console
$deviceOwners

# Optional CSV export
if ($outputCsv) {
    try {
        $deviceOwners | Export-Csv -Path $outputCsv -NoTypeInformation -Encoding UTF8
        Write-Host "Exported results to $outputCsv"
    } catch {
        Write-Warning "Failed to export CSV: $_"
    }
}
