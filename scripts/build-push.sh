#!/bin/bash
set -e

echo "================================================"
echo "   Docker Build and Push Script"
echo "================================================"
echo ""

# Project name
PROJECT_NAME="comp-jv21pat"

# Sanitize image name
IMAGE_NAME=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//')

echo "Sanitized image name: $IMAGE_NAME"
echo ""

# Prompt for image tag
read -p "Enter image tag (default: latest): " IMAGE_TAG
IMAGE_TAG=${IMAGE_TAG:-latest}

# Sanitize tag
IMAGE_TAG=$(echo "$IMAGE_TAG" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9.-' '-' | sed 's/^-*//;s/-*$//')
IMAGE_TAG=${IMAGE_TAG:-latest}

echo "Using tag: $IMAGE_TAG"
echo ""

# Registry selection
echo "Select container registry:"
echo "1. AWS ECR"
echo "2. Docker Hub"
read -p "Enter choice (1 or 2): " REGISTRY_CHOICE

if [ "$REGISTRY_CHOICE" = "1" ]; then
    echo ""
    echo "--- AWS ECR Configuration ---"
    read -p "Enter AWS Region (e.g., us-east-1): " AWS_REGION
    read -p "Enter ECR Repository Name: " ECR_REPO
    
    # Get AWS Account ID
    echo "Getting AWS Account ID..."
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    
    if [ -z "$ACCOUNT_ID" ]; then
        echo "Error: Failed to get AWS Account ID. Please check your AWS credentials."
        exit 1
    fi
    
    echo "AWS Account ID: $ACCOUNT_ID"
    
    REGISTRY_URL="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
    FULL_IMAGE_NAME="$REGISTRY_URL/$ECR_REPO:$IMAGE_TAG"
    
    echo ""
    echo "Logging into AWS ECR..."
    aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $REGISTRY_URL
    
    if [ $? -ne 0 ]; then
        echo "Error: ECR login failed"
        exit 1
    fi
    
    echo "ECR login successful"
    
    # Check if repository exists, create if not
    echo "Checking if ECR repository exists..."
    aws ecr describe-repositories --repository-names $ECR_REPO --region $AWS_REGION >/dev/null 2>&1 || {
        echo "Repository does not exist. Creating ECR repository: $ECR_REPO"
        aws ecr create-repository --repository-name $ECR_REPO --region $AWS_REGION
        echo "Repository created successfully"
    }
    
elif [ "$REGISTRY_CHOICE" = "2" ]; then
    echo ""
    echo "--- Docker Hub Configuration ---"
    read -p "Enter Docker Hub username: " DOCKER_USERNAME
    read -sp "Enter Docker Hub password/token: " DOCKER_PASSWORD
    echo ""
    
    FULL_IMAGE_NAME="$DOCKER_USERNAME/$IMAGE_NAME:$IMAGE_TAG"
    
    echo ""
    echo "Logging into Docker Hub..."
    echo "$DOCKER_PASSWORD" | docker login --username $DOCKER_USERNAME --password-stdin
    
    if [ $? -ne 0 ]; then
        echo "Error: Docker Hub login failed"
        exit 1
    fi
    
    echo "Docker Hub login successful"
    
else
    echo "Invalid choice. Exiting."
    exit 1
fi

echo ""
echo "================================================"
echo "Building Docker image: $FULL_IMAGE_NAME"
echo "================================================"
echo ""

docker build -t $FULL_IMAGE_NAME .

if [ $? -ne 0 ]; then
    echo "Error: Docker build failed"
    exit 1
fi

echo ""
echo "Build successful!"
echo ""

echo "================================================"
echo "Pushing image to registry..."
echo "================================================"
echo ""

docker push $FULL_IMAGE_NAME

if [ $? -ne 0 ]; then
    echo "Error: Docker push failed"
    exit 1
fi

echo ""
echo "================================================"
echo "   Success!"
echo "================================================"
echo ""
echo "Image: $FULL_IMAGE_NAME"
echo ""
echo "You can now deploy this image to your environment."
echo ""