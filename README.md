# Cisco RoomOS Bulk Cloud Onboarding Tool

This PowerShell automation tool is designed for Customer Delivery Architects and Administrators to perform bulk registration of on-net Cisco RoomOS devices (brand new out-of-box OR factory-reset) to the Webex Cloud. It bridges the gap between local device administration and Webex Control Hub management, automating identity resolution, cloud provisioning, and Webex Calling enablement (extension only). 

**IMPORTANT: Workspace Semi-Personalization is done using the Device <b>XCOMMAND</b> enabling you to keep the Workspace visible and a seperate user and device dial-plan. Workspaces will not show any scheduling as active, but the user's calender will sync as if a true personal device. If the end-state is to move the device under a User (which is the standard deployment based on Cisco Documentation) the following WebexAPI must be run: https://developer.webex.com/devices/docs/api/v1/workspace-personalization/personalize-a-workspace. Note the previous Calling Config will follow the device, despite showing the User's dialplan in Control Hub. 

## 🚀 Key Features

*   **Identity Resolution**: Automatically resolves Webex User Emails to `personId` and Location Names to `locationId`.
*   **Selective SSL Validation**: Uses standard secure trust chains for Webex Cloud APIs and dynamically toggles to bypass mode for local device IP connections.
*   **XML-Based Local Execution**: Utilizes the `/putxml` API for local device commands to ensure registration stability and naming integrity.
*   **Webex Calling Automation**: Handles the transition to Cloud Calling mode and assigns Extensions/Locations in a single flow.
*   **Race-Condition Prevention**: Includes optimized countdown timers (up to 120 seconds) to allow the Webex Cloud and local hardware to synchronize states.
*   **Verbose Debugging & Audit Logs**: Features a 3-level debug system and generates timestamped CSV logs for every execution.

---

## 🛠 Prerequisites

### 1. Webex Developer Token
You must obtain a Bearer Token from [developer.webex.com](https://developer.webex.com). Ensure your token has the following scopes:
*   `spark:workspaces_write` (Create and update workspaces)
*   `spark:people_read` (Resolve user emails)
*   `spark:devices_write` (Generate activation codes)
*   `spark:locations_read` (Resolve calling location names)

### 2. Network Requirements
*   The machine running the script must have HTTPS (443) access to the Webex Cloud APIs (`webexapis.com`).
*   The machine must have HTTPS access to the local IP addresses of the Cisco devices, the set username and password.
*   PowerShell 5.1 or higher.

### 3. How To Use
  * Basic operation:<br>
   Simply run the script (all 5 phases) in a new PowerShell window: .\BCOT_Combined.ps1<br><br>
   
  * Advanced options:<br>
   Use flags to stop script at a certain Phase if you choose:<br>
   Stop after Lookups: .\BCOT_Combined.ps1 -StopAt 1<br>
   Stop after Workspace Creation: .\BCOT_Combined.ps1 -StopAt 2<br>
   Stop after Webex Edge Registration: .\BCOT_Combined.ps1 -StopAt 3<br>
   Stop after Webex Edge Semi-Peronsonalization: .\BCOT_Combined.ps1 -StopAt 4<br>
   Fully Automated using CSV: .\BCOT_Combined.ps1 -CSVPath "C:\devices.csv" -Token "YOUR_TOKEN" -StopAt 4<br>

---

## 📋 CSV Configuration

If using **Bulk Mode**, create a CSV file (e.g., `devices.csv`) with the following headers. The script is case-sensitive regarding these headers.

| Header | Description | Required |
| :--- | :--- | :--- |
| **IP** | Local IP address of the RoomOS device. | Yes |
| **Username** | Local admin username for the device. | Yes |
| **Password** | Local admin password for the device. | Yes |
| **Email** | Webex User Email for Personalization. | Optional |
| **Location** | Friendly Name of the Webex Calling Location. | Optional |
| **Extension** | Extension to assign to the Workspace. | Optional |
| **WorkspaceName** | Custom name for Shared Workspaces. | Optional |

### Sample `devices.csv`
```csv
IP,Username,Password,Email,Location,Extension,WorkspaceName
10.88.145.110,admin,Cisco123!,,,,
10.88.145.111,admin,Cisco123!,,,,Huddle Room Alpha
10.88.145.112,admin,Cisco123!,psmith@example.com,,,
10.88.145.113,admin,Cisco123!,,Richardson,5501,Conference Room 4
10.88.145.114,admin,Cisco123!,mjones@example.com,Richardson,5502,
```

### Scenario Breakdown:

*   **Row 1 (Basic Shared)**: Only IP and credentials. Creates a Workspace named WS-10.88.145.110. No calling or personalization.
*   **Row 2 (Shared with Custom Name)**: No email provided. Creates a Workspace and renames the device to Huddle Room Alpha.
*   **Row 3 (Personalization Only)**: Email provided. Resolves the user's name (e.g., "Peter Smith"), creates the workspace as "Peter Smith", and flips the device to Personal Mode.
*   **Row 4 (Shared with Webex Calling)**: No email. Renames the workspace to Conference Room 4, converts the device to Cloud mode, and assigns extension 5501 in the Richardson location.
*   **Row 5 (Personalization with Webex Calling)**: Email provided. Names the device after the user, personalizes it, converts it to Cloud mode, and assigns extension 5502 in the Richardson location.  

---

## 🔍 Process Breakdown

The script executes in five distinct phases:

### Phase 1: Identity Resolution
The script resolves friendly inputs into technical IDs. It fetches the `personId` and `displayName` from the People API and the `locationId` from the Locations API.

### Phase 2: Cloud Provisioning
A Webex Workspace is created using the resolved identity. If personalized, it uses the User's name; if shared, it uses the `WorkspaceName` (optional) or defaults to `WS-IP`. An activation code is then generated.

### Phase 3: Local Device Handshake
The script connects to the local device IP and:
1.  Sets the `SystemUnit Name` to match the Cloud identity.
2.  Turn OFF the **First Time Setup Wizard**.
3.  Applies **PacURL/Manual Proxy Settings** (if provided/optional).
4.  Initiates the registration using the cloud-provided activation code.

**Note: If a PACURL is needed instead of Manual Proxy, use PowerShell script named BCOT_PACUrl.ps1.

### Phase 4: Personalization (Optional)
If an email was provided, the script flips the device from "Shared" to "Personal" mode. A 15-second safety delay is triggered to allow the device to reboot its registration services.

### Phase 5: Full-Cloud Registration & Calling Enablement (Optional)
The device is sent a `ConvertToCloud` XML command (at which point the device will restart).

If a Location and Extension were provided:
1.  **2-Minute Safety Delay**: The script tries to convert the Workspace calling type 3 times if possible and waits for the cloud calling sub-system to initialize for 120s if needed. Will prompt to continue, skip or quit if the API still fails. 
2.  A `PUT` request is sent to the Workspace API to assign the extension and location, explicitly locking in the `displayName`.

---

## ⚙️ Debug Log Levels

You can toggle the verbosity of the script by changing the variable "$LogLevel" at the top of the `.ps1` file:

*   **Level 1 (Basic)**: Shows standard progress and success/fail results.
*   **Level 2 (Technical)**: Adds API URIs, HTTP Methods, and Status Codes.
*   **Level 3 (Verbose)**: Adds full JSON/XML request bodies and full API response payloads. Recommended for initial troubleshooting.

---

## 📊 Logging & Debugging

Every execution generates a CSV log file: `ExecutionLog_YYYYMMDD_HHMMSS.csv`.
This log captures:
*   **Success/Fail** status.
*   **Resolved IDs** (Workspace, Person, Location).
*   **HTTP Status Codes** for the final calling enablement.
*   **Detailed Error Reasons** including raw API error messages from Cisco.<br>
<br><br>
However when the LogLevel=3 you will get an extra `VerboseErrorLog_YYYYMMDD_HHMMSS.txt`. 

## 🛠 Troubleshooting Guide

### 1. Connection & Security Issues

| Symptom | Root Cause | Resolution |
| :--- | :--- | :--- |
| **"The underlying connection was closed: An unexpected error occurred on a send."** | **TLS/SSL Conflict**: Forcing a global SSL bypass (`ServerCertificateValidationCallback = { $true }`) often causes corporate proxies or the Webex API to drop the connection. | **Selective SSL Toggling**: The script is designed to use standard Windows trust chains for `webexapis.com` and only bypasses validation for local device IPs. Ensure you are using the `GA 1.0` logic which resets the callback to `$null` before cloud calls. |
| **Security Warning: "Script Execution Risk"** | **IE Engine Dependency**: `Invoke-WebRequest` defaults to using the Internet Explorer engine to parse responses, which triggers a security warning in modern environments. | **Basic Parsing**: The script utilizes the `-UseBasicParsing` switch for all web requests to bypass the IE engine and suppress this warning. |
| **401 Unauthorized Error** | **Token Expiration**: Webex Developer Personal Access Tokens expire every 12 hours. | **Refresh Token**: Obtain a new token from the [Webex Developer Portal](https://developer.webex.com) and restart the script. |

### 2. Naming & Identity Issues

| Symptom | Root Cause | Resolution |
| :--- | :--- | :--- |
| **Workspace Name reverts to IP address after Calling Enablement.** | **API Overwrite**: The Webex `PUT` method is a full object replacement. If the `displayName` is missing from the Phase 5 payload, the cloud reverts the name to the original value. | **Name Persistence**: The script captures the `identityName` in Phase 1 and explicitly sends it in the Phase 5 `PUT` request to "lock" the name. |
| **Personalized device does not show the User's name.** | **Race Condition**: The device was sent a rename command before the cloud finished the personalization handshake. | **Identity First Strategy**: The script resolves the User's name first and creates the Workspace with that name *before* the device ever registers, ensuring naming consistency. |
| **"Variable reference is not valid" (Parser Error)** | **Scope Conflict**: PowerShell interprets `$Message:` as a drive scope (like `env:`). | **Variable Delimiters**: The script uses `${Message}` syntax in the countdown function to prevent the parser from misinterpreting colons. |

### 3. Registration & Calling Failures

| Symptom | Root Cause | Resolution |
| :--- | :--- | :--- |
| **"Workspace Registration timed out"** | **Cloud Latency**: The device may take longer than 60 seconds to establish a secure websocket with the Webex Cloud. | **Increased Polling**: The script is configured for 15-20 polling attempts (up to 100 seconds) to allow for slow network handshakes. |
| **Webex Calling Enablement Fails (HTTP 400)** | **Mode Mismatch**: The device must be in "Cloud" mode before calling features can be assigned via API. | **Cloud Conversion**: The script sends the `ConvertToCloud` XML command and waits for a **120-second safety delay** to ensure the calling sub-system is ready. |
| **Webex Calling Enablement Fails (HTTP 409/Conflict)** | **Duplicate Extension**: The extension provided is already assigned to another user or workspace in that location. | **Audit Extensions**: Check Webex Control Hub for extension conflicts and update your CSV with a unique value. |
| **Device stuck on Setup Wizard** | **API Blocked**: The device API may not accept certain configurations while the physical screen is on the First Time Wizard. | **Wizard Bypass**: The script sends a `FirstTimeWizard Stop` command as the very first local interaction to clear the API path. |

---

## 💡 Pro-Tips for Success

1.  **Use Debug Level 3**: If a device fails, set `$DebugLevel = 3`. This will print the exact JSON body sent to Webex and the raw error response returned. This is the fastest way to see if a failure is due to a "Duplicate Extension" or "Invalid Location ID."
2.  **Verify CSV Headers**: The script is case-sensitive. Ensure your headers are exactly: `IP,Username,Password,Email,Location,Extension,WorkspaceName`.
3.  **Location Names**: Ensure the `Location` name in your CSV matches the name in Control Hub **exactly** (including spaces). The script performs an exact match search to prevent assigning devices to the wrong site.
4.  **The 2-Minute Rule**: Do not decrease the 120-second timer in Phase 5. Webex Calling registration involves multiple back-end microservices; cutting this timer short is the #1 cause of calling enablement failures.

---

##  Sample Output
<img width="1344" height="928" alt="image" src="https://github.com/user-attachments/assets/bb1bc998-7654-4ae3-9c17-9bf73da0111b" />

---

##  Logic Diagram:
<img width="2638" height="5510" alt="image" src="https://github.com/user-attachments/assets/f21f308e-8d5e-4dd6-afb6-4b44be8051a3" />

---
Note: Contains AI-generated Code, use at own discretion.
***
