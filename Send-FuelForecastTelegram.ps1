# Send-FuelForecastTelegram.ps1
# PH Daily Fuel Forecast - dynamic estimate based on Brent crude + USD/PHP
# Schedule via Windows Task Scheduler (hourly or 3x daily)

$botToken = if ($env:TELEGRAM_BOT_TOKEN) { $env:TELEGRAM_BOT_TOKEN } else { "YOUR_BOT_TOKEN_HERE" }
$chatId   = if ($env:TELEGRAM_CHAT_ID)   { $env:TELEGRAM_CHAT_ID }   else { "@BorderlineDailyFuelForecast" }

$peso     = [char]0x20B1
$fuel     = [char]0x26FD
$announce = [char]::ConvertFromUtf32(0x1F4E2)
$clock    = [char]::ConvertFromUtf32(0x1F553)
$arrowUp  = [char]0x2B06
$arrowDn  = [char]0x2B07
$arrowFl  = [char]0x27A1

# --- Use PHT timezone (UTC+8) for all date calculations ---
$phtNow = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, "Singapore Standard Time")

# --- Confidence level based on day of week ---
$today = $phtNow.DayOfWeek
$confidence = switch ($today) {
    "Monday"    { "Low" }
    "Tuesday"   { "Low" }
    "Wednesday" { "Medium" }
    "Thursday"  { "Medium" }
    "Friday"    { "High" }
    "Saturday"  { "High" }
    "Sunday"    { "High" }
}

# --- Next Tuesday date ---
$daysUntilTuesday = (([int][System.DayOfWeek]::Tuesday - [int]$phtNow.DayOfWeek) + 7) % 7
if ($daysUntilTuesday -eq 0) { $daysUntilTuesday = 7 }
$nextTuesday = $phtNow.AddDays($daysUntilTuesday).ToString("MMM dd, yyyy")

# --- Scrape latest official DOE adjustment from GMA News ---
# Fallback: last known official adjustment — update manually each Tuesday
$fallbackDate     = "Mar 24, 2026"
$fallbackDiesel   = "17.80"
$fallbackGasoline = "10.70"
$fallbackKerosene = "21.90"
$fallbackDir      = $arrowUp

$officialSection = @"
Official Adjustment ($fallbackDate)
Diesel:   $fallbackDir ${peso}$fallbackDiesel/L
Gasoline: $fallbackDir ${peso}$fallbackGasoline/L
Kerosene: $fallbackDir ${peso}$fallbackKerosene/L
"@
try {
    $searchUrl  = "https://www.gmanetwork.com/news/search/?q=pump+prices+tuesday"
    $searchResp = Invoke-WebRequest -Uri $searchUrl -UseBasicParsing -TimeoutSec 10
    $searchHtml = $searchResp.Content

    # Extract latest article URL from search results
    $articleUrl = $null
    if ($searchHtml -match 'href="(https://www\.gmanetwork\.com/news/[^"]*pump-price[^"]*)"') {
        $articleUrl = $matches[1]
    }

    if ($articleUrl) {
        $articleResp = Invoke-WebRequest -Uri $articleUrl -UseBasicParsing -TimeoutSec 10
        $articleHtml = $articleResp.Content

        # Extract adjustment date
        $adjDate = if ($articleHtml -match 'Tuesday,?\s+([\w]+\s+\d+,?\s+\d{4})') { $matches[1] } else { "latest" }

        # Extract diesel
        $diesel = if ($articleHtml -match 'diesel[^0-9]*([0-9]+\.[0-9]+)') { $matches[1] } else { "N/A" }

        # Extract gasoline
        $gasoline = if ($articleHtml -match 'gasoline[^0-9]*([0-9]+\.[0-9]+)') { $matches[1] } else { "N/A" }

        # Extract kerosene
        $kerosene = if ($articleHtml -match 'kerosene[^0-9]*([0-9]+\.[0-9]+)') { $matches[1] } else { "N/A" }

        # Direction — check if article says "up" or "down"
        $isHike = $articleHtml -match 'hike|increas|up'
        $adjDir = if ($isHike) { $arrowUp } else { $arrowDn }

        $officialSection = @"
Official Adjustment ($adjDate)
Diesel:   $adjDir ${peso}$diesel/L
Gasoline: $adjDir ${peso}$gasoline/L
Kerosene: $adjDir ${peso}$kerosene/L
"@
    }
} catch {
    # Keep fallback values already set above
}

# --- Get USD/PHP exchange rate ---
$usdPhp = $null
try {
    $fxResponse = Invoke-RestMethod -Uri "https://open.er-api.com/v6/latest/USD" -TimeoutSec 10
    $usdPhp = [math]::Round($fxResponse.rates.PHP, 2)
} catch {
    $usdPhp = 56.00  # fallback
}

# --- Get Brent Crude price ---
$brentPrice = $null
$brentChange = $null
try {
    $brentResponse = Invoke-RestMethod -Uri "https://query1.finance.yahoo.com/v8/finance/chart/BZ=F?interval=1d&range=5d" -TimeoutSec 10
    $closes = $brentResponse.chart.result[0].indicators.quote[0].close | Where-Object { $_ -ne $null }
    if ($closes.Count -ge 2) {
        $brentPrice  = [math]::Round($closes[-1], 2)
        $brentPrev   = [math]::Round($closes[-2], 2)
        $brentChange = [math]::Round($brentPrice - $brentPrev, 2)
    } else {
        $brentPrice  = 75.00
        $brentChange = 0
    }
} catch {
    $brentPrice  = 75.00  # fallback
    $brentChange = 0
}

# --- Estimate next adjustment ---
# Rule of thumb: $1/barrel change ~ PHP 0.35-0.45/L after forex adjustment
# Adjusted by peso rate vs baseline of 56.00
$baselinePhp    = 56.00
$forexFactor    = $usdPhp / $baselinePhp
$barrelToLiter  = 159
$rawEstimate    = ($brentChange / $barrelToLiter) * $usdPhp * $forexFactor

# MOPS dampener: DOE uses weekly average, so extreme single-day moves get smoothed
# Extreme move (>$6 change): apply 0.35x — only 1-2 days drove the whole week
# Moderate move ($3-$6): apply 0.65x — partially sustained
# Normal move (<$3): apply full estimate
$absChange = [math]::Abs($brentChange)
$dampener  = if ($absChange -gt 6) { 0.35 } elseif ($absChange -gt 3) { 0.65 } else { 1.0 }
$estimatePerL = [math]::Round($rawEstimate * $dampener, 2)

# Apply fuel-type multipliers (diesel more sensitive than gasoline)
# Hard cap: diesel ±8, gasoline ±6, kerosene ±7 (realistic DOE weekly max)
$dieselEst   = [math]::Max(-8, [math]::Min(8,  [math]::Round($estimatePerL * 1.1, 2)))
$gasolineEst = [math]::Max(-6, [math]::Min(6,  [math]::Round($estimatePerL * 0.9, 2)))
$keroseneEst = [math]::Max(-7, [math]::Min(7,  [math]::Round($estimatePerL * 1.0, 2)))

# Direction arrows
function Get-Dir($val) {
    if ($val -gt 0) { return $arrowUp } elseif ($val -lt 0) { return $arrowDn } else { return $arrowFl }
}
function Get-Sign($val) {
    if ($val -gt 0) { return "+" } else { return "" }
}

$dieselDir   = Get-Dir $dieselEst
$gasolineDir = Get-Dir $gasolineEst
$keroseneDir = Get-Dir $keroseneEst

# Trend summary
$trend = if ($estimatePerL -gt 3)       { "Still increasing" }
         elseif ($estimatePerL -gt 0)   { "Slight increase" }
         elseif ($estimatePerL -eq 0)   { "Flat / Stable" }
         elseif ($estimatePerL -gt -3)  { "Slight rollback" }
         else                           { "Big rollback" }

# Advice
$advice = if ($estimatePerL -gt 3)      { "Gas up now - prices going up" }
          elseif ($estimatePerL -gt 0)  { "Gas up soon - slight increase ahead" }
          elseif ($estimatePerL -eq 0)  { "No rush - prices stable" }
          else                          { "You can wait - rollback expected" }

# Reason
$absChange   = [math]::Abs($brentChange)
$oilDir      = if ($brentChange -gt 0) { $arrowUp } else { $arrowDn }
$pesoDir     = if ($usdPhp -gt $baselinePhp) { "weak" } else { "strong" }
$reason1     = "Brent: $oilDir `$$brentPrice/bbl (${absChange}/day)"
$reason2     = "USD/PHP: $usdPhp | Peso $pesoDir"

Write-Host "DEBUG >> USD/PHP: $usdPhp | Brent: $brentPrice | Change: $brentChange | EstPerL: $estimatePerL" -ForegroundColor Yellow

$dateLabel = $phtNow.ToString("MMM dd, yyyy")
$timeLabel = $phtNow.ToString("hh:mm tt")

$message = @"
$fuel Borderline Daily Fuel Forecast
$clock $dateLabel | $timeLabel

$officialSection

$announce Next Week Estimate ($nextTuesday)
Diesel:   $dieselDir $(Get-Sign $dieselEst)${peso}$dieselEst/L
Gasoline: $gasolineDir $(Get-Sign $gasolineEst)${peso}$gasolineEst/L
Kerosene: $keroseneDir $(Get-Sign $keroseneEst)${peso}$keroseneEst/L

Trend: $trend
Confidence: $confidence
Advice: $advice

$reason1
$reason2
"@

# --- Send to Telegram ---
try {
    $uri  = "https://api.telegram.org/bot$botToken/sendMessage"
    $body = @{ chat_id = $chatId; text = $message } | ConvertTo-Json
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json; charset=utf-8" -Body $bodyBytes
    Write-Host "Fuel forecast sent. Brent: `$$brentPrice | USD/PHP: $usdPhp" -ForegroundColor Cyan
} catch {
    Write-Warning "Failed to send Telegram message: $_"
}
