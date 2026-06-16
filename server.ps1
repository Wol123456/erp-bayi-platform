# ERP Bayi Platform - HTTP Server + Mail Agent
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File server.ps1

$port = 5500
$root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Users\LT-1033\Desktop\Agent\erp-bayi-platform' }

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()
Write-Host "Server started on http://localhost:$port" -ForegroundColor Green

function Send-Response($ctx, $code, $contentType, $body) {
    $ctx.Response.StatusCode = $code
    $ctx.Response.ContentType = $contentType
    $ctx.Response.Headers.Add("Access-Control-Allow-Origin", "*")
    $ctx.Response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
    $ctx.Response.Headers.Add("Access-Control-Allow-Headers", "Content-Type")
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.Close()
}

function Handle-SendEmail($ctx) {
    try {
        $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)
        $jsonBody = $reader.ReadToEnd()
        $reader.Close()

        $data = $jsonBody | ConvertFrom-Json

        $smtpHost     = $data.smtp.host
        $smtpPort     = [int]$data.smtp.port
        $smtpUser     = $data.smtp.user
        $smtpPass     = $data.smtp.pass
        $smtpSsl      = [bool]$data.smtp.ssl
        $fromName     = $data.smtp.fromName
        $fromEmail    = $data.smtp.fromEmail
        $subject      = $data.subject
        $bodyTemplate = $data.body
        $recipients   = $data.recipients  # array of {email, company, city}
        $delayMs      = if ($data.delayMs) { [int]$data.delayMs } else { 1500 }

        $smtp = New-Object System.Net.Mail.SmtpClient($smtpHost, $smtpPort)
        $smtp.EnableSsl = $smtpSsl
        $smtp.Credentials = New-Object System.Net.NetworkCredential($smtpUser, $smtpPass)
        $smtp.Timeout = 30000

        $sent = 0
        $failed = 0
        $errors = @()

        foreach ($r in $recipients) {
            if (-not $r.email -or $r.email -eq "") { continue }

            # Merge template variables
            $personalBody = $bodyTemplate `
                -replace '\{firma_adi\}', $r.company `
                -replace '\{sehir\}',     $r.city `
                -replace '\{ilce\}',      $r.district `
                -replace '\{yetkili\}',   $r.contact

            $personalSubject = $subject `
                -replace '\{firma_adi\}', $r.company `
                -replace '\{sehir\}',     $r.city

            try {
                $msg = New-Object System.Net.Mail.MailMessage
                $msg.From = New-Object System.Net.Mail.MailAddress($fromEmail, $fromName, [System.Text.Encoding]::UTF8)
                $msg.To.Add($r.email)
                $msg.Subject = $personalSubject
                $msg.SubjectEncoding = [System.Text.Encoding]::UTF8
                $msg.Body = $personalBody
                $msg.BodyEncoding = [System.Text.Encoding]::UTF8
                $msg.IsBodyHtml = $false

                $smtp.Send($msg)
                $msg.Dispose()
                $sent++
                Write-Host "  SENT -> $($r.email) ($($r.company))" -ForegroundColor Cyan
            }
            catch {
                $failed++
                $errors += "$($r.email): $($_.Exception.Message)"
                Write-Host "  FAIL -> $($r.email): $($_.Exception.Message)" -ForegroundColor Red
            }

            if ($delayMs -gt 0) { Start-Sleep -Milliseconds $delayMs }
        }

        $smtp.Dispose()

        $result = @{ sent = $sent; failed = $failed; errors = $errors } | ConvertTo-Json
        Send-Response $ctx 200 "application/json; charset=utf-8" $result
    }
    catch {
        $err = @{ error = $_.Exception.Message } | ConvertTo-Json
        Send-Response $ctx 500 "application/json; charset=utf-8" $err
    }
}

Write-Host "Ready. Press Ctrl+C to stop." -ForegroundColor Yellow

while ($listener.IsListening) {
    try {
        $ctx = $listener.GetContext()
        $method = $ctx.Request.HttpMethod
        $path   = $ctx.Request.Url.LocalPath

        # CORS preflight
        if ($method -eq "OPTIONS") {
            Send-Response $ctx 204 "text/plain" ""
            continue
        }

        # API endpoint
        if ($method -eq "POST" -and $path -eq "/api/send-email") {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] POST /api/send-email" -ForegroundColor Yellow
            Handle-SendEmail $ctx
            continue
        }

        # Static files
        $filePath = Join-Path $root ($path.TrimStart('/'))
        if ($path -eq "/" -or $path -eq "") { $filePath = Join-Path $root "index.html" }

        if (Test-Path $filePath -PathType Leaf) {
            $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
            $mime = switch ($ext) {
                ".html" { "text/html; charset=utf-8" }
                ".css"  { "text/css; charset=utf-8" }
                ".js"   { "application/javascript; charset=utf-8" }
                ".json" { "application/json; charset=utf-8" }
                default { "application/octet-stream" }
            }
            $bytes = [System.IO.File]::ReadAllBytes($filePath)
            $ctx.Response.StatusCode = 200
            $ctx.Response.ContentType = $mime
            $ctx.Response.Headers.Add("Access-Control-Allow-Origin", "*")
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $ctx.Response.Close()
        }
        else {
            Send-Response $ctx 404 "text/plain" "Not Found: $path"
        }
    }
    catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}
