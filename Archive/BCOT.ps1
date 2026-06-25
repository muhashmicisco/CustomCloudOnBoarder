<#
.SYNOPSIS
    Automated Bulk Onboarding for Cisco RoomOS devices to Webex Cloud (GA 1.0).
    
.DESCRIPTION
    Phase 1: Identity Resolution (User Email to PersonID / Location Name to LocationID).
    Phase 2: Cloud Workspace Creation with correct Identity Name.
    Phase 3: Local Device Handshake (System Name, Wizard Bypass, Proxy, Registration).
    Phase 4: Personalization (Optional - Flips device to Personal Mode).
    Phase 5: Cloud Conversion & Calling Enablement (Assigns Extension/Location).

.CSV_HEADERS
    IP,Username,Password,Email,Location,Extension,WorkspaceName
#>

# --- CONFIGURATION: SET DEBUG LEVEL HERE ---
# Level 1: Basic | Level 2: Technical (URIs/Codes) | Level 3: Verbose (Full Payloads/Responses)
$DebugLevel = 1 

# 1. Setup Security Protocols
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null
$originalCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback

Write-Host "=== Cisco RoomOS Bulk Cloud Onboarding (GA Code 1.0) ===" -ForegroundColor Cyan
Write-Host "Debug Level: $DebugLevel" -ForegroundColor DarkGray

# --- Section 1: Source Selection ---
$csvPath = Read-Host "`nEnter CSV file path (Leave BLANK for single device)"
$devices = @()

if (-not [string]::IsNullOrWhiteSpace($csvPath)) {
    if (Test-Path $csvPath) { 
        $devices = Import-Csv -Path $csvPath 
        Write-Host "Successfully loaded $($devices.Count) devices from CSV." -ForegroundColor Green
    } else { Write-Error "CSV not found."; exit }
} else {
    $singleIP = Read-Host "Enter Device IP"
    $u = Read-Host "User"; $p = Read-Host "Pass"
    $optP = Read-Host "Personalize this device for a specific user? (y/N)"
    $email = $null; $wsNameInput = $null
    if ($optP -eq 'y') {
        $email = Read-Host "Enter the User's Webex Email"
    } else {
        $wsNameInput = Read-Host "Enter custom Workspace Name (Optional - Press Enter to skip)"
    }
    $optC = Read-Host "Enable Webex Calling? (y/N)"
    $locName = $null; $ext = $null
    if ($optC -eq 'y') {
        $locName = Read-Host "Enter Location Name (e.g., Richardson)"
        $ext     = Read-Host "Enter Extension"
    }
    $devices += [PSCustomObject]@{ IP=$singleIP; Username=$u; Password=$p; Email=$email; Location=$locName; Extension=$ext; WorkspaceName=$wsNameInput }
}

# --- Section 2: Global Inputs ---
Write-Host "`n=== Global Configurations ===" -ForegroundColor Cyan
$proxyUrl = Read-Host "Enter Proxy URL (Optional - Press ENTER to Skip)"
$useProxy = -not [string]::IsNullOrWhiteSpace($proxyUrl)
$bearerToken = Read-Host "Enter Webex Bearer Token"
$orgId = Read-Host "Enter Webex Org ID (Optional)"

$webexHeaders = @{ "Authorization"="Bearer $bearerToken"; "Content-Type"="application/json"; "Accept"="application/json" }

# --- Helper Functions ---

function Write-Log {
    param([int]$Level, [string]$Message, [string]$Color = "Gray")
    if ($DebugLevel -ge $Level) {
        $prefix = if ($Level -eq 2) { "[TECH]" } elseif ($Level -eq 3) { "[VERBOSE]" } else { "" }
        Write-Host "  $prefix $Message" -ForegroundColor $Color
    }
}

function Get-WebexError {
    param($ErrorRecord)
    if ($ErrorRecord.Exception.Response) {
        $reader = New-Object System.IO.StreamReader($ErrorRecord.Exception.Response.GetResponseStream())
        return $reader.ReadToEnd()
    }
    return $ErrorRecord.Exception.Message
}

function Start-Countdown {
    param([int]$Seconds, [string]$Message)
    for ($i = $Seconds; $i -gt 0; $i--) {
        Write-Host "`r  > ${Message}: $i seconds remaining...   " -NoNewline -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    }
    Write-Host "`r  > ${Message}: Complete.                         " -ForegroundColor Gray
}

$executionResults = @()

# --- Main Processing Loop ---
foreach ($device in $devices) {
    $currentEmail = if ($device.Email) { $device.Email.Trim() } else { $null }
    $currentLoc   = if ($device.Location) { $device.Location.Trim() } else { $null }
    $currentExt   = if ($device.Extension) { $device.Extension.Trim() } else { $null }
    $currentWSName = if ($device.WorkspaceName) { $device.WorkspaceName.Trim() } else { $null }
    $identityName = "WS-$($device.IP)" 

    Write-Host "`n--------------------------------------------------" -ForegroundColor Gray
    Write-Host "Processing Device: $($device.IP)" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------" -ForegroundColor Gray
    
    $tracker = [PSCustomObject]@{ IP=$device.IP; Success="FAIL"; IdentityName=""; WorkspaceID="N/A"; PersonID="N/A"; LocationID="N/A"; Extension=$currentExt; HttpStatus=""; Reason="" }
    $base64 = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($device.Username):$($device.Password)"))
    $deviceXmlHeaders = @{ "Authorization" = "Basic $base64"; "Content-Type" = "text/xml" }
    $statusUri = "https://$($device.IP)/getxml?location=/Status/Webex/Status"

    try {
        # --- PHASE 1: Webex Cloud Lookups ---
        Write-Host "[1/5] Performing Cloud Lookups..." -ForegroundColor DarkCyan
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $originalCallback
        
        if ($currentEmail) {
            $userUri = "https://webexapis.com/v1/people?email=$([Uri]::EscapeDataString($currentEmail))"
            Write-Log 2 "GET $userUri"
            $userResp = Invoke-RestMethod -Uri $userUri -Method Get -Headers $webexHeaders
            Write-Log 3 "User Response: $($userResp | ConvertTo-Json -Depth 5)"
            if ($userResp.items.Count -gt 0) { 
                $tracker.PersonID = $userResp.items[0].id 
                $identityName = $userResp.items[0].displayName
                Write-Log 1 "Identity Resolved (User): $identityName" "Green"
            }
        } elseif ($currentWSName) {
            $identityName = $currentWSName
            Write-Log 1 "Identity Resolved (Custom): $identityName" "Green"
        }
        $tracker.IdentityName = $identityName

        if ($currentLoc) {
            $locUri = "https://webexapis.com/v1/locations?name=$([Uri]::EscapeDataString($currentLoc))"
            Write-Log 2 "GET $locUri"
            $locResp = Invoke-RestMethod -Uri $locUri -Method Get -Headers $webexHeaders
            Write-Log 3 "Location Response: $($locResp | ConvertTo-Json -Depth 5)"
            $match = $locResp.items | Where-Object { $_.name -eq $currentLoc -or $_.id -eq $currentLoc }
            if ($match) { 
                $tracker.LocationID = $match[0].id
                Write-Log 1 "Location Resolved: $($match[0].name)" "Green"
            }
        }

        # --- PHASE 2: Workspace Creation ---
        Write-Host "[2/5] Creating Workspace..." -ForegroundColor DarkCyan
        $wsBody = @{ displayName = $identityName; calling = @{ type = "webexEdgeForDevices" } }
        if ($orgId) { $wsBody.Add("orgId", $orgId) }
        
        Write-Log 2 "POST https://webexapis.com/v1/workspaces"
        Write-Log 3 "Request Body: $($wsBody | ConvertTo-Json)"
        $wsResp = Invoke-RestMethod -Uri "https://webexapis.com/v1/workspaces" -Method Post -Headers $webexHeaders -Body ($wsBody | ConvertTo-Json -Depth 10)
        $tracker.WorkspaceID = $wsResp.id
        Write-Log 1 "Workspace Created: $($tracker.WorkspaceID)" "Green"

        $cResp = Invoke-RestMethod -Uri "https://webexapis.com/v1/devices/activationCode" -Method Post -Headers $webexHeaders -Body (@{ workspaceId=$tracker.WorkspaceID } | ConvertTo-Json)
        $workspaceCode = $cResp.code

        # --- PHASE 3: Local Device Prep & Registration ---
        Write-Host "[3/5] Local Device Handshake..." -ForegroundColor DarkCyan
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

        # 1. Set SystemUnit Name
        $null = Invoke-RestMethod -Uri "https://$($device.IP)/putxml" -Method Post -Headers $deviceXmlHeaders -Body "<Configuration><SystemUnit><Name>$identityName</Name></SystemUnit></Configuration>"

        # 2. Wizard Disablement
        $null = Invoke-RestMethod -Uri "https://$($device.IP)/putxml" -Method Post -Headers $deviceXmlHeaders -Body "<Command><SystemUnit><FirstTimeWizard><Stop></Stop></FirstTimeWizard></SystemUnit></Command>"

        # 3. Proxy Configuration
        if ($useProxy) {
            $proxyXml = "<Configuration><NetworkServices><HTTP><Mode>HTTP+HTTPS</Mode><Proxy><Url>$proxyUrl</Url><Mode>Manual</Mode></Proxy></HTTP></NetworkServices></Configuration>"
            $null = Invoke-RestMethod -Uri "https://$($device.IP)/putxml" -Method Post -Headers $deviceXmlHeaders -Body $proxyXml
            Start-Countdown -Seconds 8 -Message "Waiting for HTTP restart"
        }

        # 4. Registration
        $regXml = "<Command><Webex><Registration><Start><ActivationCode>$workspaceCode</ActivationCode><RegistrationType>Manual</RegistrationType><SecurityAction>NoAction</SecurityAction></Start></Registration></Webex></Command>"
        $null = Invoke-RestMethod -Uri "https://$($device.IP)/putxml" -Method Post -Headers $deviceXmlHeaders -Body $regXml
        
        $wsRegistered = $false
        for ($i=1; $i -le 15; $i++) {
            Start-Sleep -Seconds 5
            try {
                [xml]$xmlStatus = Invoke-RestMethod -Uri $statusUri -Method Get -Headers $deviceXmlHeaders
                if ($xmlStatus.Status.Webex.Status -eq "Registered") { $wsRegistered = $true; break }
                Write-Log 2 "Status Check: $($xmlStatus.Status.Webex.Status)"
            } catch { }
        }
        if (-not $wsRegistered) { throw "Workspace Registration timed out." }

        # --- PHASE 4: Personalization ---
        if ($tracker.PersonID -ne "N/A") {
            Write-Host "[4/5] Applying Personalization..." -ForegroundColor DarkCyan
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $originalCallback
            $pResp = Invoke-RestMethod -Uri "https://webexapis.com/v1/devices/activationCode" -Method Post -Headers $webexHeaders -Body (@{ personId=$tracker.PersonID } | ConvertTo-Json)
            
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
            $persXml = "<Command><Webex><Registration><Start><AccountLinkMode>Asynchronous</AccountLinkMode><ActivationCode>$($pResp.code)</ActivationCode><RegistrationType>Personalization</RegistrationType><SecurityAction>NoAction</SecurityAction></Start></Registration></Webex></Command>"
            $null = Invoke-RestMethod -Uri "https://$($device.IP)/putxml" -Method Post -Headers $deviceXmlHeaders -Body $persXml
            Start-Countdown -Seconds 15 -Message "Waiting for Personalization"
            $tracker.Reason = "Registered & Personalized"
        } else {
            $tracker.Reason = "Registered (Shared)"
        }

        # --- PHASE 5: Cloud Conversion & Calling ---
        if ($tracker.LocationID -ne "N/A" -and $currentExt) {
            Write-Host "[5/5] Converting to Cloud & Enabling Webex Calling if selected..." -ForegroundColor DarkCyan
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
            $null = Invoke-RestMethod -Uri "https://$($device.IP)/putxml" -Method Post -Headers $deviceXmlHeaders -Body "<Command><Webex><Registration><ConvertToCloud><Confirm>Yes</Confirm></ConvertToCloud></Registration></Webex></Command>"
            
            Start-Countdown -Seconds 120 -Message "Finalizing Cloud State (2-Minute Delay)"

            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $originalCallback
            $updateBody = @{ displayName = $identityName; calling = @{ type = "webexCalling"; webexCalling = @{ extension = $currentExt; locationId = $tracker.LocationID } } }
            $updateUri = "https://webexapis.com/v1/workspaces/$($tracker.WorkspaceID)"
            
            Write-Log 2 "PUT $updateUri"
            Write-Log 3 "Request Body: $($updateBody | ConvertTo-Json -Depth 10)"

            try {
                $response = Invoke-WebRequest -Uri $updateUri -Method Put -Headers $webexHeaders -Body ($updateBody | ConvertTo-Json -Depth 10) -UseBasicParsing
                $tracker.HttpStatus = [int]$response.StatusCode
                Write-Log 1 "Status Code: $($tracker.HttpStatus) OK" "Green"
                $tracker.Reason += " & Calling Enabled"
            } catch { 
                $tracker.HttpStatus = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "Err" }
                $errRaw = Get-WebexError $_
                Write-Log 1 "Status Code: $($tracker.HttpStatus) FAIL" "Red"
                Write-Log 3 "Error Response: $errRaw"
                $tracker.Reason += " (Calling Failed: $errRaw)"
            }
        }

        $tracker.Success = "SUCCESS"
        Write-Host "Processing Complete for $($device.IP)." -ForegroundColor Green

    } catch {
        $tracker.Success = "FAIL"; $tracker.Reason = $_.ToString(); Write-Error "Error on $($device.IP): $($tracker.Reason)"
    } finally { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $originalCallback }
    $executionResults += $tracker
}

# --- Final Summary & Logging ---
Write-Host "`n==================================================" -ForegroundColor Cyan
Write-Host "               EXECUTION SUMMARY                  " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
$executionResults | Format-Table IP, Success, HttpStatus, Reason -AutoSize

$logPath = "ExecutionLog_$(Get-Date -Format "yyyyMMdd_HHmmss").csv"
$executionResults | Export-Csv -Path $logPath -NoTypeInformation
Write-Host "Detailed log saved to: $logPath" -ForegroundColor Green
