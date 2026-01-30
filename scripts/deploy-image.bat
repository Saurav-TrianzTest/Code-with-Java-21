@echo off
setlocal enabledelayedexpansion

echo ================================================
echo    AWS ECS Fargate Deployment Script
echo ================================================
echo.

set PROJECT_NAME=comp-jv21pat
set TASK_FAMILY=!PROJECT_NAME!-task
set SERVICE_NAME=!PROJECT_NAME!-service

set /p AWS_REGION="Enter AWS Region (e.g., us-east-1): "
set /p CLUSTER_NAME="Enter ECS Cluster Name: "
set /p VPC_ID="Enter VPC ID: "
set /p SUBNETS_INPUT="Enter Subnet IDs (comma-separated, at least 2): "
set /p SECURITY_GROUP="Enter Security Group ID: "
set /p IMAGE_URI="Enter Docker Image URI: "

REM Parse subnets
for /f "tokens=1,2 delims=," %%a in ("!SUBNETS_INPUT!") do (
    set SUBNET_1=%%a
    set SUBNET_2=%%b
)

REM Trim spaces
set SUBNET_1=!SUBNET_1: =!
set SUBNET_2=!SUBNET_2: =!

if "!SUBNET_1!"=="" (
    echo Error: At least 2 subnets are required
    exit /b 1
)

if "!SUBNET_2!"=="" (
    echo Error: At least 2 subnets are required
    exit /b 1
)

echo.
echo Getting AWS Account ID...
for /f "delims=" %%i in ('aws sts get-caller-identity --query Account --output text --region !AWS_REGION!') do set ACCOUNT_ID=%%i

if "!ACCOUNT_ID!"=="" (
    echo Error: Failed to get AWS Account ID
    exit /b 1
)

echo AWS Account ID: !ACCOUNT_ID!
echo.

echo Checking if ECS cluster exists...
aws ecs describe-clusters --clusters !CLUSTER_NAME! --region !AWS_REGION! >nul 2>&1
if !ERRORLEVEL! neq 0 (
    echo Creating ECS cluster: !CLUSTER_NAME!
    aws ecs create-cluster --cluster-name !CLUSTER_NAME! --region !AWS_REGION!
    echo Cluster created successfully
)

echo Cluster: !CLUSTER_NAME! is ready
echo.

echo Creating CloudWatch log group...
set LOG_GROUP=/ecs/!PROJECT_NAME!
aws logs create-log-group --log-group-name !LOG_GROUP! --region !AWS_REGION! 2>nul
echo Log group: !LOG_GROUP!
echo.

set /p NEED_LB="Do you need a load balancer for this service? (y/n): "

set LB_ARN=
set TARGET_GROUP_ARN=
set LB_DNS=

if /i "!NEED_LB!"=="y" (
    echo.
    echo Creating Application Load Balancer...
    
    set LB_NAME=!PROJECT_NAME!-alb
    aws elbv2 create-load-balancer --name !LB_NAME! --subnets !SUBNET_1! !SUBNET_2! --security-groups !SECURITY_GROUP! --scheme internet-facing --type application --region !AWS_REGION! >nul 2>&1
    
    for /f "delims=" %%i in ('aws elbv2 describe-load-balancers --names !LB_NAME! --region !AWS_REGION! --query "LoadBalancers[0].LoadBalancerArn" --output text 2^>nul') do set LB_ARN=%%i
    for /f "delims=" %%i in ('aws elbv2 describe-load-balancers --names !LB_NAME! --region !AWS_REGION! --query "LoadBalancers[0].DNSName" --output text 2^>nul') do set LB_DNS=%%i
    
    echo Load Balancer: !LB_DNS!
    
    echo Creating Target Group...
    set TG_NAME=!PROJECT_NAME!-tg
    aws elbv2 create-target-group --name !TG_NAME! --protocol HTTP --port 8080 --vpc-id !VPC_ID! --target-type ip --health-check-enabled --health-check-protocol HTTP --health-check-path /health --region !AWS_REGION! >nul 2>&1
    
    for /f "delims=" %%i in ('aws elbv2 describe-target-groups --names !TG_NAME! --region !AWS_REGION! --query "TargetGroups[0].TargetGroupArn" --output text 2^>nul') do set TARGET_GROUP_ARN=%%i
    
    echo Target Group: !TARGET_GROUP_ARN!
    
    echo Creating ALB Listener...
    aws elbv2 create-listener --load-balancer-arn !LB_ARN! --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=!TARGET_GROUP_ARN! --region !AWS_REGION! >nul 2>&1
    
    echo Load Balancer setup complete
    echo.
)

echo Preparing task definition...
copy ecs\task-definition.json %TEMP%\task-definition-temp.json >nul

powershell -Command "(Get-Content %TEMP%\task-definition-temp.json) -replace '{{IMAGE_URI}}', '!IMAGE_URI!' | Set-Content %TEMP%\task-definition-temp.json"
powershell -Command "(Get-Content %TEMP%\task-definition-temp.json) -replace '{{AWS_REGION}}', '!AWS_REGION!' | Set-Content %TEMP%\task-definition-temp.json"
powershell -Command "(Get-Content %TEMP%\task-definition-temp.json) -replace '{{ACCOUNT_ID}}', '!ACCOUNT_ID!' | Set-Content %TEMP%\task-definition-temp.json"

echo Registering task definition...
for /f "delims=" %%i in ('aws ecs register-task-definition --cli-input-json file://%TEMP%/task-definition-temp.json --region !AWS_REGION! --query "taskDefinition.taskDefinitionArn" --output text') do set TASK_DEF_ARN=%%i

if "!TASK_DEF_ARN!"=="" (
    echo Error: Failed to register task definition
    exit /b 1
)

echo Task definition registered: !TASK_DEF_ARN!
echo.

echo Preparing service definition...
copy ecs\service-definition.json %TEMP%\service-definition-temp.json >nul

powershell -Command "(Get-Content %TEMP%\service-definition-temp.json) -replace '{{CLUSTER_NAME}}', '!CLUSTER_NAME!' | Set-Content %TEMP%\service-definition-temp.json"
powershell -Command "(Get-Content %TEMP%\service-definition-temp.json) -replace '{{SUBNET_1}}', '!SUBNET_1!' | Set-Content %TEMP%\service-definition-temp.json"
powershell -Command "(Get-Content %TEMP%\service-definition-temp.json) -replace '{{SUBNET_2}}', '!SUBNET_2!' | Set-Content %TEMP%\service-definition-temp.json"
powershell -Command "(Get-Content %TEMP%\service-definition-temp.json) -replace '{{SECURITY_GROUP}}', '!SECURITY_GROUP!' | Set-Content %TEMP%\service-definition-temp.json"

if not "!TARGET_GROUP_ARN!"=="" (
    echo Adding load balancer configuration...
    powershell -Command "$json = Get-Content %TEMP%\service-definition-temp.json | ConvertFrom-Json; $json | Add-Member -Type NoteProperty -Name 'loadBalancers' -Value @(@{'targetGroupArn'='!TARGET_GROUP_ARN!';'containerName'='comp-jv21pat';'containerPort'=8080}) -Force; $json | Add-Member -Type NoteProperty -Name 'healthCheckGracePeriodSeconds' -Value 300 -Force; $json | ConvertTo-Json -Depth 10 | Set-Content %TEMP%\service-definition-temp.json"
) else (
    echo Removing load balancer configuration...
    powershell -Command "$json = Get-Content %TEMP%\service-definition-temp.json | ConvertFrom-Json; $json.PSObject.Properties.Remove('loadBalancers'); $json.PSObject.Properties.Remove('healthCheckGracePeriodSeconds'); $json | ConvertTo-Json -Depth 10 | Set-Content %TEMP%\service-definition-temp.json"
)

echo Checking if service exists...
for /f "delims=" %%i in ('aws ecs describe-services --cluster !CLUSTER_NAME! --services !SERVICE_NAME! --region !AWS_REGION! --query "services[?status==`ACTIVE`].serviceName" --output text 2^>nul') do set EXISTING_SERVICE=%%i

if "!EXISTING_SERVICE!"=="" (
    echo Creating new ECS service...
    aws ecs create-service --cli-input-json file://%TEMP%/service-definition-temp.json --region !AWS_REGION!
    echo Service created: !SERVICE_NAME!
) else (
    echo Updating existing ECS service...
    aws ecs update-service --cluster !CLUSTER_NAME! --service !SERVICE_NAME! --task-definition !TASK_DEF_ARN! --force-new-deployment --region !AWS_REGION!
    echo Service updated: !SERVICE_NAME!
)

echo.
echo Waiting for service to become stable...
aws ecs wait services-stable --cluster !CLUSTER_NAME! --services !SERVICE_NAME! --region !AWS_REGION!

echo.
echo ================================================
echo    Deployment Complete!
echo ================================================
echo.
echo Cluster: !CLUSTER_NAME!
echo Service: !SERVICE_NAME!
echo Task Definition: !TASK_DEF_ARN!
echo CloudWatch Logs: !LOG_GROUP!

if not "!LB_DNS!"=="" (
    echo Load Balancer: http://!LB_DNS!
)

echo.
echo Service Status:
aws ecs describe-services --cluster !CLUSTER_NAME! --services !SERVICE_NAME! --region !AWS_REGION! --query "services[0].[serviceName,status,runningCount,desiredCount]" --output table

echo.
echo To view logs:
echo   aws logs tail !LOG_GROUP! --follow --region !AWS_REGION!
echo.
echo To scale the service:
echo   aws ecs update-service --cluster !CLUSTER_NAME! --service !SERVICE_NAME! --desired-count COUNT --region !AWS_REGION!
echo.

del %TEMP%\task-definition-temp.json >nul 2>&1
del %TEMP%\service-definition-temp.json >nul 2>&1

echo Deployment completed successfully!
echo.

endlocal