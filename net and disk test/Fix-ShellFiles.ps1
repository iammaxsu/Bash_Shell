param(
  [string[]] $Path = @('.'),
  [switch] $Recurse
)

function Get-TargetFiles {
  param([string[]]$Path,[switch]$Recurse)
  $all = @()
  foreach ($p in $Path) {
    $all += Get-ChildItem -Path $p -File -Recurse:$Recurse -Filter *.sh
  }
  $all | Sort-Object -Unique
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$cp950     = [System.Text.Encoding]::GetEncoding(950)

$files = Get-TargetFiles -Path $Path -Recurse:$Recurse
if (-not $files) { Write-Host "No .sh files." -ForegroundColor Yellow; exit 0 }

foreach ($f in $files) {
  $bytes = [System.IO.File]::ReadAllBytes($f.FullName)

  # 去 BOM；同時記錄有無 BOM
  $hadBom = $false
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $bytes = $bytes[3..($bytes.Length-1)]
    $hadBom = $true
  }

  # 嘗試用 UTF-8 解碼；若遇到無效序列就 fallback 到 CP950
  $text = $null
  try {
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    # 檢查是否包含 UTF-8 解不出的替代符號（�）
    if ($text.Contains([char]0xFFFD)) { throw "Invalid UTF-8 sequence" }
  } catch {
    $text = $cp950.GetString($bytes)
  }

  # 正規化行尾：CRLF/CR -> LF
  $text = $text -replace "`r`n", "`n"
  $text = $text -replace "`r",   "`n"

  # 確保 shebang 為第一個字元（無前導空白/BOM）
  if ($text -match "^\s*#\!\/usr\/bin\/env\s+bash") {
    $text = $text -replace "^\s*#\!", "#!", 1
  }

  if (-not $text.EndsWith("`n")) { $text += "`n" }

  [System.IO.File]::WriteAllText($f.FullName, $text, $utf8NoBom)
  Write-Host "Fixed: $($f.FullName)  (BOM:$hadBom)" -ForegroundColor Green
}
