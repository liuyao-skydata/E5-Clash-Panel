<#
  E5 信息屏 · Clash 面板 —— 一键上传到 GitHub

  用法（在仓库文件夹里双击「一键上传.cmd」即可，也可以命令行跑）：
      .\tools\publish-github.ps1
      .\tools\publish-github.ps1 -Token ghp_xxxx
      .\tools\publish-github.ps1 -Repo e5-clash-panel -Private
      .\tools\publish-github.ps1 -NoRelease        # 只推代码，不发 Release

  做的事：
      1) git init / commit（没有仓库就建，有就提交改动）
      2) 用 Token 调 GitHub API 建仓库（已存在就跳过）
      3) 推送 main
      4) 打 Release 标签 v1.0.0，把 release/ 里的三个文件传成附件

  Token 只在内存里用，不会写进 .git/config、不会落盘。
#>
param(
    [string]$Repo = 'E5-Clash-Panel',
    [string]$Token = $env:GITHUB_TOKEN,
    [switch]$Private,
    [switch]$NoRelease
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

function Say($m) { Write-Host $m }
function Ok($m) { Write-Host "  OK  $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  !!  $m" -ForegroundColor Yellow }
function Die($m) { Write-Host "  XX  $m" -ForegroundColor Red; exit 1 }

Say ''
Say '=== E5 信息屏 · Clash 面板 / 一键上传 GitHub ==='
Say "目录: $Root"

# ---------- 1. 本地仓库 ----------
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Die '找不到 git，请先安装 Git for Windows: https://git-scm.com/download/win'
}
if (-not (Test-Path (Join-Path $Root '.git'))) {
    git init -b main | Out-Null
    Ok 'git 仓库已初始化（分支 main）'
}
if (-not (git config user.email)) {
    git config user.email 'e5-panel@users.noreply.github.com'
    git config user.name 'E5 Panel'
    Ok '已设置本地提交身份（只对这个仓库生效）'
}
git add -A
$pending = git status --porcelain
if ($pending) {
    git commit -m 'E5 信息屏 Clash 面板 v1.0.0' | Out-Null
    Ok '已提交本地改动'
} else {
    Ok '没有新改动'
}

# ---------- 2. Token ----------
# 已经发不过一次的话，凭据就在 .git/github-token 里（git 的 store 格式），直接复用，不再弹窗也不再问你
if (-not $Token) {
    $credPath = Join-Path (Split-Path -Parent $PSScriptRoot) '.git\github-token'
    if (Test-Path -LiteralPath $credPath) {
        $line = (Get-Content -LiteralPath $credPath -TotalCount 1).Trim()
        if ($line -match '^https://[^:]+:([^@]+)@') {
            $Token = $Matches[1]
            Ok '已复用本地保存的凭据（.git/github-token），无需再登录'
        }
    }
}
if (-not $Token) {
    Say ''
    Say '需要一个 GitHub Token（classic 勾 repo；或 fine-grained 给 Contents + Administration 读写）'
    Say '生成: https://github.com/settings/tokens/new?scopes=repo&description=E5-Clash-Panel'
    $sec = Read-Host '粘贴 Token（输入不回显）' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $Token = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
if (-not $Token) { Die '没拿到 Token，已退出' }

$headers = @{
    Authorization = "Bearer $Token"
    Accept        = 'application/vnd.github+json'
    'User-Agent'  = 'e5-clash-panel-installer'
}
$api = 'https://api.github.com'

function Invoke-GitHub($Method, $Uri, $Body) {
    if ($null -eq $Body) {
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
    }
    $json = $Body | ConvertTo-Json -Depth 4
    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -Body $json -ContentType 'application/json'
}

# ---------- 3. 账号与仓库 ----------
$owner = $null
try { $owner = (Invoke-GitHub 'GET' "$api/user" $null).login }
catch { Die 'Token 无效或没网（401 / 连不上 api.github.com）' }
Ok "已登录: $owner"

$repoExists = $false
try { Invoke-GitHub 'GET' "$api/repos/$owner/$Repo" $null | Out-Null; $repoExists = $true } catch { $repoExists = $false }

if (-not $repoExists) {
    $body = @{
        name        = $Repo
        description = 'E5 随身 WiFi 信息屏的 Clash 面板：状态、实时延迟、节点/配置切换、出口 IP，一键安装'
        private     = [bool]$Private
        has_issues  = $true
        has_wiki    = $false
    }
    Invoke-GitHub 'POST' "$api/user/repos" $body | Out-Null
    Ok "仓库已创建: https://github.com/$owner/$Repo"
} else {
    Ok "仓库已存在: https://github.com/$owner/$Repo"
}

# ---------- 4. 推送 ----------
git remote remove origin 2>&1 | Out-Null
git remote add origin "https://github.com/$owner/$Repo.git"
Say '  正在推送…'
$eap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$pushLog = & git push "https://x-access-token:$Token@github.com/$owner/$Repo.git" 'HEAD:refs/heads/main' --force 2>&1 | Out-String
$ErrorActionPreference = $eap
if ($LASTEXITCODE -ne 0) { Die "推送失败（Token 是否有 repo / Contents 写权限？网络是否通？）`n$pushLog" }
if ($pushLog -match 'Everything up-to-date') { Ok '远端已是最新（没有新提交）' } else { Ok '已推送到 main' }

# ---------- 5. Release ----------
if (-not $NoRelease) {
    $tag = 'v1.0.0'
    $releaseId = $null
    try {
        $rel = Invoke-GitHub 'GET' "$api/repos/$owner/$Repo/releases/tags/$tag" $null
        $releaseId = $rel.id
        Warn "Release $tag 已存在，只补传附件"
    } catch {
        $notes = @"
E5 随身 WiFi 信息屏 · Clash 面板

安装（root shell）:
    scp -O e5-panel-install.sh root@10.10.10.1:/tmp/
    ssh root@10.10.10.1 'sh /tmp/e5-panel-install.sh'

还原: sh /tmp/e5-panel-install.sh --restore
卸载: sh /tmp/e5-panel-install.sh --uninstall --yes

装前会自动备份到 /root/e5-panel-backups/，不会动 /etc/e5-infoscreen 和 /etc/config。
"@
        $body = @{ tag_name = $tag; name = "v1.0.0 — E5 信息屏 Clash 面板"; body = $notes; draft = $false; prerelease = $false }
        $releaseId = (Invoke-GitHub 'POST' "$api/repos/$owner/$Repo/releases" $body).id
        Ok "Release $tag 已创建"
    }

    $assets = @('e5-panel-install.sh', 'e5-panel-1.0.0.tar.gz', 'SHA256SUMS')
    $existing = @()
    try { $existing = (Invoke-GitHub 'GET' "$api/repos/$owner/$Repo/releases/$releaseId/assets" $null) | ForEach-Object { $_.name } } catch { }
    foreach ($a in $assets) {
        if ($existing -contains $a) { Ok "附件已存在，跳过: $a"; continue }
        $p = Join-Path $Root ("release\" + $a)
        if (-not (Test-Path $p)) { Warn "跳过（文件不存在）: $a"; continue }
        $up = "https://uploads.github.com/repos/$owner/$Repo/releases/$releaseId/assets?name=$a"
        try {
            Invoke-RestMethod -Method Post -Uri $up -Headers $headers -InFile $p -ContentType 'application/octet-stream' | Out-Null
            Ok "附件已上传: $a"
        } catch {
            Warn "附件上传失败（可能已存在）: $a"
        }
    }
}

# ---------- 6. 收尾 ----------
Say ''
Say '================ 完成 ================'
Say "仓库:    https://github.com/$owner/$Repo"
if (-not $NoRelease) { Say "发行版:  https://github.com/$owner/$Repo/releases/tag/v1.0.0" }
Say ''
Say '别人怎么装（复制这三行给他）:'
Say '    scp -O e5-panel-install.sh root@10.10.10.1:/tmp/'
Say "    ssh root@10.10.10.1 'sh /tmp/e5-panel-install.sh'"
Say ''
