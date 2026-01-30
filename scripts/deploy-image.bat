@echo off
setlocal enabledelayedexpansion

echo ========================================
echo AWS ECS Fargate Deployment Script
echo ========================================
echo.

REM Project configuration
set PROJECT_NAME=comp-jv21pat
set TASK_FAMILY=!PROJECT_NAME!-task
set SERVICE_NAME=!PROJECT_NAME!-service
set CONTAINER_NAME=!PROJECT_NAME!
set CONTAINER_PORT=8080

REM Prompt for AWS configuration
echo === AWS Configuration ===
set /p AWS_REGION="Enter AWS Region (e.g., us-east-1): "
set AWS_DEFAULT_REGION=!AWS_REGION!

set /p CLUSTER_NAME="Enter ECS Cluster Name: "

REM Get AWS Account ID
echo.
echo Retrieving AWS Account ID...
for /f "delims=" %%a in ('aws sts get-caller-identity --query Account --output text') do set ACCOUNT_ID=%%a
if "!ACCOUNT_ID!"=="" (
    echo ERROR: Failed to retrieve AWS Account ID
    exit /b 1
)
echo AWS Account ID: !ACCOUNT_ID!

REM Check if cluster exists
echo.
echo Checking ECS cluster...
aws ecs describe-clusters --clusters "!CLUSTER_NAME!" --query "clusters[0].clusterName" --output text 2>nul | findstr /C:"!CLUSTER_NAME!" >nul
if !ERRORLEVEL! neq 0 (
    echo Creating ECS cluster: !CLUSTER_NAME!
    aws ecs create-cluster --cluster-name "!CLUSTER_NAME!" --region "!AWS_REGION!"
)

REM Network configuration
echo.
echo === Network Configuration ===
set /p VPC_ID="Enter VPC ID: "
set /p SUBNETS_INPUT="Enter Subnet IDs (comma-separated, at least 2): "
set /p SECURITY_GROUP="Enter Security Group ID: "

REM Parse subnets
for /f "tokens=1,2 delims=," %%a in ("!SUBNETS_INPUT!") do (
    set SUBNET_1=%%a
    set SUBNET_2=%%b
)
set SUBNET_1=!SUBNET_1: =!
set SUBNET_2=!SUBNET_2: =!

if "!SUBNET_1!"==" " (
    echo ERROR: At least 2 subnets are required
    exit /b 1
)
if "!SUBNET_2!"==" " (
    echo ERROR: At least 2 subnets are required
    exit /b 1
)

REM Image configuration
echo.
echo === Docker Image Configuration ===
set /p IMAGE_URI="Enter ECR Image URI: "

if "!IMAGE_URI!"=="" (
    echo ERROR: Image URI is required
    exit /b 1
)

REM Load balancer configuration
echo.
set /p NEED_LB="Do you need a load balancer for this service? (y/n): "

if /i "!NEED_LB!"=="y" (
    echo.
    echo Creating Application Load Balancer and Target Group...
    
    set TARGET_GROUP_NAME=!PROJECT_NAME!-tg
    echo Creating target group: !TARGET_GROUP_NAME!
    
    for /f "delims=" %%a in ('aws elbv2 create-target-group --name "!TARGET_GROUP_NAME!" --protocol HTTP --port !CONTAINER_PORT! --vpc-id "!VPC_ID!" --target-type ip --health-check-path "/health" --region "!AWS_REGION!" --query "TargetGroups[0].TargetGroupArn" --output text 2^>nul') do set TARGET_GROUP_ARN=%%a
    
    if "!TARGET_GROUP_ARN!"=="" (
        for /f "delims=" %%a in ('aws elbv2 describe-target-groups --names "!TARGET_GROUP_NAME!" --region "!AWS_REGION!" --query "TargetGroups[0].TargetGroupArn" --output text') do set TARGET_GROUP_ARN=%%a
    )
    
    echo Target Group ARN: !TARGET_GROUP_ARN!
    
    set ALB_NAME=!PROJECT_NAME!-alb
    echo Creating Application Load Balancer: !ALB_NAME!
    
    for /f "delims=" %%a in ('aws elbv2 create-load-balancer --name "!ALB_NAME!" --subnets "!SUBNET_1!" "!SUBNET_2!" --security-groups "!SECURITY_GROUP!" --scheme internet-facing --type application --region "!AWS_REGION!" --query "LoadBalancers[0].LoadBalancerArn" --output text 2^>nul') do set ALB_ARN=%%a
    
    if "!ALB_ARN!"=="" (
        for /f "delims=" %%a in ('aws elbv2 describe-load-balancers --names "!ALB_NAME!" --region "!AWS_REGION!" --query "LoadBalancers[0].LoadBalancerArn" --output text') do set ALB_ARN=%%a
    )
    
    echo Load Balancer ARN: !ALB_ARN!
    
    echo Creating ALB listener...
    aws elbv2 create-listener --load-balancer-arn "!ALB_ARN!" --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn="!TARGET_GROUP_ARN!" --region "!AWS_REGION!" >nul 2>&1
    
    for /f "delims=" %%a in ('aws elbv2 describe-load-balancers --load-balancer-arns "!ALB_ARN!" --region "!AWS_REGION!" --query "LoadBalancers[0].DNSName" --output text') do set ALB_DNS=%%a
    
    echo Load Balancer DNS: !ALB_DNS!
) else (
    set TARGET_GROUP_ARN=
    echo Skipping load balancer creation
)

REM Prepare task definition
echo.
echo Preparing ECS task definition...
copy ecs\task-definition.json %TEMP%\task-definition.json >nul
powershell -Command "(Get-Content '%TEMP%\task-definition.json') -replace '{{ACCOUNT_ID}}','!ACCOUNT_ID!' | Set-Content '%TEMP%\task-definition.json'"
powershell -Command "(Get-Content '%TEMP%\task-definition.json') -replace '{{AWS_REGION}}','!AWS_REGION!' | Set-Content '%TEMP%\task-definition.json'"
powershell -Command "(Get-Content '%TEMP%\task-definition.json') -replace '{{IMAGE_URI}}','!IMAGE_URI!' | Set-Content '%TEMP%\task-definition.json'"

REM Register task definition
echo Registering ECS task definition...
for /f "delims=" %%a in ('aws ecs register-task-definition --cli-input-json file://%TEMP%/task-definition.json --region "!AWS_REGION!" --query "taskDefinition.taskDefinitionArn" --output text') do set TASK_DEF_ARN=%%a

if "!TASK_DEF_ARN!"=="" (
    echo ERROR: Failed to register task definition
    exit /b 1
)

echo Task Definition ARN: !TASK_DEF_ARN!

REM Prepare service definition
echo.
echo Preparing ECS service definition...
copy ecs\service-definition.json %TEMP%\service-definition.json >nul
powershell -Command "(Get-Content '%TEMP%\service-definition.json') -replace '{{CLUSTER_NAME}}','!CLUSTER_NAME!' | Set-Content '%TEMP%\service-definition.json'"
powershell -Command "(Get-Content '%TEMP%\service-definition.json') -replace '{{SUBNET_1}}','!SUBNET_1!' | Set-Content '%TEMP%\service-definition.json'"
powershell -Command "(Get-Content '%TEMP%\service-definition.json') -replace '{{SUBNET_2}}','!SUBNET_2!' | Set-Content '%TEMP%\service-definition.json'"
powershell -Command "(Get-Content '%TEMP%\service-definition.json') -replace '{{SECURITY_GROUP}}','!SECURITY_GROUP!' | Set-Content '%TEMP%\service-definition.json'"

if not "!TARGET_GROUP_ARN!"=="" (
    powershell -Command "(Get-Content '%TEMP%\service-definition.json') -replace '{{TARGET_GROUP_ARN}}','!TARGET_GROUP_ARN!' | Set-Content '%TEMP%\service-definition.json'"
) else (
    powershell -Command "$json = Get-Content '%TEMP%\service-definition.json' | ConvertFrom-Json; $json.PSObject.Properties.Remove('loadBalancers'); $json.PSObject.Properties.Remove('healthCheckGracePeriodSeconds'); $json | ConvertTo-Json -Depth 10 | Set-Content '%TEMP%\service-definition.json'"
)

REM Check if service exists
echo.
echo Checking if ECS service exists...
for /f "delims=" %%a in ('aws ecs describe-services --cluster "!CLUSTER_NAME!" --services "!SERVICE_NAME!" --region "!AWS_REGION!" --query "services[0].serviceName" --output text 2^>nul') do set EXISTING_SERVICE=%%a

if "!EXISTING_SERVICE!"=="!SERVICE_NAME!" (
    echo Updating existing ECS service: !SERVICE_NAME!
    aws ecs update-service --cluster "!CLUSTER_NAME!" --service "!SERVICE_NAME!" --task-definition "!TASK_DEF_ARN!" --force-new-deployment --region "!AWS_REGION!" >nul
) else (
    echo Creating new ECS service: !SERVICE_NAME!
    aws ecs create-service --cli-input-json file://%TEMP%/service-definition.json --region "!AWS_REGION!" >nul
)

REM Wait for service stability
echo.
echo Waiting for service to become stable...
aws ecs wait services-stable --cluster "!CLUSTER_NAME!" --services "!SERVICE_NAME!" --region "!AWS_REGION!"

REM Verify deployment
echo.
echo ========================================
echo Deployment Status
echo ========================================

for /f "delims=" %%a in ('aws ecs describe-services --cluster "!CLUSTER_NAME!" --services "!SERVICE_NAME!" --region "!AWS_REGION!" --query "services[0].runningCount" --output text') do set RUNNING_COUNT=%%a

echo Service: !SERVICE_NAME!
echo Cluster: !CLUSTER_NAME!
echo Running Tasks: !RUNNING_COUNT!
echo Task Definition: !TASK_DEF_ARN!
echo CloudWatch Logs: /ecs/!PROJECT_NAME!

if not "!ALB_DNS!"=="" (
    echo Application URL: http://!ALB_DNS!
)

echo.
echo ========================================
echo Deployment completed successfully!
echo ========================================

endlocal