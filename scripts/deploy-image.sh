#!/bin/bash
set -e
set -o pipefail

echo "================================================"
echo "   AWS ECS Fargate Deployment Script"
echo "================================================"
echo ""

# Configuration
PROJECT_NAME="comp-jv21pat"
TASK_FAMILY="$PROJECT_NAME-task"
SERVICE_NAME="$PROJECT_NAME-service"

# Prompt for AWS configuration
read -p "Enter AWS Region (e.g., us-east-1): " AWS_REGION
read -p "Enter ECS Cluster Name: " CLUSTER_NAME
read -p "Enter VPC ID: " VPC_ID
read -p "Enter Subnet IDs (comma-separated, at least 2): " SUBNETS_INPUT
read -p "Enter Security Group ID: " SECURITY_GROUP
read -p "Enter Docker Image URI: " IMAGE_URI

# Parse subnets
IFS=',' read -ra SUBNET_ARRAY <<< "$SUBNETS_INPUT"
SUBNET_1=$(echo "${SUBNET_ARRAY[0]}" | xargs)
SUBNET_2=$(echo "${SUBNET_ARRAY[1]}" | xargs)

if [ -z "$SUBNET_1" ] || [ -z "$SUBNET_2" ]; then
    echo "Error: At least 2 subnets are required for high availability"
    exit 1
fi

echo ""
echo "Getting AWS Account ID..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region $AWS_REGION)

if [ -z "$ACCOUNT_ID" ]; then
    echo "Error: Failed to get AWS Account ID. Please check your AWS credentials."
    exit 1
fi

echo "AWS Account ID: $ACCOUNT_ID"
echo ""

# Check/create ECS cluster
echo "Checking if ECS cluster exists..."
aws ecs describe-clusters --clusters $CLUSTER_NAME --region $AWS_REGION >/dev/null 2>&1 || {
    echo "Cluster does not exist. Creating ECS cluster: $CLUSTER_NAME"
    aws ecs create-cluster --cluster-name $CLUSTER_NAME --region $AWS_REGION
    echo "Cluster created successfully"
}

echo "Cluster: $CLUSTER_NAME is ready"
echo ""

# Create CloudWatch log group
echo "Creating CloudWatch log group..."
LOG_GROUP="/ecs/$PROJECT_NAME"
aws logs create-log-group --log-group-name $LOG_GROUP --region $AWS_REGION 2>/dev/null || echo "Log group already exists"
echo "Log group: $LOG_GROUP"
echo ""

# Load balancer configuration
read -p "Do you need a load balancer for this service? (y/n): " NEED_LB

LB_ARN=""
TARGET_GROUP_ARN=""

if [ "$NEED_LB" = "y" ] || [ "$NEED_LB" = "Y" ]; then
    echo ""
    echo "Creating Application Load Balancer..."
    
    # Create ALB
    LB_NAME="$PROJECT_NAME-alb"
    LB_CREATE_OUTPUT=$(aws elbv2 create-load-balancer \
        --name $LB_NAME \
        --subnets $SUBNET_1 $SUBNET_2 \
        --security-groups $SECURITY_GROUP \
        --scheme internet-facing \
        --type application \
        --ip-address-type ipv4 \
        --region $AWS_REGION \
        --output json 2>/dev/null || echo "")
    
    if [ -n "$LB_CREATE_OUTPUT" ]; then
        LB_ARN=$(echo $LB_CREATE_OUTPUT | jq -r '.LoadBalancers[0].LoadBalancerArn')
        LB_DNS=$(echo $LB_CREATE_OUTPUT | jq -r '.LoadBalancers[0].DNSName')
        echo "Load Balancer created: $LB_DNS"
    else
        # Load balancer might already exist
        LB_ARN=$(aws elbv2 describe-load-balancers --names $LB_NAME --region $AWS_REGION --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "")
        LB_DNS=$(aws elbv2 describe-load-balancers --names $LB_NAME --region $AWS_REGION --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || echo "")
        echo "Using existing Load Balancer: $LB_DNS"
    fi
    
    # Create Target Group
    echo "Creating Target Group..."
    TG_NAME="$PROJECT_NAME-tg"
    TG_CREATE_OUTPUT=$(aws elbv2 create-target-group \
        --name $TG_NAME \
        --protocol HTTP \
        --port 8080 \
        --vpc-id $VPC_ID \
        --target-type ip \
        --health-check-enabled \
        --health-check-protocol HTTP \
        --health-check-path /health \
        --health-check-interval-seconds 30 \
        --health-check-timeout-seconds 5 \
        --healthy-threshold-count 2 \
        --unhealthy-threshold-count 3 \
        --region $AWS_REGION \
        --output json 2>/dev/null || echo "")
    
    if [ -n "$TG_CREATE_OUTPUT" ]; then
        TARGET_GROUP_ARN=$(echo $TG_CREATE_OUTPUT | jq -r '.TargetGroups[0].TargetGroupArn')
        echo "Target Group created: $TARGET_GROUP_ARN"
    else
        # Target group might already exist
        TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups --names $TG_NAME --region $AWS_REGION --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "")
        echo "Using existing Target Group: $TARGET_GROUP_ARN"
    fi
    
    # Create Listener
    echo "Creating ALB Listener..."
    aws elbv2 create-listener \
        --load-balancer-arn $LB_ARN \
        --protocol HTTP \
        --port 80 \
        --default-actions Type=forward,TargetGroupArn=$TARGET_GROUP_ARN \
        --region $AWS_REGION 2>/dev/null || echo "Listener already exists"
    
    echo "Load Balancer setup complete"
    echo ""
fi

# Prepare task definition JSON
echo "Preparing task definition..."
cp ecs/task-definition.json /tmp/task-definition-temp.json

sed -i "s|{{IMAGE_URI}}|$IMAGE_URI|g" /tmp/task-definition-temp.json
sed -i "s|{{AWS_REGION}}|$AWS_REGION|g" /tmp/task-definition-temp.json
sed -i "s|{{ACCOUNT_ID}}|$ACCOUNT_ID|g" /tmp/task-definition-temp.json

echo "Registering task definition..."
TASK_DEF_ARN=$(aws ecs register-task-definition \
    --cli-input-json file:///tmp/task-definition-temp.json \
    --region $AWS_REGION \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text)

if [ -z "$TASK_DEF_ARN" ]; then
    echo "Error: Failed to register task definition"
    exit 1
fi

echo "Task definition registered: $TASK_DEF_ARN"
echo ""

# Prepare service definition JSON
echo "Preparing service definition..."
cp ecs/service-definition.json /tmp/service-definition-temp.json

sed -i "s|{{CLUSTER_NAME}}|$CLUSTER_NAME|g" /tmp/service-definition-temp.json
sed -i "s|{{SUBNET_1}}|$SUBNET_1|g" /tmp/service-definition-temp.json
sed -i "s|{{SUBNET_2}}|$SUBNET_2|g" /tmp/service-definition-temp.json
sed -i "s|{{SECURITY_GROUP}}|$SECURITY_GROUP|g" /tmp/service-definition-temp.json

# Handle load balancer configuration
if [ -n "$TARGET_GROUP_ARN" ]; then
    # Add load balancer configuration
    jq --arg tg "$TARGET_GROUP_ARN" '.loadBalancers = [{"targetGroupArn": $tg, "containerName": "comp-jv21pat", "containerPort": 8080}] | .healthCheckGracePeriodSeconds = 300' /tmp/service-definition-temp.json > /tmp/service-definition-final.json
    mv /tmp/service-definition-final.json /tmp/service-definition-temp.json
else
    # Remove load balancer configuration
    jq 'del(.loadBalancers) | del(.healthCheckGracePeriodSeconds)' /tmp/service-definition-temp.json > /tmp/service-definition-final.json
    mv /tmp/service-definition-final.json /tmp/service-definition-temp.json
fi

# Check if service exists
echo "Checking if service exists..."
EXISTING_SERVICE=$(aws ecs describe-services \
    --cluster $CLUSTER_NAME \
    --services $SERVICE_NAME \
    --region $AWS_REGION \
    --query 'services[?status==`ACTIVE`].serviceName' \
    --output text 2>/dev/null || echo "")

if [ -z "$EXISTING_SERVICE" ] || [ "$EXISTING_SERVICE" = "None" ]; then
    echo "Creating new ECS service..."
    aws ecs create-service \
        --cli-input-json file:///tmp/service-definition-temp.json \
        --region $AWS_REGION
    echo "Service created: $SERVICE_NAME"
else
    echo "Updating existing ECS service..."
    aws ecs update-service \
        --cluster $CLUSTER_NAME \
        --service $SERVICE_NAME \
        --task-definition $TASK_DEF_ARN \
        --force-new-deployment \
        --region $AWS_REGION
    echo "Service updated: $SERVICE_NAME"
fi

echo ""
echo "Waiting for service to become stable..."
aws ecs wait services-stable \
    --cluster $CLUSTER_NAME \
    --services $SERVICE_NAME \
    --region $AWS_REGION

echo ""
echo "================================================"
echo "   Deployment Complete!"
echo "================================================"
echo ""
echo "Cluster: $CLUSTER_NAME"
echo "Service: $SERVICE_NAME"
echo "Task Definition: $TASK_DEF_ARN"
echo "CloudWatch Logs: $LOG_GROUP"

if [ -n "$LB_DNS" ]; then
    echo "Load Balancer: http://$LB_DNS"
fi

echo ""
echo "Service Status:"
aws ecs describe-services \
    --cluster $CLUSTER_NAME \
    --services $SERVICE_NAME \
    --region $AWS_REGION \
    --query 'services[0].[serviceName,status,runningCount,desiredCount]' \
    --output table

echo ""
echo "To view logs:"
echo "  aws logs tail $LOG_GROUP --follow --region $AWS_REGION"
echo ""
echo "To scale the service:"
echo "  aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --desired-count <COUNT> --region $AWS_REGION"
echo ""

# Cleanup temp files
rm -f /tmp/task-definition-temp.json /tmp/service-definition-temp.json

echo "Deployment completed successfully!"
echo ""