$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$AwsProfile = 'aws-3-tier-learning'
$Region = 'ap-south-1'
$stacks = @(
    'aws-3-tier-web',
    'aws-3-tier-app',
    'aws-3-tier-database',
    'aws-3-tier-artifacts',
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

    # CloudFormation can delete the project artifact bucket only after its objects
    # are removed. This command is deliberately scoped to that stack's bucket.
    if ($stack -eq 'aws-3-tier-artifacts') {
        $query = "Stacks[0].Outputs[?OutputKey=='ArtifactsBucketName'].OutputValue | [0]"
        $bucket = & aws cloudformation describe-stacks --stack-name $stack --query $query `
            --output text --profile $AwsProfile --region $Region
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($bucket) -or $bucket -eq 'None') {
            throw 'Could not resolve the project artifact bucket; refusing an unscoped delete.'
        }
        Write-Host "Emptying project artifact bucket $bucket ..." -ForegroundColor Yellow
        Invoke-Aws s3 rm "s3://$bucket" --recursive --only-show-errors
    }

    Write-Host "Deleting $stack ..." -ForegroundColor Yellow
    Invoke-Aws cloudformation delete-stack --stack-name $stack
    Invoke-Aws cloudformation wait stack-delete-complete --stack-name $stack
    Write-Host "Deleted $stack." -ForegroundColor Green
}

Write-Host 'Project stack cleanup complete. No unrelated resources were targeted.' -ForegroundColor Green
