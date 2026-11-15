param(
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

$requiredCommands = @(
    'login',
    'use',
    'current',
    'list',
    'status',
    'status-all',
    'path',
    'env',
    'run'
)

function Get-SwitchCommands {
    param(
        [string]$Path,
        [System.Collections.Generic.HashSet[string]]$Visited
    )

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    if ($Visited.Contains($resolvedPath)) {
        return [string[]]@()
    }
    [void]$Visited.Add($resolvedPath)

    $text = Get-Content -LiteralPath $resolvedPath -Raw
    $wrapperMatch = [regex]::Match($text, '(?m)^\s*\$target\s*=\s*Join-Path\s+\$PSScriptRoot\s+''([^'']+)''\s*$')
    if ($wrapperMatch.Success -and $text -match '&\s+\$target\s+@args') {
        $targetPath = Join-Path (Split-Path -Parent $resolvedPath) $wrapperMatch.Groups[1].Value
        return Get-SwitchCommands -Path $targetPath -Visited $Visited
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($resolvedPath, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        throw "PowerShell parse failed for $resolvedPath with $($errors.Count) error(s)."
    }

    $commands = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $switches = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.SwitchStatementAst] }, $true)
    foreach ($switchStatement in $switches) {
        foreach ($clause in $switchStatement.Clauses) {
            foreach ($condition in $clause.Item1) {
                $strings = $condition.FindAll({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)
                foreach ($stringAst in $strings) {
                    $value = $stringAst.Value
                    if ($value -match '^[a-z0-9][a-z0-9-]*$') {
                        [void]$commands.Add($value.ToLowerInvariant())
                    }
                }
            }
        }
    }

    return [string[]]($commands | Sort-Object)
}

$root = $PSScriptRoot
$helpers = @(Get-ChildItem -LiteralPath $root -Filter '*-account.ps1' -File | Sort-Object Name)
$rows = foreach ($helper in $helpers) {
    $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $commands = @(Get-SwitchCommands -Path $helper.FullName -Visited $visited)
    $missing = @($requiredCommands | Where-Object { $commands -notcontains $_ })
    $isWrapper = $visited.Count -gt 1
    [pscustomobject]@{
        Helper = $helper.Name
        Status = if ($missing.Count -eq 0) { if ($isWrapper) { 'PASS(wrapper)' } else { 'PASS' } } else { 'FAIL' }
        Missing = if ($missing.Count -gt 0) { $missing -join ', ' } else { '' }
        Commands = $commands -join ', '
    }
}

if ($Json) {
    $rows | ConvertTo-Json -Depth 6
} else {
    $rows | Format-Table Helper, Status, Missing -AutoSize
}

if (@($rows | Where-Object { $_.Status -eq 'FAIL' }).Count -gt 0) {
    exit 1
}

