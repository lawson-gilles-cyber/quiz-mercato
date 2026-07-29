# =====================================================================
# QUIZ MERCATO — Script de déploiement
# =====================================================================
# Range les fichiers téléchargés dans les bons répertoires du repo,
# puis commit + push (Cloudflare redéploie automatiquement).
#
# UTILISATION :
#   1. Télécharge les fichiers fournis (ils vont dans C:\Users\gille\Downloads)
#   2. Ouvre PowerShell dans le dossier du repo :
#        cd "C:\Users\gille\Downloads\quiz-mercato"
#   3. Lance :  .\deploy.ps1 -Message "Description du changement"
#
# Le script cherche les fichiers dans le dossier Downloads (un niveau
# au-dessus) et les déplace vers leur destination dans le repo.
# =====================================================================

param(
  [string]$Message = "Mise a jour Quiz Mercato"
)

$ErrorActionPreference = "Stop"

# Racine du repo = dossier courant ; source des téléchargements = Downloads
$Repo      = Get-Location
$Downloads = "C:\Users\gille\Downloads"

Write-Host "=== Rangement des fichiers telecharges ===" -ForegroundColor Cyan

# Table de correspondance : nom de fichier -> sous-dossier de destination dans le repo
# (racine = "", sinon "js", "db", "edge")
$map = @{
  "index.html"              = ""
  "admin.html"              = ""
  "README.md"               = ""
  "api.js"                  = "js"
  "01_schema.sql"           = "db"
  "02_rpc_auctions.sql"     = "db"
  "03_rls.sql"              = "db"
  "04_cron.sql"             = "db"
  "05_admin.sql"            = "db"
  "06_import_players.sql"   = "db"
  "07_attributes.sql"       = "db"
  "08_seed_attributes.sql"  = "db"
  "09_squad_rules.sql"      = "db"
  "close-auctions.ts"       = "edge"
}

# S'assure que les sous-dossiers existent
foreach ($sub in @("js","db","edge")) {
  $path = Join-Path $Repo $sub
  if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path | Out-Null }
}

$moved = 0
foreach ($file in $map.Keys) {
  $src = Join-Path $Downloads $file
  if (Test-Path $src) {
    $destDir = if ($map[$file] -eq "") { $Repo } else { Join-Path $Repo $map[$file] }
    $dest = Join-Path $destDir $file
    Move-Item -Path $src -Destination $dest -Force
    Write-Host "  deplace : $file -> $($map[$file])" -ForegroundColor Green
    $moved++
  }
}

if ($moved -eq 0) {
  Write-Host "Aucun fichier a deplacer trouve dans $Downloads." -ForegroundColor Yellow
  Write-Host "(Les fichiers ont peut-etre deja ete ranges. On continue vers git.)" -ForegroundColor Yellow
} else {
  Write-Host "$moved fichier(s) range(s)." -ForegroundColor Cyan
}

# --- Verification anti-fuite : aucune cle service_role ne doit partir ---
Write-Host "`n=== Verification securite ===" -ForegroundColor Cyan
$leak = Select-String -Path "js\api.js" -Pattern "service_role" -ErrorAction SilentlyContinue
if ($leak) {
  Write-Host "ARRET : une cle service_role a ete detectee dans js\api.js. Push annule." -ForegroundColor Red
  exit 1
}
Write-Host "  OK : pas de cle secrete detectee." -ForegroundColor Green

# --- Commit + push ---
Write-Host "`n=== Git : commit + push ===" -ForegroundColor Cyan
git add .
git commit -m $Message
git push

Write-Host "`nTermine. Cloudflare redeploie sous ~30 secondes." -ForegroundColor Green
Write-Host "Recharge le site avec Ctrl+F5 pour voir les changements." -ForegroundColor Green
