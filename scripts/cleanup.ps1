$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$AwsProfile = 'aws-3-tier-learning'
$Region = 'ap-south-1'
$stacks = @(
    'aws-3-tier-web',
    'aws-3-tier-app',
    'aws-3-tier-database',
    'aws-3-tier-security',
    'aws-3-tier-network'
)

function Invoke-Aws {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    & aws @Arguments --profile $AwsProfile --region $Region
    if ($LASTEXITCODE -ne 0) { throw "AWS CLI failed: aws $($Arguments -join ' ')" }
}

foreach ($stack in $stacks) {
    Write-Host "Checking project stack $stack ..." -ForegroundColor Cyan
    & aws cloudformation describe-stacks --stack-name $stack --profile $AwsProfile --region $Region 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Stack $stack does not exist; skipping." -ForegroundColor Yellow
        continue
    }

    Write-Host "Deleting $stack ..." -ForegroundColor Yellow
    Invoke-Aws cloudformation delete-stack --stack-name $stack
    Invoke-Aws cloudformation wait stack-delete-complete --stack-name $stack
    Write-Host "Deleted $stack." -ForegroundColor Green
}

Write-Host 'Project stack cleanup complete. No unrelated resources were targeted.' -ForegroundColor Green
