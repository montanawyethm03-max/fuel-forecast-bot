# fuel-forecast-bot

# ⛽ Borderline Daily Fuel Forecast Bot

Automated Philippine fuel price forecast bot that sends daily updates to a Telegram channel.

## What it does
- Runs every 2 hours via GitHub Actions (no local machine needed)
- Fetches live **Brent crude oil price** (Yahoo Finance)
- Fetches live **USD/PHP exchange rate** (open.er-api.com)
- Scrapes latest **official DOE adjustment** from GMA News
- Calculates estimated **next Tuesday's adjustment** using MOPS-based formula
- Posts formatted report to **Telegram channel**

## How the forecast works
Uses the DOE's own methodology:
1. Brent crude daily change → converted to PHP/liter
2. Adjusted by current USD/PHP exchange rate
3. MOPS dampener applied (extreme single-day moves get smoothed)
4. Hard cap applied (realistic DOE weekly max)
5. Confidence level auto-adjusts by day of week (Low Mon–Tue, Medium Wed–Thu, High Fri–Sun)

## Telegram Channel
📲 [t.me/BorderlineDailyFuelForecast](https://t.me/BorderlineDailyFuelForecast)

## Schedule
Runs every 2 hours via GitHub Actions cron.

## Maintenance
Every Tuesday after DOE announces official adjustment, update these lines in `Send-FuelForecastTelegram.ps1`:
```powershell
$fallbackDate     = "Mar 31, 2026"
$fallbackDiesel   = "X.XX"
$fallbackGasoline = "X.XX"
$fallbackKerosene = "X.XX"


Data Sources
Brent Crude: Yahoo Finance (BZ=F)
USD/PHP Rate: open.er-api.com
Official Adjustment: GMA News (scraped weekly)
Methodology reference: Philippine DOE / MOPS


