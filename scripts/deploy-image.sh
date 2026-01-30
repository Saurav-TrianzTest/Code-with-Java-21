#!/bin/bash
set -e
set -o pipefail

echo "========================================"
echo "AWS ECS Fargate Deployment Script"
echo "========================================"
echo ""

# Project configuration
PROJECT_NAME="comp-jv21pat"
TASK_FAMILY="${PROJECT_NAME}-task"
SERVICE_NAME="${PROJECT_NAME}-service"
CONTAINER_NAME="${PROJECT_NAME}"
CONTAINER_PORT=8080

# Prompt for AWS configuration
echo "=== AWS Configuration ==="
read -p "Enter AWS Region (e.g., us-east-1): " AWS_REGION
export AWS_DEFAULT_REGION="$AWS_REGION"

read -p "Enter ECS Cluster Name: " CLUSTER_NAME

# Get AWS Account ID
echo ""
echo "Retrieving AWS Account ID..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [ -z "$ACCOUNT_ID" ]; then
    echo "ERROR: Failed to retrieve AWS Account ID"
    exit 1
fi
echo "AWS Account ID: $ACCOUNT_ID"

# Check if cluster exists, create if not
echo ""
echo "Checking ECS cluster..."
aws ecs describe-clusters --clusters "$CLUSTER_NAME" --query 'clusters[0].clusterName' --output text 2>/dev/null | grep -q "$CLUSTER_NAME" || {
    echo "Creating ECS cluster: $CLUSTER_NAME"
    aws ecs create-cluster --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION"
}

# Network configuration
echo ""
echo "=== Network Configuration ==="
read -p "Enter VPC ID: " VPC_ID
read -p "Enter Subnet IDs (comma-separated, at least 2): " SUBNETS_INPUT
read -p "Enter Security Group ID: " SECURITY_GROUP

# Parse subnets
IFS=',' read -ra SUBNET_ARRAY <<< "$SUBNETS_INPUT"
SUBNET_1=$(echo "${SUBNET_ARRAY[0]}" | xargs)
SUBNET_2=$(echo "${SUBNET_ARRAY[1]}" | xargs)

if [ -z "$SUBNET_1" ] || [ -z "$SUBNET_2" ]; then
    echo "ERROR: At least 2 subnets are required for high availability"
    exit 1
fi

# Image configuration
echo ""
echo "=== Docker Image Configuration ==="
read -p "Enter ECR Image URI (e.g., 123456789.dkr.ecr.us-east-1.amazonaws.com/app:latest): " IMAGE_URI

if [ -z "$IMAGE_URI" ]; then
    echo "ERROR: Image URI is required"
    exit 1
fi

# Load balancer configuration
echo ""
read -p "Do you need a load balancer for this service? (y/n): " NEED_LB

if [[ "$NEED_LB" =~ ^[Yy]$ ]]; then
    echo ""
    echo "Creating Application Load Balancer and Target Group..."
    
    # Create target group with ip target type (required for Fargate)
    TARGET_GROUP_NAME="${PROJECT_NAME}-tg"
    echo "Creating target group: $TARGET_GROUP_NAME"
    
    TARGET_GROUP_ARN=$(aws elbv2 create-target-group \
        --name "$TARGET_GROUP_NAME" \
        --protocol HTTP \
        --port "$CONTAINER_PORT" \
        --vpc-id "$VPC_ID" \
        --target-type ip \
        --health-check-enabled \
        --health-check-path "/health" \
        --health-check-interval-seconds 30 \
        --health-check-timeout-seconds 5 \
        --healthy-threshold-count 2 \
        --unhealthy-threshold-count 3 \
        --region "$AWS_REGION" \
        --query 'TargetGroups[0].TargetGroupArn' \
        --output text 2>/dev/null || aws elbv2 describe-target-groups \
        --names "$TARGET_GROUP_NAME" \
        --region "$AWS_REGION" \
        --query 'TargetGroups[0].TargetGroupArn' \
        --output text)
    
    echo "Target Group ARN: $TARGET_GROUP_ARN"
    
    # Create ALB
    ALB_NAME="${PROJECT_NAME}-alb"
    echo "Creating Application Load Balancer: $ALB_NAME"
    
    ALB_ARN=$(aws elbv2 create-load-balancer \
        --name "$ALB_NAME" \
        --subnets "$SUBNET_1" "$SUBNET_2" \
        --security-groups "$SECURITY_GROUP" \
        --scheme internet-facing \
        --type application \
        --ip-address-type ipv4 \
        --region "$AWS_REGION" \
        --query 'LoadBalancers[0].LoadBalancerArn' \
        --output text 2>/dev/null || aws elbv2 describe-load-balancers \
        --names "$ALB_NAME" \
        --region "$AWS_REGION" \
        --query 'LoadBalancers[0].LoadBalancerArn' \
        --output text)
    
    echo "Load Balancer ARN: $ALB_ARN"
    
    # Create listener
    echo "Creating ALB listener..."
    aws elbv2 create-listener \
        --load-balancer-arn "$ALB_ARN" \
        --protocol HTTP \
        --port 80 \
        --default-actions Type=forward,TargetGroupArn="$TARGET_GROUP_ARN" \
        --region "$AWS_REGION" >/dev/null 2>&1 || echo "Listener may already exist"
    
    # Get ALB DNS name
    ALB_DNS=$(aws elbv2 describe-load-balancers \
        --load-balancer-arns "$ALB_ARN" \
        --region "$AWS_REGION" \
        --query 'LoadBalancers[0].DNSName' \
        --output text)
    
    echo "Load Balancer DNS: $ALB_DNS"
else
    TARGET_GROUP_ARN=""
    echo "Skipping load balancer creation"
fi

# Prepare task definition JSON
echo ""
echo "Preparing ECS task definition..."
cp ecs/task-definition.json /tmp/task-definition.json
sed -i "s|{{ACCOUNT_ID}}|$ACCOUNT_ID|g" /tmp/task-definition.json
sed -i "s|{{AWS_REGION}}|$AWS_REGION|g" /tmp/task-definition.json
sed -i "s|{{IMAGE_URI}}|$IMAGE_URI|g" /tmp/task-definition.json

# Register task definition
echo "Registering ECS task definition..."
TASK_DEF_ARN=$(aws ecs register-task-definition \
    --cli-input-json file:///tmp/task-definition.json \
    --region "$AWS_REGION" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text)

if [ -z "$TASK_DEF_ARN" ]; then
    echo "ERROR: Failed to register task definition"
    exit 1
fi

echo "Task Definition ARN: $TASK_DEF_ARN"

# Prepare service definition JSON
echo ""
echo "Preparing ECS service definition..."
cp ecs/service-definition.json /tmp/service-definition.json
sed -i "s|{{CLUSTER_NAME}}|$CLUSTER_NAME|g" /tmp/service-definition.json
sed -i "s|{{SUBNET_1}}|$SUBNET_1|g" /tmp/service-definition.json
sed -i "s|{{SUBNET_2}}|$SUBNET_2|g" /tmp/service-definition.json
sed -i "s|{{SECURITY_GROUP}}|$SECURITY_GROUP|g" /tmp/service-definition.json

if [ -n "$TARGET_GROUP_ARN" ]; then
    sed -i "s|{{TARGET_GROUP_ARN}}|$TARGET_GROUP_ARN|g" /tmp/service-definition.json
else
    # Remove loadBalancers section if no load balancer
    python3 -c "import json; d=json.load(open('/tmp/service-definition.json')); d.pop('loadBalancers',None); d.pop('healthCheckGracePeriodSeconds',None); json.dump(d,open('/tmp/service-definition.json','w'),indent=2)" 2>/dev/null || \
    sed -i '/"loadBalancers"/,/\],/d' /tmp/service-definition.json
fi

# Check if service exists
echo ""
echo "Checking if ECS service exists..."
EXISTING_SERVICE=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --region "$AWS_REGION" \
    --query 'services[0].serviceName' \
    --output text 2>/dev/null)

if [ "$EXISTING_SERVICE" = "$SERVICE_NAME" ]; then
    echo "Updating existing ECS service: $SERVICE_NAME"
    aws ecs update-service \
        --cluster "$CLUSTER_NAME" \
        --service "$SERVICE_NAME" \
        --task-definition "$TASK_DEF_ARN" \
        --force-new-deployment \
        --region "$AWS_REGION" >/dev/null
else
    echo "Creating new ECS service: $SERVICE_NAME"
    aws ecs create-service \
        --cli-input-json file:///tmp/service-definition.json \
        --region "$AWS_REGION" >/dev/null
fi

# Wait for service stability
echo ""
echo "Waiting for service to become stable (this may take several minutes)..."
aws ecs wait services-stable \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --region "$AWS_REGION"

# Verify deployment
echo ""
echo "========================================"
echo "Deployment Status"
echo "========================================"

RUNNING_COUNT=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --region "$AWS_REGION" \
    --query 'services[0].runningCount' \
    --output text)

echo "Service: $SERVICE_NAME"
echo "Cluster: $CLUSTER_NAME"
echo "Running Tasks: $RUNNING_COUNT"
echo "Task Definition: $TASK_DEF_ARN"
echo "CloudWatch Logs: /ecs/$PROJECT_NAME"

if [ -n "$ALB_DNS" ]; then
    echo "Application URL: http://$ALB_DNS"
fi

echo ""
echo "========================================"
echo "Deployment completed successfully!"
echo "======================================="