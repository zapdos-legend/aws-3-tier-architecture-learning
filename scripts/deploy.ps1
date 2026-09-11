$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$AwsProfile = 'aws-3-tier-learning'
$Region = 'ap-south-1'
$Root = Split-Path -Parent $PSScriptRoot

function Invoke-Aws {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    & aws @Arguments --profile $AwsProfile --region $Region
    if ($LASTEXITCODE -ne 0) { throw "AWS CLI failed: aws $($Arguments -join ' ')" }
}

function Test-Template([string]$Path) {
    Write-Host "Validating $Path ..." -ForegroundColor Cyan
    Invoke-Aws cloudformation validate-template --template-body "file://$Path" | Out-Null
}

function Deploy-Stack([string]$Name, [string]$Path, [string[]]$Parameters = @()) {
    Write-Host "Deploying $Name ..." -ForegroundColor Green
    $args = @('cloudformation', 'deploy', '--stack-name', $Name, '--template-file', $Path,
              '--no-fail-on-empty-changeset', '--capabilities', 'CAPABILITY_NAMED_IAM')
    if ($Parameters.Count -gt 0) { $args += '--parameter-overrides'; $args += $Parameters }
    Invoke-Aws @args
}

function Get-StackResourceId([string]$Stack, [string]$LogicalId) {
    $value = & aws cloudformation describe-stack-resource --stack-name $Stack `
        --logical-resource-id $LogicalId --query 'StackResourceDetail.PhysicalResourceId' `
        --output text --profile $AwsProfile --region $Region
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value) -or $value -eq 'None') {
        throw "Could not find $LogicalId in $Stack."
    }
    return $value.Trim()
}

$templates = @(
    Join-Path $Root 'infrastructure/01-network.yaml'
    Join-Path $Root 'infrastructure/02-security.yaml'
    Join-Path $Root 'infrastructure/03-database.yaml'
    Join-Path $Root 'infrastructure/04-app-tier.yaml'
    Join-Path $Root 'infrastructure/05-web-tier.yaml'
)

foreach ($template in $templates) {
    if (-not (Test-Path $template)) { throw "Required template not found: $template" }
    Test-Template $template
}

$dbUsername = Read-Host 'Database master username'
$securePassword = Read-Host 'Database master password' -AsSecureString
$passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
try {
    $dbPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
    Deploy-Stack 'aws-3-tier-network' $templates[0]
    Deploy-Stack 'aws-3-tier-security' $templates[1]
    $databaseSg = Get-StackResourceId 'aws-3-tier-security' 'DatabaseSecurityGroup'
    $internalAlbSg = Get-StackResourceId 'aws-3-tier-security' 'InternalALBSecurityGroup'
    $appSg = Get-StackResourceId 'aws-3-tier-security' 'AppTierSecurityGroup'
    $publicAlbSg = Get-StackResourceId 'aws-3-tier-security' 'PublicALBSecurityGroup'
    $webSg = Get-StackResourceId 'aws-3-tier-security' 'WebTierSecurityGroup'

    Deploy-Stack 'aws-3-tier-database' $templates[2] @(
        "DBUsername=$dbUsername", "DBPassword=$dbPassword", "DatabaseSecurityGroupId=$databaseSg")
    Deploy-Stack 'aws-3-tier-app' $templates[3] @(
        "InternalALBSecurityGroupId=$internalAlbSg", "AppTierSecurityGroupId=$appSg")
    Deploy-Stack 'aws-3-tier-web' $templates[4] @(
        "PublicALBSecurityGroupId=$publicAlbSg", "WebTierSecurityGroupId=$webSg")
}
finally {
    if ($passwordPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
    }
    Remove-Variable dbPassword -ErrorAction SilentlyContinue
}

Write-Host 'All project stacks deployed successfully.' -ForegroundColor Green
