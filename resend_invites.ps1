# resend_invites.ps1

# 1. Load Environment Variables
$SUPABASE_URL = $env:SUPABASE_URL
$SERVICE_KEY = $env:SUPABASE_SERVICE_ROLE_KEY
$DB_URL = $env:SUPABASE_DB_URL

if (-not $SUPABASE_URL -or -not $SERVICE_KEY -or -not $DB_URL) {
    Write-Host "❌ ERROR: Missing environment variables." -ForegroundColor Red
    Write-Host "Please set SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, and SUPABASE_DB_URL before running."
    exit
}

Write-Host "Fetching pending members from the database..." -ForegroundColor Cyan

# 2. Query the database for members who HAVEN'T confirmed their account
# We only want active members whose email_confirmed_at is null
$sql = @"
SELECT m.email 
FROM public.members m 
JOIN auth.users au ON au.id = m.auth_user_id 
WHERE au.email_confirmed_at IS NULL 
  AND m.status = 'Active'
  AND m.email IS NOT NULL;
"@

# Run the query using psql (-t removes headers, -A removes padding)
$pending_emails = psql $DB_URL -t -A -c $sql

if ([string]::IsNullOrWhiteSpace($pending_emails)) {
    Write-Host "✅ No pending members found. Everyone is confirmed!" -ForegroundColor Green
    exit
}

# Clean up the output into an array
$email_list = $pending_emails -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
$total = $email_list.Count

Write-Host "Found $total members who need a new invitation." -ForegroundColor Yellow
$confirm = Read-Host "Type 'RESEND' to confirm you want to send $total invitations"
if ($confirm -ne "RESEND") {
    Write-Host "Aborted."
    exit
}

# 3. Setup API Headers
$headers = @{
    "apikey"        = $SERVICE_KEY
    "Authorization" = "Bearer $SERVICE_KEY"
    "Content-Type"  = "application/json"
}

# 4. Loop and Send
$success = 0
$failed = 0
$logFile = "resend-log-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"

# Create log file with headers
"Email,Status,Detail" | Out-File -FilePath $logFile -Encoding utf8

Write-Host "`nStarting batch resend..." -ForegroundColor Cyan
Write-Host "=================================================="

for ($i = 0; $i -lt $total; $i++) {
    $email = $email_list[$i]
    $percent = [math]::Round((($i + 1) / $total) * 100)
    
    Write-Host "[$($i + 1)/$total] ($percent%) Sending to: $email... " -NoNewline
    
    $body = @{ email = $email } | ConvertTo-Json
    
    try {
        # Using /auth/v1/invite to safely resend to an existing unconfirmed user
        $response = Invoke-RestMethod -Uri "$SUPABASE_URL/auth/v1/invite" `
            -Method Post `
            -Headers $headers `
            -Body $body `
            -ErrorAction Stop
            
        Write-Host "✅ Success" -ForegroundColor Green
        "$email,Success,Invited" | Out-File -FilePath $logFile -Append -Encoding utf8
        $success++
    } 
    catch {
        $errorMsg = $_.Exception.Message
        if ($_.ErrorDetails.Message) {
            # Try to extract the JSON error message from Supabase
            try {
                $errJson = $_.ErrorDetails.Message | ConvertFrom-Json
                $errorMsg = $errJson.msg
                if (-not $errorMsg) { $errorMsg = $errJson.message }
            } catch {}
        }
        
        Write-Host "❌ Failed: $errorMsg" -ForegroundColor Red
        "$email,Failed,$errorMsg" | Out-File -FilePath $logFile -Append -Encoding utf8
        $failed++
    }
    
    # Rate limit: 1 second between requests
    if ($i -lt ($total - 1)) {
        Start-Sleep -Seconds 1
    }
}

Write-Host "=================================================="
Write-Host "Done!" -ForegroundColor Cyan
Write-Host "✅ Success: $success" -ForegroundColor Green
Write-Host "❌ Failed:  $failed" -ForegroundColor Red
Write-Host "📄 Log saved to: $logFile" -ForegroundColor Yellow