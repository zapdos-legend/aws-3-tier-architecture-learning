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

function Deploy-DatabaseStack([string]$Path, [string]$Username, [SecureString]$Password, [string]$SecurityGroupId) {
    # A temporary parameter file keeps the password out of the process command line.
    # AWS output is suppressed for this one operation so neither native errors nor
    # PowerShell exceptions can reproduce a rejected parameter value.
    $parameterFile = Join-Path ([IO.Path]::GetTempPath()) ("aws-3-tier-db-{0}.json" -f [guid]::NewGuid())
    $stdoutFile = "$parameterFile.stdout"
    $stderrFile = "$parameterFile.stderr"
    $pointer = [IntPtr]::Zero
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        # cloudformation deploy models --parameter-overrides as a list of Key=Value
        # strings. AWS CLI v2 can load that list from a JSON file, leaving only the
        # non-sensitive file name visible in the process arguments.
        $parameterValues = @(
            "DBUsername=$Username"
            "DBPassword=$plainPassword"
            "DatabaseSecurityGroupId=$SecurityGroupId"
        )
        $parameterJson = ConvertTo-Json -InputObject $parameterValues -Compress
        [IO.File]::WriteAllText($parameterFile, $parameterJson, [Text.UTF8Encoding]::new($false))
        Remove-Variable plainPassword -ErrorAction SilentlyContinue
        Remove-Variable parameterValues -ErrorAction SilentlyContinue
        Remove-Variable parameterJson -ErrorAction SilentlyContinue

        Write-Host 'Deploying aws-3-tier-database (sensitive output hidden) ...' -ForegroundColor Green
        & aws cloudformation deploy --stack-name aws-3-tier-database --template-file $Path `
            --no-fail-on-empty-changeset --capabilities CAPABILITY_NAMED_IAM `
            --parameter-overrides "file://$parameterFile" --profile $AwsProfile --region $Region `
            1>$stdoutFile 2>$stderrFile
        if ($LASTEXITCODE -ne 0) {
            throw 'Database stack deployment failed. Review the CloudFormation stack events in the AWS console; sensitive CLI output was intentionally hidden.'
        }
    }
    finally {
        if ($pointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
        Remove-Variable plainPassword -ErrorAction SilentlyContinue
        Remove-Variable parameterValues -ErrorAction SilentlyContinue
        Remove-Variable parameterJson -ErrorAction SilentlyContinue
        foreach ($file in @($parameterFile, $stdoutFile, $stderrFile)) {
            if (Test-Path -LiteralPath $file) {
                # Best effort overwrite before removal; the files live only for this command.
                Set-Content -LiteralPath $file -Value '' -NoNewline -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            }
        }
    }
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

function Get-StackOutput([string]$Stack, [string]$OutputKey) {
    $query = "Stacks[0].Outputs[?OutputKey=='$OutputKey'].OutputValue | [0]"
    $value = & aws cloudformation describe-stacks --stack-name $Stack --query $query `
        --output text --profile $AwsProfile --region $Region
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value) -or $value -eq 'None') {
        throw "Could not find output $OutputKey in $Stack."
    }
    return $value.Trim()
}

function Get-Export([string]$Name) {
    $query = "Exports[?Name=='$Name'].Value | [0]"
    $value = & aws cloudformation list-exports --query $query --output text `
        --profile $AwsProfile --region $Region
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value) -or $value -eq 'None') {
        throw "Could not find CloudFormation export $Name."
    }
    return $value.Trim()
}

function Wait-TargetGroupHealthy([string]$Name, [string]$TargetGroupArn, [int]$TimeoutMinutes = 30) {
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    Write-Host "Waiting for the $Name target group to become healthy ..." -ForegroundColor Cyan
    while ((Get-Date) -lt $deadline) {
        $states = & aws elbv2 describe-target-health --target-group-arn $TargetGroupArn `
            --query 'TargetHealthDescriptions[].TargetHealth.State' --output text `
            --profile $AwsProfile --region $Region
        if ($LASTEXITCODE -ne 0) { throw "Could not read $Name target health." }
        $stateList = @($states -split '\s+' | Where-Object { $_ })
        if ($stateList.Count -gt 0 -and @($stateList | Where-Object { $_ -ne 'healthy' }).Count -eq 0) {
            Write-Host "$Name target group is healthy." -ForegroundColor Green
            return
        }
        Start-Sleep -Seconds 15
    }
    throw "$Name target group did not become healthy within $TimeoutMinutes minutes. Check target health and EC2 user-data logs."
}

function Get-SubnetRouteTable([string]$SubnetId) {
    $value = & aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$SubnetId" `
        --query 'RouteTables[0].RouteTableId' --output text --profile $AwsProfile --region $Region
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value) -or $value -eq 'None') {
        throw "Could not find an explicit route table association for subnet $SubnetId."
    }
    return $value.Trim()
}

$artifactTemplate = Join-Path $Root 'infrastructure/00-artifacts.yaml'
$networkTemplate = Join-Path $Root 'infrastructure/01-network.yaml'
$securityTemplate = Join-Path $Root 'infrastructure/02-security.yaml'
$databaseTemplate = Join-Path $Root 'infrastructure/03-database.yaml'
$appTemplate = Join-Path $Root 'infrastructure/04-app-tier.yaml'
$webTemplate = Join-Path $Root 'infrastructure/05-web-tier.yaml'

foreach ($template in @($networkTemplate, $securityTemplate, $artifactTemplate, $databaseTemplate, $appTemplate, $webTemplate)) {
    if (-not (Test-Path $template)) { throw "Required project template not found: $template" }
    Test-Template $template
}

function Initialize-BaseStack([string]$Name, [string]$Path) {
    if (Test-Path $Path) {
        Test-Template $Path
        Deploy-Stack $Name $Path
        return
    }
    Write-Host "$Path is not present; verifying the existing $Name stack ..." -ForegroundColor Yellow
    & aws cloudformation describe-stacks --stack-name $Name --profile $AwsProfile --region $Region | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "$Name is not deployed and its template is not present."
    }
}

$dbUsername = Read-Host 'Database master username'
$securePassword = Read-Host 'Database master password' -AsSecureString
$artifactDirectory = $null
try {
    Initialize-BaseStack 'aws-3-tier-network' $networkTemplate
    Initialize-BaseStack 'aws-3-tier-security' $securityTemplate
    Deploy-Stack 'aws-3-tier-artifacts' $artifactTemplate
    $artifactBucket = Get-StackOutput 'aws-3-tier-artifacts' 'ArtifactsBucketName'
    $uncommitted = & git -C $Root status --porcelain -- application
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the application Git working tree.' }
    if ($uncommitted) {
        throw 'Application files have uncommitted changes. Commit them before packaging a deployment.'
    }
    $artifactVersion = (& git -C $Root rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Could not determine the Git commit for artifact versioning.' }
    $artifactDirectory = Join-Path ([IO.Path]::GetTempPath()) "aws-3-tier-$artifactVersion"
    New-Item -ItemType Directory -Force -Path $artifactDirectory | Out-Null
    $appArchive = Join-Path $artifactDirectory 'app-tier.zip'
    $webArchive = Join-Path $artifactDirectory 'web-tier.zip'
    & git -C $Root archive --format=zip --output=$appArchive "HEAD:application/app-tier"
    if ($LASTEXITCODE -ne 0) { throw 'Could not package the app-tier source.' }
    & git -C $Root archive --format=zip --output=$webArchive "HEAD:application/web-tier"
    if ($LASTEXITCODE -ne 0) { throw 'Could not package the web-tier source.' }
    Invoke-Aws s3 cp $appArchive "s3://$artifactBucket/app-tier/$artifactVersion.zip" `
        --sse AES256 --only-show-errors
    Invoke-Aws s3 cp $webArchive "s3://$artifactBucket/web-tier/$artifactVersion.zip" `
        --sse AES256 --only-show-errors

    $publicSubnet = Get-Export 'aws-3-tier-PublicWebSubnetAZ1'
    $privateSubnet1 = Get-Export 'aws-3-tier-PrivateAppSubnetAZ1'
    $privateRouteTable = Get-SubnetRouteTable $privateSubnet1
    $databaseSg = Get-StackResourceId 'aws-3-tier-security' 'DatabaseSecurityGroup'
    $internalAlbSg = Get-StackResourceId 'aws-3-tier-security' 'InternalALBSecurityGroup'
    $appSg = Get-StackResourceId 'aws-3-tier-security' 'AppTierSecurityGroup'
    $publicAlbSg = Get-StackResourceId 'aws-3-tier-security' 'PublicALBSecurityGroup'
    $webSg = Get-StackResourceId 'aws-3-tier-security' 'WebTierSecurityGroup'

    Deploy-DatabaseStack $databaseTemplate $dbUsername $securePassword $databaseSg
    Deploy-Stack 'aws-3-tier-app' $appTemplate @(
        "InternalALBSecurityGroupId=$internalAlbSg", "AppTierSecurityGroupId=$appSg",
        "PublicSubnetId=$publicSubnet", "PrivateAppRouteTable=$privateRouteTable",
        "ArtifactVersion=$artifactVersion")
    Deploy-Stack 'aws-3-tier-web' $webTemplate @(
        "PublicALBSecurityGroupId=$publicAlbSg", "WebTierSecurityGroupId=$webSg",
        "ArtifactVersion=$artifactVersion")
}
finally {
    if ($null -ne $artifactDirectory) {
        Remove-Item -Recurse -Force $artifactDirectory -ErrorAction SilentlyContinue
    }
}

$appTargetGroup = Get-StackOutput 'aws-3-tier-app' 'AppTargetGroupArn'
$webTargetGroup = Get-StackResourceId 'aws-3-tier-web' 'WebTargetGroup'
Wait-TargetGroupHealthy 'app-tier' $appTargetGroup
Wait-TargetGroupHealthy 'web-tier' $webTargetGroup
$publicUrl = Get-StackOutput 'aws-3-tier-web' 'PublicLoadBalancerUrl'
Write-Host "DEMO READY: $publicUrl" -ForegroundColor Green
