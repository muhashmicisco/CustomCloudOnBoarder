<#
.SYNOPSIS
    Automated Bulk Onboarding for Cisco RoomOS devices to Webex Cloud (GA 1.4).
    
.PARAMETER StopAt
    The phase number to stop at (1-5). Default is 5 (Full Process).
    1: Stop after Identity Lookups
    2: Stop after Workspace Creation
    3: Stop after Device Registration
    4: Stop after Personalization
    5: Full Process (Calling Enablement)
#>

Param(
    [Parameter(Mandatory=$false)]
    [ValidateRange(1,5)]
    [int]$StopAt = 5,

    [Parameter(Mandatory=$false)]
    [string]$CSVPath,

    [Parameter(Mandatory=$false)]
    [string]$Token,

    [Parameter(Mandatory=$false)]
    [string]$OrgId
)

# --- CONFIGURATION: SET DEBUG LEVEL HERE ---
$DebugLevel = 3 

# 1. Setup Security Protocols
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null
$originalCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback

Write-Host "=== Cisco RoomOS Bulk Cloud Onboarding (GA Code 1.4) ===" -ForegroundColor Cyan
Write-Host "Execution Mode: Stop at Phase $StopAt" -ForegroundColor Yellow

# --- Section 1: Source Selection ---
if ([string]::IsNullOrWhiteSpace($CSVPath)) {
    $csvPathInput = Read-Host "`nEnter CSV file path (Leave BLANK for single device)"
    $CSVPath = $csvPathInput.Trim('"') 
}

$devices = @()
if (-not [string]::IsNullOrWhiteSpace($CSVPath)) {
    if (Test-Path $CSVPath) { 
        $devices = Import-Csv -Path $CSVPath 
        Write-Host "Loaded $($devices.Count) devices from CSV." -ForegroundColor Green
    } else { Write-Error "CSV not found at $CSVPath."; exit }
} else {
    $singleIP = Read-Host "Enter Device IP"
    $u = Read-Host "User"; $p = Read-Host "Pass"
    $optP = Read-Host "Personalize this device? (y/N)"
    $email = if ($optP -eq 'y') { Read-Host "Enter User Email" } else { $null }
    $wsNameInput = if ($optP -ne 'y') { Read-Host "Enter custom Workspace Name (Optional)" } else { $null }
    $optC = Read-Host "Enable Webex Calling? (y/N)"
    $locName = if ($optC -eq 'y') { Read-Host "Enter Location Name" } else { $null }
    $ext = if ($optC -eq 'y') { Read-Host "Enter Extension" } else { $null }
    $devices += [PSCustomObject]@{ IP=$singleIP; Username=$u; Password=$p; Email=$email; Location=$locName; Extension=$ext; WorkspaceName=$wsNameInput }
}

# --- Section 2: Proxy Configuration ---
Write-Host "`n=== Proxy Configuration ===" -ForegroundColor Cyan
Write-Host "1) No Proxy"
Write-Host "2) Manual Proxy (Static URL)"
Write-Host "3) PAC URL (Auto-config)"
$proxyChoice = Read-Host "Select an option (1-3)"
$proxyUrl = $null
if ($proxyChoice -eq '2' -or $proxyChoice -eq '3') { $proxyUrl = Read-Host "Enter the Proxy/PAC URL" }

# --- Section 3: Webex Credentials ---
if ([string]::IsNullOrWhiteSpace($Token)) { $Token = Read-Host "`nEnter Webex Bearer Token" }
if ([string]::IsNullOrWhiteSpace($OrgId)) { $OrgId = Read-Host "Enter Webex Org ID (Optional - Press Enter to skip)" }

$webexHeaders = @{ "Authorization"="Bearer $Token"; "Content-Type"="application/json"; "Accept"="application/json" }

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
            $userResp = Invoke-RestMethod -Uri $userUri -Method Get -Headers $webexHeaders
            if ($userResp.items.Count -gt 0) { 
                $tracker.PersonID = $userResp.items[0].id 
                $identityName = $userResp.items[0].displayName
                Write-Log 1 "Identity Resolved (User): $identityName" "Green"
            } else {
                Write-Host "  [!] User ($currentEmail) NOT found." -ForegroundColor Yellow
                $choice = Read-Host "      [C]ontinue (Skip Personalization), [S]kip Device, [Q]uit"
                if ($choice -eq 's') { $tracker.Reason = "User not found; skipped."; $executionResults += $tracker; continue }
                if ($choice -eq 'q') { exit }
            }
        } elseif ($currentWSName) { $identityName = $currentWSName }
        $tracker.IdentityName = $identityName

        if ($currentLoc) {
            $locUri = "https://webexapis.com/v1/locations?name=$([Uri]::EscapeDataString($currentLoc))"
            $locResp = Invoke-RestMethod -Uri $locUri -Method Get -Headers $webexHeaders
            $match = $locResp.items | Where-Object { $_.name -eq $currentLoc -or $_.id -eq $currentLoc }
            if ($match) { 
                $tracker.LocationID = $match[0].id
                Write-Log 1 "Location Resolved: $($match[0].name)" "Green"
            } else {
                Write-Host "  [!] Location ($currentLoc) NOT found." -ForegroundColor Yellow
                $choice = Read-Host "      [C]ontinue (Skip Calling), [S]kip Device, [Q]uit"
                if ($choice -eq 's') { $tracker.Reason = "Location not found; skipped."; $executionResults += $tracker; continue }
                if ($choice -eq 'q') { exit }
            }
        }
        
        if ($StopAt -eq 1) { $tracker.Success = "STOPPED"; $tracker.Reason = "Stopped after Phase 1"; $executionResults += $tracker; continue }

        # --- PHASE 2: Workspace Creation ---
        Write-Host "[2/5] Creating Workspace..." -ForegroundColor DarkCyan
        $wsBody = @{ displayName = $identityName; calling = @{ type = "webexEdgeForDevices" } }
        if ($OrgId) { $wsBody.Add("orgId", $OrgId) }
        $wsResp = Invoke-RestMethod -Uri "https://webexapis.com/v1/workspaces" -Method Post -Headers $webexHeaders -Body ($wsBody | ConvertTo-Json -Depth 10)
        $tracker.WorkspaceID = $wsResp.id
        $cResp = Invoke-RestMethod -Uri "https://webexapis.com/v1/devices/activationCode" -Method Post -Headers $webexHeaders -Body (@{ workspaceId=$tracker.WorkspaceID } | ConvertTo-Json)
        $workspaceCode = $cResp.code

        if ($StopAt -eq 2) { $tracker.Success = "STOPPED"; $tracker.Reason = "Stopped after Phase 2"; $executionResults += $tracker; continue }

        # --- PHASE 3: Local Device Handshake ---
        Write-Host "[3/5] Local Device Handshake..." -ForegroundColor DarkCyan
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        $null = Invoke-RestMethod -Uri "https://$($device.IP)/putxml" -Method Post -Headers $deviceXmlHeaders -Body "<Configuration><SystemUnit><Name>$identityName</Name></SystemUnit></Configuration>"
        $null = Invoke-RestMethod -Uri "https://$($device.IP)/putxml" -Method Post -Headers $deviceXmlHeaders -Body "<Command><SystemUnit><FirstTimeWizard><Stop></Stop></FirstTimeWizard></SystemUnit></Command>"

        if ($proxyChoice -ne '1') {
            $proxyXml = if ($proxyChoice -eq '2') { "<Configuration><NetworkServices><HTTP><Mode>HTTP+HTTPS</Mode><Proxy><Url>$proxyUrl</Url><Mode>Manual</Mode></Proxy></HTTP></NetworkServices></Configuration>" }
                        else { "<Configuration><NetworkServices><HTTP><Mode>HTTP+HTTPS</Mode><Proxy><PACUrl>$proxyUrl</PACUrl><Mode>PACURL</Mode></Proxy></HTTP></NetworkServices></Configuration>" }
            $null = Invoke-RestMethod -Uri "https://$($device.IP)/putxml" -Method Post -Headers $deviceXmlHeaders -Body $proxyXml
            Start-Countdown -Seconds 8 -Message "Waiting for HTTP restart"
        }

        $null = Invoke-RestMethod -Uri "https://$($device.IP)/putxml" -Method Post -Headers $deviceXmlHeaders -Body "<Command><Webex><Registration><Start><ActivationCode>$workspaceCode</ActivationCode><RegistrationType>Manual</RegistrationType><SecurityAction>NoAction</SecurityAction></Start></Registration></Webex></Command>"
        
        $wsRegistered = $false
        for ($i=1; $i -le 15; $i++) {
            Start-Sleep -Seconds 5
            try {
                [xml]$xmlStatus = Invoke-RestMethod -Uri $statusUri -Method Get -Headers $deviceXmlHeaders
                if ($xmlStatus.Status.Webex.Status -eq "Registered") { $wsRegistered = $true; break }
            } catch { }
        }
        if (-not $wsRegistered) { throw "Workspace Registration timed out." }

        if ($StopAt -eq 3) { $tracker.Success = "STOPPED"; $tracker.Reason = "Stopped after Phase 3"; $executionResults += $tracker; continue }

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
        } else { $tracker.Reason = "Registered (Shared)" }

        if ($StopAt -eq 4) { $tracker.Success = "STOPPED"; $tracker.Reason = "Stopped after Phase 4"; $executionResults += $tracker; continue }

        # --- PHASE 5: Cloud Conversion & Intelligent Calling Loop ---
        if ($tracker.LocationID -ne "N/A" -and $currentExt) {
            Write-Host "[5/5] Enabling Webex Calling..." -ForegroundColor DarkCyan
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
            $null = Invoke-RestMethod -Uri "https://$($device.IP)/putxml" -Method Post -Headers $deviceXmlHeaders -Body "<Command><Webex><Registration><ConvertToCloud><Confirm>Yes</Confirm></ConvertToCloud></Registration></Webex></Command>"
            
            Start-Countdown -Seconds 20 -Message "Initial Cloud Conversion Sync"

            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $originalCallback
            $updateBody = @{ displayName = $identityName; calling = @{ type = "webexCalling"; webexCalling = @{ extension = $currentExt; locationId = $tracker.LocationID } } }
            $updateUri = "https://webexapis.com/v1/workspaces/$($tracker.WorkspaceID)"
            $jsonPayload = $updateBody | ConvertTo-Json -Depth 10

            for ($attempt = 1; $attempt -le 4; $attempt++) {
                if ($attempt -eq 4) { Start-Countdown -Seconds 120 -Message "Finalizing Cloud State (Fallback Delay)" }
                elseif ($attempt -gt 1) { Start-Sleep -Seconds 5; Write-Log 1 "Retrying Calling (Attempt $attempt/3)..." "Yellow" }

                try {
                    $response = Invoke-WebRequest -Uri $updateUri -Method Put -Headers $webexHeaders -Body $jsonPayload -UseBasicParsing
                    $tracker.HttpStatus = [int]$response.StatusCode
                    $tracker.Reason += " & Calling Enabled"; break
                } catch {
                    $tracker.HttpStatus = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "Err" }
                    if ($attempt -eq 4) { $tracker.Reason += " (Converted-NoCalling: $(Get-WebexError $_))" }
                }
            }
        }

        $tracker.Success = "SUCCESS"; Write-Host "Success!" -ForegroundColor Green

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
