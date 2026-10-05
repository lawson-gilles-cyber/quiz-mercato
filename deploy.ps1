# =====================================================================
# QUIZ MERCATO — Script de déploiement (v2)
# =====================================================================
# 1. Déplace les fichiers téléchargés vers les bons répertoires
#    -> SAUF api.js (il contient ta clé ; tu le gères à la main)
# 2. Vérifie la syntaxe des fichiers JS avec `node --check`
#    (équivalent d'un "build" pour un projet statique Vanilla JS :
#     rien à compiler, mais on valide que le JS ne casse pas)
# 3. Commit + push (Cloudflare redéploie automatiquement)
#
# UTILISATION :
#   cd "C:\Users\gille\Downloads\quiz-mercato"
#   powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -Message "Ton message"
# =====================================================================

param(
  [string]$Message = "Mise a jour Quiz Mercato"
)

$ErrorActionPreference = "Stop"

$Repo      = Get-Location
$Downloads = "C:\Users\gille\Downloads"

# -------------------------------------------------------------------
# 1. RANGEMENT (api.js volontairement EXCLU)
# -------------------------------------------------------------------
Write-Host "=== 1. Rangement des fichiers telecharges ===" -ForegroundColor Cyan

$map = @{
  "index.html"              = ""
  "admin.html"              = ""
  "README.md"               = ""
  "deploy.ps1"              = ""
  "01_schema.sql"           = "db"
  "02_rpc_auctions.sql"     = "db"
  "03_rls.sql"              = "db"
  "04_cron.sql"             = "db"
  "05_admin.sql"            = "db"
  "06_import_players.sql"   = "db"
  "07_attributes.sql"       = "db"
  "08_seed_attributes.sql"  = "db"
  "09_squad_rules.sql"      = "db"
  "10_points_system.sql"    = "db"
  "11_trades.sql"           = "db"
  "12_commissions.sql"      = "db"
  "close-auctions.ts"       = "edge"
}

foreach ($sub in @("js","db","edge")) {
  $path = Join-Path $Repo $sub
  if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path | Out-Null }
}

$moved = 0
foreach ($file in $map.Keys) {
  $src = Join-Path $Downloads $file
  if (Test-Path $src) {
    $destDir = if ($map[$file] -eq "") { $Repo } else { Join-Path $Repo $map[$file] }
    Move-Item -Path $src -Destination (Join-Path $destDir $file) -Force
    $where = if ($map[$file]) { $map[$file] } else { "racine" }
    Write-Host "  deplace : $file -> $where" -ForegroundColor Green
    $moved++
  }
}

if (Test-Path (Join-Path $Downloads "api.js")) {
  Write-Host "  NOTE : api.js detecte dans Downloads mais NON deplace (a gerer a la main avec ta cle)." -ForegroundColor Yellow
}

if ($moved -eq 0) {
  Write-Host "  Aucun fichier a deplacer (deja ranges ?). On continue." -ForegroundColor Yellow
} else {
  Write-Host "  $moved fichier(s) range(s)." -ForegroundColor Cyan
}

# -------------------------------------------------------------------
# 2. VERIFICATION SYNTAXE JS (le "build" d'un projet statique)
# -------------------------------------------------------------------
Write-Host "`n=== 2. Verification syntaxe JS (node --check) ===" -ForegroundColor Cyan

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
  Write-Host "  node introuvable : verification sautee. (Installe Node.js pour activer ce controle.)" -ForegroundColor Yellow
} else {
  $jsError = $false

  if (Test-Path "js\api.js") {
    $tmp = [System.IO.Path]::GetTempFileName() + ".mjs"
    Copy-Item "js\api.js" $tmp -Force
    & node --check $tmp 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Host "  ERREUR de syntaxe dans js\api.js" -ForegroundColor Red
      & node --check $tmp
      $jsError = $true
    } else {
      Write-Host "  OK : js\api.js" -ForegroundColor Green
    }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  }

  foreach ($html in @("index.html","admin.html")) {
    if (Test-Path $html) {
      $content = Get-Content $html -Raw
      $m = [regex]::Match($content, '(?s)<script[^>]*>(.*?)</script>')
      if ($m.Success) {
        $tmp = [System.IO.Path]::GetTempFileName() + ".mjs"
        Set-Content -Path $tmp -Value $m.Groups[1].Value -Encoding UTF8
        & node --check $tmp 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
          Write-Host "  ERREUR de syntaxe dans $html" -ForegroundColor Red
          & node --check $tmp
          $jsError = $true
        } else {
          Write-Host "  OK : $html" -ForegroundColor Green
        }
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
      }
    }
  }

  if ($jsError) {
    Write-Host "`nARRET : erreur(s) de syntaxe detectee(s). Rien n'est pousse." -ForegroundColor Red
    exit 1
  }
  Write-Host "  Tous les fichiers JS sont valides." -ForegroundColor Green
}

# -------------------------------------------------------------------
# 3. SECURITE : aucune cle service_role ne doit partir
# -------------------------------------------------------------------
Write-Host "`n=== 3. Verification securite ===" -ForegroundColor Cyan
if (Test-Path "js\api.js") {
  $leak = Select-String -Path "js\api.js" -Pattern "service_role" -ErrorAction SilentlyContinue
  if ($leak) {
    Write-Host "  ARRET : cle service_role detectee dans js\api.js. Push annule." -ForegroundColor Red
    exit 1
  }
}
Write-Host "  OK : pas de cle secrete detectee." -ForegroundColor Green

# -------------------------------------------------------------------
# 4. COMMIT + PUSH
# -------------------------------------------------------------------
Write-Host "`n=== 4. Git : commit + push ===" -ForegroundColor Cyan
git add .
$status = git status --porcelain
if ([string]::IsNullOrWhiteSpace($status)) {
  Write-Host "  Rien a commiter (working tree clean)." -ForegroundColor Yellow
} else {
  git commit -m $Message
  git push
  Write-Host "`nTermine. Cloudflare redeploie sous ~30 secondes." -ForegroundColor Green
  Write-Host "Recharge le site avec Ctrl+F5." -ForegroundColor Green
}
