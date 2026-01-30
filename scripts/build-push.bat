@echo off
setlocal enabledelayedexpansion

echo ================================================
echo    Docker Build and Push Script
echo ================================================
echo.

set PROJECT_NAME=comp-jv21pat

REM Sanitize image name using PowerShell
for /f "delims=" %%i in ('powershell -Command "'!PROJECT_NAME!'.ToLower() -replace '[^a-z0-9]+', '-' -replace '^-+', '' -replace '-+$', ''"') do set IMAGE_NAME=%%i

echo Sanitized image name: !IMAGE_NAME!
echo.

set /p IMAGE_TAG="Enter image tag (default: latest): "
if "!IMAGE_TAG!"=="" set IMAGE_TAG=latest

REM Sanitize tag
for /f "delims=" %%i in ('powershell -Command "'!IMAGE_TAG!'.ToLower() -replace '[^a-z0-9.-]+', '-' -replace '^-+', '' -replace '-+$', ''"') do set IMAGE_TAG=%%i
if "!IMAGE_TAG!"=="" set IMAGE_TAG=latest

echo Using tag: !IMAGE_TAG!
echo.

echo Select container registry:
echo 1. AWS ECR
echo 2. Docker Hub
set /p REGISTRY_CHOICE="Enter choice (1 or 2): "

if "!REGISTRY_CHOICE!"=="1" (
    echo.
    echo --- AWS ECR Configuration ---
    set /p AWS_REGION="Enter AWS Region (e.g., us-east-1): "
    set /p ECR_REPO="Enter ECR Repository Name: "
    
    echo Getting AWS Account ID...
    for /f "delims=" %%i in ('aws sts get-caller-identity --query Account --output text') do set ACCOUNT_ID=%%i
    
    if "!ACCOUNT_ID!"=="" (
        echo Error: Failed to get AWS Account ID. Please check your AWS credentials.
        exit /b 1
    )
    
    echo AWS Account ID: !ACCOUNT_ID!
    
    set REGISTRY_URL=!ACCOUNT_ID!.dkr.ecr.!AWS_REGION!.amazonaws.com
    set FULL_IMAGE_NAME=!REGISTRY_URL!/!ECR_REPO!:!IMAGE_TAG!
    
    echo.
    echo Logging into AWS ECR...
    aws ecr get-login-password --region !AWS_REGION! | docker login --username AWS --password-stdin !REGISTRY_URL!
    
    if !ERRORLEVEL! neq 0 (
        echo Error: ECR login failed
        exit /b 1
    )
    
    echo ECR login successful
    
    echo Checking if ECR repository exists...
    aws ecr describe-repositories --repository-names !ECR_REPO! --region !AWS_REGION! >nul 2>&1
    if !ERRORLEVEL! neq 0 (
        echo Repository does not exist. Creating ECR repository: !ECR_REPO!
        aws ecr create-repository --repository-name !ECR_REPO! --region !AWS_REGION!
        if !ERRORLEVEL! neq 0 (
            echo Error: Failed to create ECR repository
            exit /b 1
        )
        echo Repository created successfully
    )
    
) else if "!REGISTRY_CHOICE!"=="2" (
    echo.
    echo --- Docker Hub Configuration ---
    set /p DOCKER_USERNAME="Enter Docker Hub username: "
    set /p DOCKER_PASSWORD="Enter Docker Hub password/token: "
    
    set FULL_IMAGE_NAME=!DOCKER_USERNAME!/!IMAGE_NAME!:!IMAGE_TAG!
    
    echo.
    echo Logging into Docker Hub...
    echo !DOCKER_PASSWORD! | docker login --username !DOCKER_USERNAME! --password-stdin
    
    if !ERRORLEVEL! neq 0 (
        echo Error: Docker Hub login failed
        exit /b 1
    )
    
    echo Docker Hub login successful
    
) else (
    echo Invalid choice. Exiting.
    exit /b 1
)

echo.
echo ================================================
echo Building Docker image: !FULL_IMAGE_NAME!
echo ================================================
echo.

docker build -t !FULL_IMAGE_NAME! .

if !ERRORLEVEL! neq 0 (
    echo Error: Docker build failed
    exit /b 1
)

echo.
echo Build successful!
echo.

echo ================================================
echo Pushing image to registry...
echo ================================================
echo.

docker push !FULL_IMAGE_NAME!

if !ERRORLEVEL! neq 0 (
    echo Error: Docker push failed
    exit /b 1
)

echo.
echo ================================================
echo    Success!
echo ================================================
echo.
echo Image: !FULL_IMAGE_NAME!
echo.
echo You can now deploy this image to your environment.
echo.

endlocal