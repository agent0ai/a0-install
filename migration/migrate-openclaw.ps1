$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Migrate an OpenClaw installation to Agent Zero on Windows.

.DESCRIPTION
    PowerShell port of migrate-openclaw.sh with Windows-native path discovery.

.PARAMETER IncludeAuthProfiles
    Attempt to extract API-key-style secrets from auth-profiles.json.

.PARAMETER OpenClawDir
    Path to the OpenClaw state directory. If omitted, the script checks:
      1. $env:OPENCLAW_STATE_DIR
      2. $HOME\.openclaw
      3. $HOME\.openclaw-*

.PARAMETER AgentZeroUsrDir
    Path to Agent Zero's usr directory. If omitted, the script checks:
      1. $HOME\agent-zero\agent-zero\usr
      2. $HOME\agent-zero\*\usr
      3. Falls back to $HOME\agent-zero\agent-zero\usr

.EXAMPLE
    .\migrate-openclaw.ps1 -IncludeAuthProfiles

.EXAMPLE
    .\migrate-openclaw.ps1 'C:\Users\me\.openclaw' 'C:\Users\me\agent-zero\agent-zero\usr'
#>

param(
    [Parameter(Position = 0)]
    [string]$OpenClawDir,

    [Parameter(Position = 1)]
    [string]$AgentZeroUsrDir,

    [switch]$IncludeAuthProfiles,

    [switch]$Help
)

$script:HomeDir = [Environment]::GetFolderPath('UserProfile')
$script:ScriptName = if ($PSCommandPath) { Split-Path -Leaf $PSCommandPath } else { 'migrate-openclaw.ps1' }
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Migrated = 0
$script:Skipped = 0
$script:Warnings = 0
$script:ReportInitialized = $false
$script:MigrationReport = ''
$script:PythonCommand = $null
$script:NodeCommand = $null
$script:KnownEnvKeys = @(
    'OPENAI_API_KEY',
    'ANTHROPIC_API_KEY',
    'GEMINI_API_KEY',
    'GOOGLE_API_KEY',
    'OPENROUTER_API_KEY',
    'GROQ_API_KEY',
    'MISTRAL_API_KEY',
    'DEEPSEEK_API_KEY',
    'TOGETHER_API_KEY',
    'PERPLEXITY_API_KEY',
    'XAI_API_KEY',
    'CEREBRAS_API_KEY',
    'SAMBANOVA_API_KEY'
)

function Show-Usage {
    @"
Usage:
  .\migrate-openclaw.ps1 [-IncludeAuthProfiles] [OPENCLAW_DIR] [A0_USR_DIR]

Options:
  -IncludeAuthProfiles   Attempt to extract API-key-style secrets from auth-profiles.json
  -Help                  Show this help text
"@ | Write-Host
}

function print_info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function print_ok {
    param([string]$Message)
    Write-Host "[ OK ] $Message" -ForegroundColor Green
}

function print_warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function print_error {
    param([string]$Message)
    Write-Host "[ERR ] $Message" -ForegroundColor Red
}

function Write-Header {
    param([string]$Title)
    Write-Host ''
    Write-Host "=== $Title ===" -ForegroundColor White
}

function Expand-UserPath {
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $PathValue
    }

    if ($PathValue -eq '~') {
        return $script:HomeDir
    }

    if ($PathValue.StartsWith('~/') -or $PathValue.StartsWith('~\')) {
        return (Join-Path $script:HomeDir $PathValue.Substring(2))
    }

    return $PathValue
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent *> $null
    }

    [System.IO.File]::WriteAllText($Path, $Content, $script:Utf8NoBom)
}

function Append-LineUtf8 {
    param(
        [string]$Path,
        [string]$Line
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent *> $null
    }

    [System.IO.File]::AppendAllText($Path, $Line + [Environment]::NewLine, $script:Utf8NoBom)
}

function report_line {
    param([string]$Line = '')

    if ($script:ReportInitialized -and -not [string]::IsNullOrWhiteSpace($script:MigrationReport)) {
        Append-LineUtf8 -Path $script:MigrationReport -Line $Line
    }
}

function log_migrated {
    param([string]$Message)
    $script:Migrated++
    print_ok $Message
    report_line "- Migrated: $Message"
}

function log_skipped {
    param([string]$Message)
    $script:Skipped++
    print_info "Skipped: $Message"
    report_line "- Skipped: $Message"
}

function log_warning {
    param([string]$Message)
    $script:Warnings++
    print_warn $Message
    report_line "- Warning: $Message"
}

function ConvertTo-OrderedMap {
    param([object]$InputObject)

    $map = [ordered]@{}

    if ($null -eq $InputObject) {
        return $map
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            $map[$key] = $InputObject[$key]
        }
        return $map
    }

    foreach ($prop in $InputObject.PSObject.Properties) {
        $map[$prop.Name] = $prop.Value
    }

    return $map
}

function Get-ConfigPropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
        return $Default
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop) {
        return $prop.Value
    }

    return $Default
}

function Get-NestedConfigValue {
    param(
        [object]$Object,
        [string]$Path,
        [object]$Default = $null
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Object
    }

    $current = $Object
    foreach ($segment in ($Path.Trim('.').Split('.'))) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }

        if ($null -eq $current) {
            return $Default
        }

        if (($current -is [System.Collections.IList]) -and -not ($current -is [string])) {
            if ($segment -notmatch '^\d+$') {
                return $Default
            }
            $index = [int]$segment
            if ($index -ge $current.Count) {
                return $Default
            }
            $current = $current[$index]
            continue
        }

        $current = Get-ConfigPropertyValue -Object $current -Name $segment -Default $null
        if ($null -eq $current) {
            return $Default
        }
    }

    return $current
}

function Test-IsConfigObject {
    param([object]$Value)
    return ($Value -is [System.Collections.IDictionary]) -or ($Value -is [pscustomobject])
}

function To-JsonString {
    param(
        [object]$Value,
        [int]$Depth = 20
    )

    return (($Value | ConvertTo-Json -Depth $Depth) + [Environment]::NewLine)
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Payload
    )

    Write-Utf8NoBom -Path $Path -Content (To-JsonString -Value $Payload -Depth 30)
}

function Write-AgentManifest {
    param(
        [string]$Path,
        [string]$Title,
        [string]$Description
    )

    $payload = [ordered]@{
        title = $Title
        description = $Description
    }
    Write-JsonFile -Path $Path -Payload $payload
}

function First-MeaningfulLine {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }

    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $stripped = ([regex]::Replace($line, '^#+\s*', '')).Trim()
        if (-not [string]::IsNullOrWhiteSpace($stripped)) {
            return $stripped
        }
    }

    return ''
}

function Get-EnvironmentVariableValue {
    param([string]$Name)

    foreach ($target in @('Process', 'User', 'Machine')) {
        $value = [Environment]::GetEnvironmentVariable($Name, $target)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    return $null
}

function Sanitize-AgentId {
    param([string]$Value)

    $sanitized = [regex]::Replace(($Value | ForEach-Object { "$_" }), '[^A-Za-z0-9._-]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($sanitized)) {
        return 'agent'
    }

    return $sanitized
}

function Map-EnvKey {
    param([string]$SourceKey)

    switch ($SourceKey) {
        'OPENAI_API_KEY' { return 'API_KEY_OPENAI' }
        'ANTHROPIC_API_KEY' { return 'API_KEY_ANTHROPIC' }
        { $_ -in @('GEMINI_API_KEY', 'GOOGLE_API_KEY') } { return 'API_KEY_GOOGLE' }
        'OPENROUTER_API_KEY' { return 'API_KEY_OPENROUTER' }
        'GROQ_API_KEY' { return 'API_KEY_GROQ' }
        'MISTRAL_API_KEY' { return 'API_KEY_MISTRAL' }
        'DEEPSEEK_API_KEY' { return 'API_KEY_DEEPSEEK' }
        'TOGETHER_API_KEY' { return 'API_KEY_TOGETHER' }
        'PERPLEXITY_API_KEY' { return 'API_KEY_PERPLEXITYAI' }
        'XAI_API_KEY' { return 'API_KEY_XAI' }
        'CEREBRAS_API_KEY' { return 'API_KEY_CEREBRAS' }
        'SAMBANOVA_API_KEY' { return 'API_KEY_SAMBANOVA' }
        default { return $null }
    }
}

function Ensure-EnvKey {
    param(
        [string]$SourceKey,
        [string]$Value,
        [string]$SourceLabel,
        [string]$TargetEnvPath
    )

    $targetKey = Map-EnvKey -SourceKey $SourceKey
    if ([string]::IsNullOrWhiteSpace($targetKey) -or [string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    $current = ''
    if (Test-Path -LiteralPath $TargetEnvPath) {
        $current = Get-Content -LiteralPath $TargetEnvPath -Raw
    }

    $escapedTargetKey = [regex]::Escape($targetKey)
    if ($current -match "(?m)^${escapedTargetKey}=") {
        log_skipped "$targetKey already set in $TargetEnvPath"
        return
    }

    Append-LineUtf8 -Path $TargetEnvPath -Line "$targetKey=$Value"
    log_migrated "$SourceKey -> $targetKey ($SourceLabel)"
}

function Trim-WrappingQuotes {
    param([string]$Value)

    if ($null -eq $Value) {
        return ''
    }

    $text = "$Value"
    if ($text.Length -ge 2) {
        if (($text.StartsWith('"') -and $text.EndsWith('"')) -or ($text.StartsWith("'") -and $text.EndsWith("'"))) {
            return $text.Substring(1, $text.Length - 2)
        }
    }

    return $text
}

function Get-EnvFileValues {
    param([string]$Path)

    $values = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $values
    }

    foreach ($rawLine in [System.IO.File]::ReadAllLines($Path)) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#') -or -not $line.Contains('=')) {
            continue
        }

        $parts = $line.Split('=', 2)
        $key = $parts[0].Trim()
        $value = Trim-WrappingQuotes -Value $parts[1].Trim()
        if (-not [string]::IsNullOrWhiteSpace($key)) {
            $values[$key] = $value
        }
    }

    return $values
}

function Get-ConfigEnvRefs {
    param([string]$RawText)

    if ([string]::IsNullOrWhiteSpace($RawText)) {
        return @()
    }

    return @([regex]::Matches($RawText, '\$\{([A-Za-z_][A-Za-z0-9_]*)\}') |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object -Unique)
}

function Get-KnownEnvPairsFromObject {
    param(
        [object]$Object,
        [string[]]$CandidateKeys
    )

    $results = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $candidateSet = @{}
    foreach ($candidate in $CandidateKeys) {
        $candidateSet[$candidate] = $true
    }

    function Visit-Node {
        param([object]$Node)

        if ($null -eq $Node) {
            return
        }

        if ($Node -is [System.Collections.IDictionary]) {
            foreach ($key in $Node.Keys) {
                $value = $Node[$key]
                if ($candidateSet.ContainsKey([string]$key) -and $value -is [string] -and -not [string]::IsNullOrWhiteSpace($value)) {
                    $signature = "$key`n$value"
                    if (-not $seen.ContainsKey($signature)) {
                        $seen[$signature] = $true
                        $results.Add([pscustomobject]@{
                            Key = [string]$key
                            Value = [string]$value
                        })
                    }
                }
                Visit-Node -Node $value
            }
            return
        }

        if ($Node -is [pscustomobject]) {
            foreach ($prop in $Node.PSObject.Properties) {
                $value = $prop.Value
                if ($candidateSet.ContainsKey([string]$prop.Name) -and $value -is [string] -and -not [string]::IsNullOrWhiteSpace($value)) {
                    $signature = "$($prop.Name)`n$value"
                    if (-not $seen.ContainsKey($signature)) {
                        $seen[$signature] = $true
                        $results.Add([pscustomobject]@{
                            Key = [string]$prop.Name
                            Value = [string]$value
                        })
                    }
                }
                Visit-Node -Node $value
            }
            return
        }

        if (($Node -is [System.Collections.IEnumerable]) -and -not ($Node -is [string])) {
            foreach ($item in $Node) {
                Visit-Node -Node $item
            }
        }
    }

    Visit-Node -Node $Object
    return @($results)
}

function Get-DirectoryFingerprint {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return @()
    }

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $files = Get-ChildItem -LiteralPath $resolved -Recurse -File | Sort-Object FullName
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($resolved.Length).TrimStart('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        $lines.Add("$relative`t$($file.Length)`t$hash")
    }
    return @($lines)
}

function Directories-Equal {
    param(
        [string]$LeftPath,
        [string]$RightPath
    )

    $left = Get-DirectoryFingerprint -Path $LeftPath
    $right = Get-DirectoryFingerprint -Path $RightPath

    if ($left.Count -ne $right.Count) {
        return $false
    }

    for ($i = 0; $i -lt $left.Count; $i++) {
        if ($left[$i] -ne $right[$i]) {
            return $false
        }
    }

    return $true
}

function Copy-DirectoryWithCollisionHandling {
    param(
        [string]$SourceDir,
        [string]$TargetDir,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $TargetDir -PathType Container)) {
        $parent = Split-Path -Parent $TargetDir
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            New-Item -ItemType Directory -Force -Path $parent *> $null
        }
        Copy-Item -LiteralPath $SourceDir -Destination $TargetDir -Recurse
        log_migrated $Label
        return
    }

    if (Directories-Equal -LeftPath $SourceDir -RightPath $TargetDir) {
        log_skipped "$Label already exists with identical contents"
    }
    else {
        log_warning "$Label already exists with different contents: $TargetDir"
    }
}

function ConvertTo-List {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string]) -and -not ($Value -is [System.Collections.IDictionary]) -and -not ($Value -is [pscustomobject])) {
        return @($Value)
    }

    return @($Value)
}

function Normalize-AllowedUsers {
    param([object]$Raw)

    if ($null -eq $Raw -or ($Raw -is [System.Collections.IDictionary]) -or ($Raw -is [pscustomobject])) {
        return @()
    }

    $result = New-Object System.Collections.Generic.List[string]
    foreach ($item in (ConvertTo-List -Value $Raw)) {
        $value = ([string]$item).Replace('telegram:', '').Replace('tg:', '').Trim()
        if (-not [string]::IsNullOrWhiteSpace($value) -and $value -ne '*' -and -not $result.Contains($value)) {
            $null = $result.Add($value)
        }
    }

    return @($result)
}

function Normalize-GroupMode {
    param([object]$RawGroups)

    if ($RawGroups -is [bool] -and -not $RawGroups) {
        return 'off'
    }

    if (-not (Test-IsConfigObject -Value $RawGroups)) {
        return 'mention'
    }

    $groupMap = ConvertTo-OrderedMap -InputObject $RawGroups
    if ($groupMap.Count -eq 0) {
        return 'mention'
    }

    $keys = @('*') + @($groupMap.Keys)
    foreach ($key in $keys) {
        $entry = Get-ConfigPropertyValue -Object $RawGroups -Name ([string]$key) -Default $null
        if (-not (Test-IsConfigObject -Value $entry)) {
            continue
        }

        $enabled = Get-ConfigPropertyValue -Object $entry -Name 'enabled' -Default $null
        if ($enabled -is [bool] -and -not $enabled) {
            return 'off'
        }

        $requireMention = Get-ConfigPropertyValue -Object $entry -Name 'requireMention' -Default $null
        if ($requireMention -is [bool] -and -not $requireMention) {
            return 'all'
        }
        if ($requireMention -is [bool] -and $requireMention) {
            return 'mention'
        }
    }

    return 'mention'
}

function Get-WebhookFields {
    param([object]$Raw)

    if (-not (Test-IsConfigObject -Value $Raw)) {
        return [ordered]@{
            mode = 'polling'
            webhook_url = ''
            webhook_secret = ''
        }
    }

    $enabled = Get-ConfigPropertyValue -Object $Raw -Name 'enabled' -Default $null
    if ($enabled -is [bool] -and -not $enabled) {
        return [ordered]@{
            mode = 'polling'
            webhook_url = ''
            webhook_secret = ''
        }
    }

    $url = [string](Get-ConfigPropertyValue -Object $Raw -Name 'url' -Default '')
    if ([string]::IsNullOrWhiteSpace($url)) {
        $url = [string](Get-ConfigPropertyValue -Object $Raw -Name 'webhookUrl' -Default '')
    }
    if ([string]::IsNullOrWhiteSpace($url)) {
        $url = [string](Get-ConfigPropertyValue -Object $Raw -Name 'baseUrl' -Default '')
    }

    $secret = [string](Get-ConfigPropertyValue -Object $Raw -Name 'secret' -Default '')
    if ([string]::IsNullOrWhiteSpace($secret)) {
        $secret = [string](Get-ConfigPropertyValue -Object $Raw -Name 'webhookSecret' -Default '')
    }

    if (-not [string]::IsNullOrWhiteSpace($url)) {
        return [ordered]@{
            mode = 'webhook'
            webhook_url = $url
            webhook_secret = $secret
        }
    }

    return [ordered]@{
        mode = 'polling'
        webhook_url = ''
        webhook_secret = ''
    }
}

function Build-TelegramBot {
    param(
        [string]$Name,
        [object]$Source,
        [object]$TelegramConfig,
        [System.Collections.IDictionary]$EnvValues
    )

    $warnings = New-Object System.Collections.Generic.List[string]
    if (-not (Test-IsConfigObject -Value $Source)) {
        $warnings.Add("telegram account '$Name' is not an object; skipped")
        return [ordered]@{
            bot = $null
            warnings = @($warnings)
        }
    }

    $token = [string](Get-ConfigPropertyValue -Object $Source -Name 'botToken' -Default '')
    if ([string]::IsNullOrWhiteSpace($token)) {
        $token = [string](Get-ConfigPropertyValue -Object $TelegramConfig -Name 'botToken' -Default '')
    }
    if ([string]::IsNullOrWhiteSpace($token) -and $EnvValues.Contains('TELEGRAM_BOT_TOKEN')) {
        $token = [string]$EnvValues['TELEGRAM_BOT_TOKEN']
    }

    if ([string]::IsNullOrWhiteSpace($token) -or $token.Contains('${')) {
        $warnings.Add("telegram account '$Name' has no concrete bot token; skipped")
        return [ordered]@{
            bot = $null
            warnings = @($warnings)
        }
    }

    $webhookSource = Get-ConfigPropertyValue -Object $Source -Name 'webhook' -Default $null
    if ($null -eq $webhookSource) {
        $webhookSource = Get-ConfigPropertyValue -Object $TelegramConfig -Name 'webhook' -Default $null
    }
    $webhook = Get-WebhookFields -Raw $webhookSource

    $allowFrom = Get-ConfigPropertyValue -Object $Source -Name 'allowFrom' -Default $null
    if ($null -eq $allowFrom) {
        $allowFrom = Get-ConfigPropertyValue -Object $TelegramConfig -Name 'allowFrom' -Default @()
    }

    $groups = Get-ConfigPropertyValue -Object $Source -Name 'groups' -Default $null
    if ($null -eq $groups) {
        $groups = Get-ConfigPropertyValue -Object $TelegramConfig -Name 'groups' -Default @{}
    }

    $bot = [ordered]@{
        name = $Name
        enabled = $true
        token = $token
        mode = $webhook['mode']
        webhook_url = $webhook['webhook_url']
        webhook_secret = $webhook['webhook_secret']
        allowed_users = @(Normalize-AllowedUsers -Raw $allowFrom)
        group_mode = Normalize-GroupMode -RawGroups $groups
    }

    return [ordered]@{
        bot = $bot
        warnings = @($warnings)
    }
}

function Build-TelegramPayload {
    param(
        [object]$ConfigObject,
        [System.Collections.IDictionary]$EnvValues
    )

    $channels = Get-ConfigPropertyValue -Object $ConfigObject -Name 'channels' -Default $null
    $telegram = Get-ConfigPropertyValue -Object $channels -Name 'telegram' -Default @{}
    if (-not (Test-IsConfigObject -Value $telegram)) {
        $telegram = @{}
    }

    $bots = New-Object System.Collections.Generic.List[object]
    $warnings = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]

    $accounts = Get-ConfigPropertyValue -Object $telegram -Name 'accounts' -Default $null
    if (Test-IsConfigObject -Value $accounts) {
        foreach ($entry in (ConvertTo-OrderedMap -InputObject $accounts).GetEnumerator()) {
            $built = Build-TelegramBot -Name ([string]$entry.Key) -Source $entry.Value -TelegramConfig $telegram -EnvValues $EnvValues
            foreach ($warning in @($built['warnings'])) {
                if (-not [string]::IsNullOrWhiteSpace($warning)) {
                    $warnings.Add($warning)
                }
            }
            if ($null -ne $built['bot']) {
                $bots.Add($built['bot'])
            }
        }
    }
    else {
        $built = Build-TelegramBot -Name 'default' -Source $telegram -TelegramConfig $telegram -EnvValues $EnvValues
        foreach ($warning in @($built['warnings'])) {
            if (-not [string]::IsNullOrWhiteSpace($warning)) {
                $warnings.Add($warning)
            }
        }
        if ($null -ne $built['bot']) {
            $bots.Add($built['bot'])
        }
    }

    $dmPolicy = [string](Get-ConfigPropertyValue -Object $telegram -Name 'dmPolicy' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($dmPolicy)) {
        $notes.Add("OpenClaw dmPolicy was '$dmPolicy' and was not mapped directly.")
    }

    if ($null -ne (Get-ConfigPropertyValue -Object $telegram -Name 'bindings' -Default $null)) {
        $notes.Add('OpenClaw Telegram bindings were not migrated; review channel routing manually.')
    }

    if ($null -ne (Get-ConfigPropertyValue -Object $telegram -Name 'pairing' -Default $null)) {
        $notes.Add('OpenClaw Telegram pairing behavior was not migrated.')
    }

    return [ordered]@{
        bots = @($bots)
        warnings = @($warnings)
        notes = @($notes)
    }
}

function Get-PythonCommand {
    if ($script:PythonCommand) {
        return $script:PythonCommand
    }

    if (Get-Command python -ErrorAction SilentlyContinue) {
        $script:PythonCommand = [ordered]@{
            Name = 'python'
            Args = @()
        }
        return $script:PythonCommand
    }

    if (Get-Command python3 -ErrorAction SilentlyContinue) {
        $script:PythonCommand = [ordered]@{
            Name = 'python3'
            Args = @()
        }
        return $script:PythonCommand
    }

    if (Get-Command py -ErrorAction SilentlyContinue) {
        $probe = & py -3 -c 'import sys; print(sys.version_info[0])' 2>$null
        if ($LASTEXITCODE -eq 0) {
            $script:PythonCommand = [ordered]@{
                Name = 'py'
                Args = @('-3')
            }
            return $script:PythonCommand
        }
    }

    return $null
}

function Invoke-PythonCommand {
    param([string]$Code)

    $python = Get-PythonCommand
    if ($null -eq $python) {
        return [pscustomobject]@{
            ExitCode = 127
            Output = ''
        }
    }

    $output = & $python['Name'] @($python['Args']) -c $Code 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = (($output | ForEach-Object { "$_" }) -join [Environment]::NewLine)
    }
}

function Invoke-PythonFileCommand {
    param(
        [string]$Code,
        [string[]]$Arguments
    )

    $python = Get-PythonCommand
    if ($null -eq $python) {
        return [pscustomobject]@{
            ExitCode = 127
            Output = ''
        }
    }

    $output = & $python['Name'] @($python['Args']) -c $Code @Arguments 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = (($output | ForEach-Object { "$_" }) -join [Environment]::NewLine)
    }
}

function Get-NodeCommand {
    if ($script:NodeCommand) {
        return $script:NodeCommand
    }

    if (Get-Command node -ErrorAction SilentlyContinue) {
        $script:NodeCommand = 'node'
    }

    return $script:NodeCommand
}

function Invoke-NodeCommand {
    param(
        [string]$Code,
        [string[]]$Arguments
    )

    $node = Get-NodeCommand
    if ([string]::IsNullOrWhiteSpace($node)) {
        return [pscustomobject]@{
            ExitCode = 127
            Output = ''
        }
    }

    $output = & $node -e $Code @Arguments 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = (($output | ForEach-Object { "$_" }) -join [Environment]::NewLine)
    }
}

function Test-PythonJson5Support {
    $result = Invoke-PythonCommand -Code 'import json5'
    return ($result.ExitCode -eq 0)
}

function Test-NodeJson5Support {
    $result = Invoke-NodeCommand -Code 'require("json5")' -Arguments @()
    return ($result.ExitCode -eq 0)
}

function Parse-ConfigJson5WithPython {
    param([string]$Path)

    $code = @'
import json
import pathlib
import sys
import json5

path = pathlib.Path(sys.argv[1])
data = json5.loads(path.read_text(encoding="utf-8"))
sys.stdout.write(json.dumps(data))
'@

    $result = Invoke-PythonFileCommand -Code $code -Arguments @($Path)
    if ($result.ExitCode -ne 0) {
        throw "Python json5 parse failed: $($result.Output)"
    }
    return $result.Output
}

function Parse-ConfigJson5WithNode {
    param([string]$Path)

    $code = @'
const fs = require("fs");
const JSON5 = require("json5");
const filePath = process.argv[1];
const raw = fs.readFileSync(filePath, "utf8");
process.stdout.write(JSON.stringify(JSON5.parse(raw)));
'@

    $result = Invoke-NodeCommand -Code $code -Arguments @($Path)
    if ($result.ExitCode -ne 0) {
        throw "Node json5 parse failed: $($result.Output)"
    }
    return $result.Output
}

function Select-PathFromCandidates {
    param(
        [string]$Label,
        [string[]]$Candidates
    )

    if ($Candidates.Count -eq 0) {
        return $null
    }

    if ($Candidates.Count -eq 1 -or -not [Environment]::UserInteractive) {
        return $Candidates[0]
    }

    Write-Host ''
    Write-Host "Multiple $Label directories were found:" -ForegroundColor White
    for ($i = 0; $i -lt $Candidates.Count; $i++) {
        Write-Host ("  {0}. {1}" -f ($i + 1), $Candidates[$i])
    }

    while ($true) {
        $selection = Read-Host "Choose a number for the $Label directory"
        if ([string]::IsNullOrWhiteSpace($selection)) {
            return $Candidates[0]
        }
        if ($selection -match '^\d+$') {
            $index = [int]$selection - 1
            if ($index -ge 0 -and $index -lt $Candidates.Count) {
                return $Candidates[$index]
            }
        }
        print_warn 'Invalid selection.'
    }
}

function Prompt-ForAbsoluteDirectory {
    param([string]$Prompt)

    if (-not [Environment]::UserInteractive) {
        throw "Directory was not found automatically and no interactive terminal is available. Pass the path explicitly."
    }

    while ($true) {
        $candidate = Read-Host $Prompt
        $candidate = Expand-UserPath -PathValue $candidate

        if ([string]::IsNullOrWhiteSpace($candidate)) {
            print_warn 'Please enter an absolute path.'
            continue
        }

        if (-not [System.IO.Path]::IsPathRooted($candidate)) {
            print_warn 'The path must be absolute.'
            continue
        }

        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
            print_warn "Directory not found: $candidate"
            continue
        }

        return $candidate
    }
}

function Get-OpenClawCandidatePaths {
    $seen = @{}
    $candidates = New-Object System.Collections.Generic.List[string]

    $envStateDir = Expand-UserPath -PathValue $env:OPENCLAW_STATE_DIR
    if (-not [string]::IsNullOrWhiteSpace($envStateDir) -and (Test-Path -LiteralPath $envStateDir -PathType Container)) {
        $seen[$envStateDir] = $true
        $candidates.Add($envStateDir)
    }

    $defaultDir = Join-Path $script:HomeDir '.openclaw'
    if (Test-Path -LiteralPath $defaultDir -PathType Container -and -not $seen.ContainsKey($defaultDir)) {
        $seen[$defaultDir] = $true
        $candidates.Add($defaultDir)
    }

    if (Test-Path -LiteralPath $script:HomeDir -PathType Container) {
        $profileDirs = Get-ChildItem -LiteralPath $script:HomeDir -Directory | Where-Object { $_.Name -like '.openclaw-*' } | Sort-Object Name
        foreach ($dir in $profileDirs) {
            if (-not $seen.ContainsKey($dir.FullName)) {
                $seen[$dir.FullName] = $true
                $candidates.Add($dir.FullName)
            }
        }
    }

    return @($candidates)
}

function Resolve-OpenClawDir {
    param([string]$ExplicitDir)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitDir)) {
        $resolved = Expand-UserPath -PathValue $ExplicitDir
        if (Test-Path -LiteralPath $resolved -PathType Container) {
            return $resolved
        }

        print_warn "OpenClaw directory not found at explicit path: $resolved"
        return (Prompt-ForAbsoluteDirectory -Prompt 'Enter the absolute path to your .openclaw folder')
    }

    $candidates = Get-OpenClawCandidatePaths
    if ($candidates.Count -gt 0) {
        return (Select-PathFromCandidates -Label 'OpenClaw' -Candidates $candidates)
    }

    return (Prompt-ForAbsoluteDirectory -Prompt 'Enter the absolute path to your .openclaw folder')
}

function Get-AgentZeroUsrCandidates {
    $installRoot = Join-Path $script:HomeDir 'agent-zero'
    $seen = @{}
    $candidates = New-Object System.Collections.Generic.List[string]

    $defaultUsr = Join-Path $installRoot 'agent-zero\usr'
    if (Test-Path -LiteralPath $defaultUsr -PathType Container) {
        $seen[$defaultUsr] = $true
        $candidates.Add($defaultUsr)
    }

    if (Test-Path -LiteralPath $installRoot -PathType Container) {
        foreach ($instanceDir in (Get-ChildItem -LiteralPath $installRoot -Directory | Sort-Object Name)) {
            $usrDir = Join-Path $instanceDir.FullName 'usr'
            if (Test-Path -LiteralPath $usrDir -PathType Container -and -not $seen.ContainsKey($usrDir)) {
                $seen[$usrDir] = $true
                $candidates.Add($usrDir)
            }
        }
    }

    return @($candidates)
}

function Resolve-AgentZeroUsrDir {
    param([string]$ExplicitDir)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitDir)) {
        return (Expand-UserPath -PathValue $ExplicitDir)
    }

    $candidates = Get-AgentZeroUsrCandidates
    if ($candidates.Count -gt 0) {
        return (Select-PathFromCandidates -Label 'Agent Zero usr' -Candidates $candidates)
    }

    return (Join-Path (Join-Path $script:HomeDir 'agent-zero') 'agent-zero\usr')
}

if ($Help) {
    Show-Usage
    exit 0
}

$OpenClawDir = Resolve-OpenClawDir -ExplicitDir $OpenClawDir
$AgentZeroUsrDir = Resolve-AgentZeroUsrDir -ExplicitDir $AgentZeroUsrDir

$OPENCLAW_CONFIG = Join-Path $OpenClawDir 'openclaw.json'
$OPENCLAW_ENV = Join-Path $OpenClawDir '.env'
$OPENCLAW_AUTH_PROFILES = Join-Path $OpenClawDir 'auth-profiles.json'
$A0_ENV = Join-Path $AgentZeroUsrDir '.env'
$MIGRATION_LOG = Join-Path $AgentZeroUsrDir 'openclaw-migration.log'
$script:MigrationReport = Join-Path $AgentZeroUsrDir 'openclaw-migration-report.md'
$MIGRATION_WORKDIR_ROOT = Join-Path $AgentZeroUsrDir 'workdir\openclaw-migration'
$KNOWLEDGE_DIR = Join-Path $AgentZeroUsrDir 'knowledge\custom\openclaw'
$MEMORY_KNOWLEDGE_DIR = Join-Path $AgentZeroUsrDir 'knowledge\custom\openclaw-memory'

Write-Header 'OpenClaw -> Agent Zero Migration'
Write-Host ''
print_info "OpenClaw dir : $OpenClawDir"
print_info "Agent Zero   : $AgentZeroUsrDir"
Write-Host ''

if (-not (Test-Path -LiteralPath $OpenClawDir -PathType Container)) {
    print_error "OpenClaw directory not found: $OpenClawDir"
    exit 1
}

New-Item -ItemType Directory -Force -Path $AgentZeroUsrDir *> $null
if (-not (Test-Path -LiteralPath $A0_ENV -PathType Leaf)) {
    Write-Utf8NoBom -Path $A0_ENV -Content ''
}

$reportIntro = @(
    '# OpenClaw -> Agent Zero Migration Report',
    '',
    "- Date: $([DateTimeOffset]::Now.ToString('o'))",
    "- Source: $OpenClawDir",
    "- Target: $AgentZeroUsrDir",
    "- Promptinclude workdir root: $MIGRATION_WORKDIR_ROOT",
    '',
    '## Notes',
    '',
    "- Agent Zero profiles are generated from OpenClaw agents, but they do not preserve OpenClaw's full auth/session/channel isolation model.",
    '- Promptinclude files are written to a generated workdir tree. Agent Zero loads them only when the active workdir or project points there.',
    '',
    '## Actions',
    ''
)
Write-Utf8NoBom -Path $script:MigrationReport -Content (($reportIntro -join [Environment]::NewLine) + [Environment]::NewLine)
$script:ReportInitialized = $true

$ConfigObject = [ordered]@{}
$ConfigParseMode = 'not-used'
$ConfigRawText = ''

if (Test-Path -LiteralPath $OPENCLAW_CONFIG -PathType Leaf) {
    $ConfigRawText = Get-Content -LiteralPath $OPENCLAW_CONFIG -Raw
    try {
        $ConfigObject = $ConfigRawText | ConvertFrom-Json
        $ConfigParseMode = 'powershell-json'
        print_ok 'Parsed openclaw.json with strict JSON parser'
        report_line "- Config parser: $ConfigParseMode"
    }
    catch {
        if (Test-PythonJson5Support) {
            $parsedJson = Parse-ConfigJson5WithPython -Path $OPENCLAW_CONFIG
            $ConfigObject = $parsedJson | ConvertFrom-Json
            $ConfigParseMode = 'python-json5'
            print_ok 'Parsed openclaw.json with Python json5 parser'
            report_line "- Config parser: $ConfigParseMode"
        }
        elseif (Test-NodeJson5Support) {
            $parsedJson = Parse-ConfigJson5WithNode -Path $OPENCLAW_CONFIG
            $ConfigObject = $parsedJson | ConvertFrom-Json
            $ConfigParseMode = 'node-json5'
            print_ok 'Parsed openclaw.json with Node json5 parser'
            report_line "- Config parser: $ConfigParseMode"
        }
        else {
            print_error "Could not parse $OPENCLAW_CONFIG."
            print_error 'The file appears to require JSON5 support, but no JSON5-capable parser is available.'
            print_error "Install the Python package 'json5' or a Node runtime with the 'json5' package, then rerun."
            exit 1
        }
    }
}
else {
    print_warn "No openclaw.json found at $OPENCLAW_CONFIG"
    print_warn 'Will still attempt to migrate workspace files and .env'
    report_line '- Config parser: config file missing'
}

$envValues = Get-EnvFileValues -Path $OPENCLAW_ENV

Write-Header 'Step 1: API Keys'

if (Test-Path -LiteralPath $OPENCLAW_ENV -PathType Leaf) {
    print_info "Reading $OPENCLAW_ENV"
    foreach ($entry in $envValues.GetEnumerator()) {
        Ensure-EnvKey -SourceKey ([string]$entry.Key) -Value ([string]$entry.Value) -SourceLabel '.env' -TargetEnvPath $A0_ENV
    }
}
else {
    log_skipped "No .env file found at $OPENCLAW_ENV"
}

if (Test-Path -LiteralPath $OPENCLAW_CONFIG -PathType Leaf) {
    foreach ($refName in (Get-ConfigEnvRefs -RawText $ConfigRawText)) {
        $targetKey = Map-EnvKey -SourceKey $refName
        if ([string]::IsNullOrWhiteSpace($targetKey)) {
            continue
        }

        $value = Get-EnvironmentVariableValue -Name $refName
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            Ensure-EnvKey -SourceKey $refName -Value $value -SourceLabel 'PowerShell environment (referenced by openclaw.json)' -TargetEnvPath $A0_ENV
        }
        elseif ($envValues.Contains($refName)) {
            continue
        }
        else {
            log_warning "Config references $refName; set $targetKey manually if needed"
        }
    }
}

if ($IncludeAuthProfiles) {
    if (Test-Path -LiteralPath $OPENCLAW_AUTH_PROFILES -PathType Leaf) {
        try {
            $authProfilesObject = (Get-Content -LiteralPath $OPENCLAW_AUTH_PROFILES -Raw) | ConvertFrom-Json
            foreach ($pair in (Get-KnownEnvPairsFromObject -Object $authProfilesObject -CandidateKeys $script:KnownEnvKeys)) {
                Ensure-EnvKey -SourceKey $pair.Key -Value $pair.Value -SourceLabel 'auth-profiles.json' -TargetEnvPath $A0_ENV
            }
        }
        catch {
            log_warning "Could not parse auth-profiles.json: $($_.Exception.Message)"
        }
    }
    else {
        log_skipped "No auth-profiles.json found at $OPENCLAW_AUTH_PROFILES"
    }
}
else {
    log_skipped 'auth-profiles.json scan disabled (use -IncludeAuthProfiles to enable)'
}

Write-Header 'Step 2: Discover Agents'

$agentsList = Get-NestedConfigValue -Object $ConfigObject -Path 'agents.list' -Default @()
$defaultWorkspace = [string](Get-NestedConfigValue -Object $ConfigObject -Path 'agents.defaults.workspace' -Default (Join-Path $OpenClawDir 'workspace'))
$defaultWorkspace = Expand-UserPath -PathValue $defaultWorkspace

$agentIds = @()
$agentNames = @()
$agentWorkspaces = @()
$agentProfileIds = @()

if (($agentsList -is [System.Collections.IEnumerable]) -and -not ($agentsList -is [string])) {
    $index = 0
    foreach ($agent in $agentsList) {
        if (-not (Test-IsConfigObject -Value $agent)) {
            continue
        }
        $aid = [string](Get-ConfigPropertyValue -Object $agent -Name 'id' -Default "agent$index")
        $name = [string](Get-ConfigPropertyValue -Object $agent -Name 'name' -Default $aid)
        $workspace = [string](Get-ConfigPropertyValue -Object $agent -Name 'workspace' -Default '')
        $agentIds += $aid
        $agentNames += $name
        $agentWorkspaces += $workspace
        $index++
    }
}

if ($agentIds.Count -eq 0) {
    $agentIds = @('main')
    $agentNames = @('Main')
    $agentWorkspaces = @('')
}

$usedProfileIds = @()
for ($i = 0; $i -lt $agentIds.Count; $i++) {
    $aid = $agentIds[$i]
    $workspace = $agentWorkspaces[$i]

    if ([string]::IsNullOrWhiteSpace($workspace)) {
        $workspaceCandidate = Join-Path $OpenClawDir "workspace-$aid"
        if (Test-Path -LiteralPath $workspaceCandidate -PathType Container) {
            $workspace = $workspaceCandidate
        }
        elseif (Test-Path -LiteralPath $defaultWorkspace -PathType Container) {
            $workspace = $defaultWorkspace
        }
        else {
            $workspace = Join-Path $OpenClawDir 'workspace'
        }
    }
    else {
        $workspace = Expand-UserPath -PathValue $workspace
    }

    $agentWorkspaces[$i] = $workspace

    $baseProfileId = Sanitize-AgentId -Value $aid
    $profileId = $baseProfileId
    $suffix = 2
    while ($usedProfileIds -contains $profileId) {
        $profileId = "$baseProfileId-$suffix"
        $suffix++
    }
    $usedProfileIds += $profileId
    $agentProfileIds += $profileId
}

print_info "Found $($agentIds.Count) agent(s):"
for ($i = 0; $i -lt $agentIds.Count; $i++) {
    $aid = $agentIds[$i]
    $name = $agentNames[$i]
    $workspace = $agentWorkspaces[$i]
    $profileId = $agentProfileIds[$i]
    if (Test-Path -LiteralPath $workspace -PathType Container) {
        Write-Host "   * $aid ($name) -> $workspace [profile: $profileId] OK"
    }
    else {
        Write-Host "   * $aid ($name) -> $workspace [profile: $profileId] MISSING"
    }
}

Write-Header 'Step 3: Agent Profiles and Prompt Content'

for ($i = 0; $i -lt $agentIds.Count; $i++) {
    $aid = $agentIds[$i]
    $workspace = $agentWorkspaces[$i]
    $name = $agentNames[$i]
    $profileId = $agentProfileIds[$i]

    if (-not (Test-Path -LiteralPath $workspace -PathType Container)) {
        log_warning "Workspace not found for agent '$aid': $workspace"
        continue
    }

    $agentDir = Join-Path $AgentZeroUsrDir "agents\$profileId"
    $promptsDir = Join-Path $agentDir 'prompts'
    $agentSkillsDir = Join-Path $agentDir 'skills'
    $agentWorkdir = Join-Path $MIGRATION_WORKDIR_ROOT $profileId
    New-Item -ItemType Directory -Force -Path $promptsDir, $agentSkillsDir, $agentWorkdir *> $null

    print_info "Migrating OpenClaw agent '$aid' into Agent Zero profile '$profileId'"

    $description = "Generated from OpenClaw agent '$aid'"
    $identityPath = Join-Path $workspace 'IDENTITY.md'
    if (Test-Path -LiteralPath $identityPath -PathType Leaf) {
        $firstLine = First-MeaningfulLine -Path $identityPath
        if (-not [string]::IsNullOrWhiteSpace($firstLine)) {
            $description = $firstLine
        }
    }

    $agentManifestPath = Join-Path $agentDir 'agent.json'
    if (-not (Test-Path -LiteralPath $agentManifestPath -PathType Leaf)) {
        Write-AgentManifest -Path $agentManifestPath -Title $name -Description $description
        log_migrated "agent.json for profile '$profileId'"
    }
    else {
        log_skipped "agent.json already exists for profile '$profileId'"
    }

    $roleSource = Join-Path $workspace 'SOUL.md'
    $roleTarget = Join-Path $promptsDir 'agent.system.main.role.md'
    if (Test-Path -LiteralPath $roleSource -PathType Leaf) {
        if (-not (Test-Path -LiteralPath $roleTarget -PathType Leaf)) {
            $content = @(
                '# Agent Role',
                '',
                '> Migrated from OpenClaw SOUL.md.',
                '',
                (Get-Content -LiteralPath $roleSource -Raw)
            ) -join [Environment]::NewLine
            Write-Utf8NoBom -Path $roleTarget -Content $content
            log_migrated "SOUL.md -> agent.system.main.role.md (profile '$profileId')"
        }
        else {
            log_skipped "agent.system.main.role.md already exists for profile '$profileId'"
        }
    }

    $promptincludeCreated = $false

    if (Test-Path -LiteralPath $identityPath -PathType Leaf) {
        $target = Join-Path $agentWorkdir 'identity.promptinclude.md'
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            $content = @(
                '# Agent Identity',
                '',
                '> Migrated from OpenClaw IDENTITY.md.',
                '',
                (Get-Content -LiteralPath $identityPath -Raw)
            ) -join [Environment]::NewLine
            Write-Utf8NoBom -Path $target -Content $content
            log_migrated "IDENTITY.md -> $target"
            $promptincludeCreated = $true
        }
        else {
            log_skipped "identity.promptinclude.md already exists for profile '$profileId'"
        }
    }

    $userPath = Join-Path $workspace 'USER.md'
    if (Test-Path -LiteralPath $userPath -PathType Leaf) {
        $target = Join-Path $agentWorkdir 'user.promptinclude.md'
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            $content = @(
                '# User Profile',
                '',
                '> Migrated from OpenClaw USER.md.',
                '',
                (Get-Content -LiteralPath $userPath -Raw)
            ) -join [Environment]::NewLine
            Write-Utf8NoBom -Path $target -Content $content
            log_migrated "USER.md -> $target"
            $promptincludeCreated = $true
        }
        else {
            log_skipped "user.promptinclude.md already exists for profile '$profileId'"
        }
    }

    $memoryPath = Join-Path $workspace 'MEMORY.md'
    if (Test-Path -LiteralPath $memoryPath -PathType Leaf) {
        $target = Join-Path $agentWorkdir 'memory.promptinclude.md'
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            $content = @(
                '# Long-Term Memory',
                '',
                '> Migrated from OpenClaw MEMORY.md.',
                '> Agent Zero will load this only when the active workdir or project points to this folder.',
                '',
                (Get-Content -LiteralPath $memoryPath -Raw)
            ) -join [Environment]::NewLine
            Write-Utf8NoBom -Path $target -Content $content
            log_migrated "MEMORY.md -> $target"
            $promptincludeCreated = $true
        }
        else {
            log_skipped "memory.promptinclude.md already exists for profile '$profileId'"
        }

        $memoryKnowledgeTarget = Join-Path $MEMORY_KNOWLEDGE_DIR "$profileId\MEMORY.md"
        if (-not (Test-Path -LiteralPath $memoryKnowledgeTarget -PathType Leaf)) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $memoryKnowledgeTarget) *> $null
            Copy-Item -LiteralPath $memoryPath -Destination $memoryKnowledgeTarget
            log_migrated "MEMORY.md -> knowledge\custom\openclaw-memory\$profileId\MEMORY.md"
        }
        else {
            log_skipped "Memory knowledge file already exists for profile '$profileId'"
        }
    }

    $promptincludeReadme = Join-Path $agentWorkdir 'README.md'
    if (-not (Test-Path -LiteralPath $promptincludeReadme -PathType Leaf)) {
        $content = @(
            '# OpenClaw Promptinclude Migration',
            '',
            ('This folder contains promptinclude files generated from OpenClaw workspace content for Agent Zero profile `' + $profileId + '`.' ),
            '',
            'To have Agent Zero load these files with the `_promptinclude` plugin, set the active workdir or project to this folder.',
            '',
            ('- OpenClaw agent id: `' + $aid + '`'),
            ('- Source workspace: `' + $workspace + '`')
        ) -join [Environment]::NewLine
        Write-Utf8NoBom -Path $promptincludeReadme -Content $content
        log_migrated "Promptinclude README for profile '$profileId'"
    }
    else {
        log_skipped "Promptinclude README already exists for profile '$profileId'"
    }

    $specificsTarget = Join-Path $promptsDir 'agent.system.main.specifics.md'
    $agentsMd = Join-Path $workspace 'AGENTS.md'
    $toolsMd = Join-Path $workspace 'TOOLS.md'
    if (-not (Test-Path -LiteralPath $specificsTarget -PathType Leaf)) {
        if ((Test-Path -LiteralPath $agentsMd -PathType Leaf) -or (Test-Path -LiteralPath $toolsMd -PathType Leaf) -or (Test-Path -LiteralPath $identityPath -PathType Leaf) -or (Test-Path -LiteralPath $userPath -PathType Leaf) -or (Test-Path -LiteralPath $memoryPath -PathType Leaf)) {
            $parts = New-Object System.Collections.Generic.List[string]
            $parts.Add('# Agent Specifics')
            $parts.Add('')
            $parts.Add(('> Generated from OpenClaw workspace `' + $workspace + '`.'))
            $parts.Add("> This Agent Zero profile preserves prompt content, but not OpenClaw auth/session/channel isolation.")
            $parts.Add('')

            if (Test-Path -LiteralPath $agentsMd -PathType Leaf) {
                $parts.Add('## Operating Instructions')
                $parts.Add('')
                $parts.Add((Get-Content -LiteralPath $agentsMd -Raw))
                $parts.Add('')
            }

            if (Test-Path -LiteralPath $toolsMd -PathType Leaf) {
                $parts.Add('## Local Tool Notes')
                $parts.Add('')
                $parts.Add((Get-Content -LiteralPath $toolsMd -Raw))
                $parts.Add('')
            }

            $parts.Add('## Migration Notes')
            $parts.Add('')
            $parts.Add(('- Promptinclude files were written to `' + $agentWorkdir + '`.'))
            $parts.Add('- To load `IDENTITY.md`, `USER.md`, and `MEMORY.md` automatically, point Agent Zero workdir or project to that folder.')
            $parts.Add(('- `memory/*.md` files were copied into `' + [System.IO.Path]::Combine($KNOWLEDGE_DIR, $profileId) + '` for searchability.'))
            if (Test-Path -LiteralPath $memoryPath -PathType Leaf) {
                $parts.Add(('- `MEMORY.md` was also copied into `' + [System.IO.Path]::Combine($MEMORY_KNOWLEDGE_DIR, $profileId, 'MEMORY.md') + '` for reference.'))
            }

            Write-Utf8NoBom -Path $specificsTarget -Content (($parts -join [Environment]::NewLine))
            log_migrated "agent.system.main.specifics.md for profile '$profileId'"
        }
    }
    else {
        log_skipped "agent.system.main.specifics.md already exists for profile '$profileId'"
    }

    $memoryDir = Join-Path $workspace 'memory'
    if (Test-Path -LiteralPath $memoryDir -PathType Container) {
        $copiedCount = 0
        $profileKnowledgeDir = Join-Path $KNOWLEDGE_DIR $profileId
        New-Item -ItemType Directory -Force -Path $profileKnowledgeDir *> $null
        foreach ($mdFile in (Get-ChildItem -LiteralPath $memoryDir -Filter '*.md' -File)) {
            $target = Join-Path $profileKnowledgeDir $mdFile.Name
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
                Copy-Item -LiteralPath $mdFile.FullName -Destination $target
                $copiedCount++
            }
        }

        if ($copiedCount -gt 0) {
            log_migrated "$copiedCount memory\*.md files -> knowledge\custom\openclaw\$profileId"
        }
        else {
            log_skipped "No new memory\*.md files for profile '$profileId'"
        }
    }

    if ($promptincludeCreated) {
        report_line "- Promptinclude workdir created for profile '$profileId': $agentWorkdir"
    }
}

Write-Header 'Step 4: Telegram'

$telegramPluginDir = Join-Path $AgentZeroUsrDir 'plugins\_telegram_integration'
$telegramConfigPath = Join-Path $telegramPluginDir 'config.json'
$telegramNotesPath = Join-Path $telegramPluginDir 'openclaw-migration-notes.md'
New-Item -ItemType Directory -Force -Path $telegramPluginDir *> $null

$telegramPayload = Build-TelegramPayload -ConfigObject $ConfigObject -EnvValues $envValues
$telegramBots = @($telegramPayload['bots'])

if ($telegramBots.Count -gt 0) {
    if (-not (Test-Path -LiteralPath $telegramConfigPath -PathType Leaf)) {
        Write-JsonFile -Path $telegramConfigPath -Payload ([ordered]@{ bots = $telegramBots })
        log_migrated "Telegram config -> $telegramConfigPath"
    }
    else {
        log_skipped "Telegram config already exists at $telegramConfigPath"
        log_warning "Review existing Telegram config manually: $telegramConfigPath"
    }

    $tgNotes = New-Object System.Collections.Generic.List[string]
    $tgNotes.Add('# OpenClaw Telegram Migration Notes')
    $tgNotes.Add('')
    $tgNotes.Add(('- Generated from: `' + $OPENCLAW_CONFIG + '`'))
    $tgNotes.Add(('- Output config: `' + $telegramConfigPath + '`'))
    $tgNotes.Add("- Bot count migrated: $($telegramBots.Count)")
    $tgNotes.Add('')
    $tgNotes.Add('## Manual Review Items')
    $tgNotes.Add('')
    $tgNotes.Add('- Per-group policies are mapped conservatively to Agent Zero `group_mode`.')
    $tgNotes.Add('- OpenClaw bindings, pairing, and DM policy do not map cleanly and require manual review.')
    $tgNotes.Add('- Session history and channel routing are not migrated.')
    $tgNotes.Add('')
    $tgNotes.Add('## Payload Notes')
    $tgNotes.Add('')

    $payloadNotes = @($telegramPayload['notes'])
    $payloadWarnings = @($telegramPayload['warnings'])
    if ($payloadNotes.Count -eq 0 -and $payloadWarnings.Count -eq 0) {
        $tgNotes.Add('- No extra migration notes emitted.')
    }
    else {
        foreach ($item in $payloadNotes) {
            $tgNotes.Add("- $item")
        }
        foreach ($item in $payloadWarnings) {
            $tgNotes.Add("- WARNING: $item")
        }
    }

    Write-Utf8NoBom -Path $telegramNotesPath -Content (($tgNotes -join [Environment]::NewLine) + [Environment]::NewLine)
    log_migrated "Telegram migration notes -> $telegramNotesPath"

    foreach ($warning in @($telegramPayload['warnings'])) {
        if (-not [string]::IsNullOrWhiteSpace($warning)) {
            log_warning $warning
        }
    }
}
else {
    log_skipped 'No Telegram bot tokens found to migrate'
}

Write-Header 'Step 5: Skills'

for ($i = 0; $i -lt $agentIds.Count; $i++) {
    $workspace = $agentWorkspaces[$i]
    $profileId = $agentProfileIds[$i]
    $workspaceSkillsDir = Join-Path $workspace 'skills'

    if (-not (Test-Path -LiteralPath $workspaceSkillsDir -PathType Container)) {
        continue
    }

    foreach ($skillDir in (Get-ChildItem -LiteralPath $workspaceSkillsDir -Directory)) {
        $target = Join-Path $AgentZeroUsrDir "agents\$profileId\skills\$($skillDir.Name)"
        Copy-DirectoryWithCollisionHandling -SourceDir $skillDir.FullName -TargetDir $target -Label "Workspace skill '$($skillDir.Name)' for profile '$profileId'"
    }
}

$globalSkillsDir = Join-Path $OpenClawDir 'skills'
if (Test-Path -LiteralPath $globalSkillsDir -PathType Container) {
    foreach ($skillDir in (Get-ChildItem -LiteralPath $globalSkillsDir -Directory)) {
        $target = Join-Path $AgentZeroUsrDir "skills\$($skillDir.Name)"
        Copy-DirectoryWithCollisionHandling -SourceDir $skillDir.FullName -TargetDir $target -Label "Global skill '$($skillDir.Name)'"
    }
}

Write-Header 'Migration Complete'
Write-Host ''
Write-Host ("  Migrated : {0}" -f $script:Migrated) -ForegroundColor Green
Write-Host ("  Skipped  : {0}" -f $script:Skipped) -ForegroundColor Cyan
Write-Host ("  Warnings : {0}" -f $script:Warnings) -ForegroundColor Yellow
Write-Host ''

$logLines = @(
    '# OpenClaw -> Agent Zero Migration Log',
    "Date: $([DateTimeOffset]::Now.ToString('o'))",
    "Source: $OpenClawDir",
    "Target: $AgentZeroUsrDir",
    "Config parser: $ConfigParseMode",
    "Migrated: $($script:Migrated)",
    "Skipped: $($script:Skipped)",
    "Warnings: $($script:Warnings)"
)
Write-Utf8NoBom -Path $MIGRATION_LOG -Content (($logLines -join [Environment]::NewLine) + [Environment]::NewLine)

report_line ''
report_line '## Manual Follow-Up'
report_line ''
report_line ('- Set Agent Zero workdir or project to one of the generated folders under `' + $MIGRATION_WORKDIR_ROOT + '` if you want the migrated `*.promptinclude.md` files loaded automatically.')
report_line '- Review Telegram routing, DM policy, bindings, and webhook details before enabling the plugin.'
report_line '- OpenClaw OAuth profiles, session history, channel state, and agent isolation are not fully portable.'
report_line '- Review migrated profiles under Settings -> Agents and verify prompts, skills, and model settings.'

print_info "Migration log: $MIGRATION_LOG"
print_info "Migration report: $script:MigrationReport"
Write-Host ''

if ($script:Migrated -gt 0) {
    Write-Host 'Next steps:' -ForegroundColor White
    Write-Host "  1. Review generated profiles under Settings -> Agents"
    Write-Host "  2. Point Agent Zero workdir/project to $MIGRATION_WORKDIR_ROOT\<profile-id> if you want promptinclude behavior"
    Write-Host "  3. Review knowledge files under $KNOWLEDGE_DIR and $MEMORY_KNOWLEDGE_DIR"
    Write-Host "  4. Review $telegramConfigPath and $telegramNotesPath before enabling Telegram"
    Write-Host ''
}

if ($script:Warnings -gt 0) {
    Write-Host 'Review warnings above for items needing manual attention.' -ForegroundColor Yellow
    Write-Host ''
}

Write-Host 'Not migrated automatically:' -ForegroundColor White
Write-Host '  * OpenClaw auth/session/channel isolation semantics'
Write-Host '  * OAuth profiles beyond API-key-style secrets'
Write-Host '  * Session history / transcripts'
Write-Host '  * Channel bindings / agent routing'
Write-Host '  * Heartbeat / cron schedules (use A0 Task Scheduler)'
