# AWS ECS Fargate Deployment Guide

## Table of Contents
- [Prerequisites](#prerequisites)
- [Project Overview](#project-overview)
- [Local Development Setup](#local-development-setup)
- [Docker Build and Push](#docker-build-and-push)
- [AWS ECS Fargate Prerequisites](#aws-ecs-fargate-prerequisites)
- [ECS Fargate Setup](#ecs-fargate-setup)
- [ECS Task Definition Explained](#ecs-task-definition-explained)
- [ECS Service Configuration](#ecs-service-configuration)
- [ECS Fargate Deployment](#ecs-fargate-deployment)
- [Verification and Testing](#verification-and-testing)
- [Troubleshooting](#troubleshooting)
- [Scaling and Management](#scaling-and-management)
- [Security Best Practices](#security-best-practices)

## Prerequisites

### Required Software
- **Docker**: Version 20.10 or later
- **AWS CLI**: Version 2.x or later
- **Java**: JDK 21 (for local development)
- **Maven**: Version 3.9.x or later (for local builds)

### AWS Account Requirements
- Active AWS account with ECS permissions
- IAM user with appropriate policies:
  - `AmazonECS_FullAccess`
  - `AmazonEC2ContainerRegistryFullAccess`
  - `IAMReadOnlyAccess`
- AWS CLI configured with credentials (`aws configure`)

### Verify Prerequisites
```bash
# Check Docker
docker --version

# Check AWS CLI
aws --version
aws sts get-caller-identity

# Check Java
java -version

# Check Maven
mvn -version
```

## Project Overview

**Project Name**: comp-jv21pat
**Technology Stack**: Java 21 + Maven
**Application Type**: Java Application
**Base Image**: eclipse-temurin:21-jre
**Application Port**: 8080
**Target Platform**: AWS ECS Fargate

## Local Development Setup

### Build Locally with Maven
```bash
# Navigate to project directory
cd /modernize-data/studio-data/TNT1001/APP3381/transformed-code/1065/studio-workspace/COmp-jv21PAT

# Build the project
mvn clean package -DskipTests

# Run locally
java -jar target/*.jar
```

### Run with Docker Compose
```bash
# Build and run
docker-compose up --build

# Run in detached mode
docker-compose up -d

# View logs
docker-compose logs -f

# Stop services
docker-compose down
```

Access the application at: `http://localhost:8080`

## Docker Build and Push

### Option 1: AWS ECR (Recommended for ECS)

#### Linux/macOS
```bash
chmod +x scripts/build-push.sh
./scripts/build-push.sh
```

#### Windows
```cmd
scripts\build-push.bat
```

### Option 2: Docker Hub
The build scripts support Docker Hub as well. Select option 2 when prompted.

### Manual Docker Build
```bash
# Build image
docker build -t comp-jv21pat:latest .

# Tag for ECR
docker tag comp-jv21pat:latest <account-id>.dkr.ecr.<region>.amazonaws.com/comp-jv21pat:latest

# Login to ECR
aws ecr get-login-password --region <region> | docker login --username AWS --password-stdin <account-id>.dkr.ecr.<region>.amazonaws.com

# Create repository (if not exists)
aws ecr create-repository --repository-name comp-jv21pat --region <region>

# Push to ECR
docker push <account-id>.dkr.ecr.<region>.amazonaws.com/comp-jv21pat:latest
```

## AWS ECS Fargate Prerequisites

### 1. VPC and Networking
ECS Fargate requires a VPC with proper networking configuration:

```bash
# List available VPCs
aws ec2 describe-vpcs --query 'Vpcs[*].[VpcId,CidrBlock,Tags[?Key==`Name`].Value|[0]]' --output table

# List subnets in a VPC
aws ec2 describe-subnets --filters "Name=vpc-id,Values=<vpc-id>" --query 'Subnets[*].[SubnetId,AvailabilityZone,CidrBlock]' --output table
```

**Requirements**:
- At least 2 subnets in different Availability Zones (for high availability)
- Subnets must have internet access (NAT Gateway or Internet Gateway)
- Public IP assignment enabled (or use NAT Gateway)

### 2. Security Groups
Create a security group that allows:
- Inbound traffic on port 8080 (application port)
- Outbound traffic for external services

```bash
# Create security group
aws ec2 create-security-group \
    --group-name comp-jv21pat-sg \
    --description "Security group for comp-jv21pat ECS service" \
    --vpc-id <vpc-id>

# Add inbound rule for application port
aws ec2 authorize-security-group-ingress \
    --group-id <security-group-id> \
    --protocol tcp \
    --port 8080 \
    --cidr 0.0.0.0/0

# Add inbound rule for load balancer (if using ALB)
aws ec2 authorize-security-group-ingress \
    --group-id <security-group-id> \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0
```

### 3. IAM Roles
ECS Fargate requires two IAM roles:

#### Task Execution Role (Required)
Allows ECS to pull images and write logs:

```bash
# Create trust policy
cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Create role
aws iam create-role \
    --role-name ecsTaskExecutionRole \
    --assume-role-policy-document file://trust-policy.json

# Attach policy
aws iam attach-role-policy \
    --role-name ecsTaskExecutionRole \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
```

#### Task Role (Optional)
Provides permissions for the application itself:

```bash
# Create role
aws iam create-role \
    --role-name ecsTaskRole \
    --assume-role-policy-document file://trust-policy.json

# Attach custom policies as needed
aws iam attach-role-policy \
    --role-name ecsTaskRole \
    --policy-arn arn:aws:iam::aws:policy/<YourPolicy>
```

### 4. CloudWatch Log Group
Create log group for application logs:

```bash
aws logs create-log-group --log-group-name /ecs/comp-jv21pat
```

## ECS Fargate Setup

### 1. Create ECS Cluster
```bash
aws ecs create-cluster --cluster-name comp-jv21pat-cluster
```

### 2. Verify Cluster
```bash
aws ecs describe-clusters --clusters comp-jv21pat-cluster
```

## ECS Task Definition Explained

The task definition (`ecs/task-definition.json`) defines:

### Fargate Configuration
- **Launch Type**: `FARGATE` (serverless container execution)
- **Network Mode**: `awsvpc` (required for Fargate, provides ENI per task)
- **CPU**: `512` (0.5 vCPU)
- **Memory**: `1024` (1 GB)

### Valid CPU/Memory Combinations
| CPU (units) | Memory (MB) |
|-------------|-------------|
| 256 | 512, 1024, 2048 |
| 512 | 1024, 2048, 3072, 4096 |
| 1024 | 2048-8192 (increments of 1024) |
| 2048 | 4096-16384 (increments of 1024) |
| 4096 | 8192-30720 (increments of 1024) |

### Container Definition
- **Image**: ECR image URI
- **Port Mappings**: Container port 8080 (no host port for Fargate)
- **Environment Variables**:
  - `JAVA_OPTS`: JVM memory and optimization flags
  - `TZ`: Timezone configuration
- **Logging**: CloudWatch Logs with awslogs driver

### IAM Roles
- **executionRoleArn**: Allows ECS to pull images and write logs
- **taskRoleArn**: Provides permissions to the application

## ECS Service Configuration

The service definition (`ecs/service-definition.json`) defines:

### Service Settings
- **Service Name**: `comp-jv21pat-service`
- **Desired Count**: 2 (number of tasks to run)
- **Launch Type**: `FARGATE`

### Deployment Configuration
- **Maximum Percent**: 200 (allows 2x desired count during deployment)
- **Minimum Healthy Percent**: 50 (keeps at least 50% tasks running)
- **Circuit Breaker**: Enabled with automatic rollback

### Network Configuration
- **Subnets**: At least 2 subnets in different AZs
- **Security Groups**: Allows traffic on port 8080
- **Public IP**: Enabled (for internet access)

### Load Balancer (Optional)
- **Target Group**: Application Load Balancer target group
- **Container Name**: `comp-jv21pat`
- **Container Port**: 8080
- **Health Check Grace Period**: 300 seconds (allows for startup time)

### Service Tags
- Uses `tags` parameter for service-level tagging
- `propagateTags: SERVICE` propagates tags to tasks

## ECS Fargate Deployment

### Automated Deployment

#### Linux/macOS
```bash
chmod +x scripts/deploy-image.sh
./scripts/deploy-image.sh
```

#### Windows
```cmd
scripts\deploy-image.bat
```

### Manual Deployment Steps

#### 1. Register Task Definition
```bash
# Replace placeholders in task definition
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
sed "s/{{ACCOUNT_ID}}/$ACCOUNT_ID/g" ecs/task-definition.json > /tmp/task-def.json
sed -i "s/{{AWS_REGION}}/us-east-1/g" /tmp/task-def.json
sed -i "s|{{IMAGE_URI}}|<your-image-uri>|g" /tmp/task-def.json

# Register task definition
aws ecs register-task-definition --cli-input-json file:///tmp/task-def.json
```

#### 2. Create Service
```bash
# Update service definition placeholders
sed "s/{{CLUSTER_NAME}}/comp-jv21pat-cluster/g" ecs/service-definition.json > /tmp/service-def.json
sed -i "s/{{SUBNET_1}}/<subnet-id-1>/g" /tmp/service-def.json
sed -i "s/{{SUBNET_2}}/<subnet-id-2>/g" /tmp/service-def.json
sed -i "s/{{SECURITY_GROUP}}/<security-group-id>/g" /tmp/service-def.json
sed -i "s|{{TARGET_GROUP_ARN}}|<target-group-arn>|g" /tmp/service-def.json

# Create service
aws ecs create-service --cli-input-json file:///tmp/service-def.json
```

#### 3. Wait for Stability
```bash
aws ecs wait services-stable \
    --cluster comp-jv21pat-cluster \
    --services comp-jv21pat-service
```

## Verification and Testing

### Check Service Status
```bash
aws ecs describe-services \
    --cluster comp-jv21pat-cluster \
    --services comp-jv21pat-service
```

### List Running Tasks
```bash
aws ecs list-tasks \
    --cluster comp-jv21pat-cluster \
    --service-name comp-jv21pat-service
```

### View Task Details
```bash
aws ecs describe-tasks \
    --cluster comp-jv21pat-cluster \
    --tasks <task-id>
```

### View CloudWatch Logs
```bash
aws logs tail /ecs/comp-jv21pat --follow
```

### Test Application
```bash
# If using load balancer
curl http://<alb-dns-name>/health

# Direct task access (if public IP enabled)
curl http://<task-public-ip>:8080/health
```

## Troubleshooting

### Common Issues

#### Task Fails to Start
1. **Check task stopped reason**:
   ```bash
   aws ecs describe-tasks --cluster comp-jv21pat-cluster --tasks <task-id> --query 'tasks[0].stoppedReason'
   ```

2. **Common causes**:
   - Invalid CPU/memory combination
   - Image pull errors (check execution role permissions)
   - Insufficient ENI capacity in subnet
   - Security group blocking required ports

#### Task Starts But Exits Immediately
1. **Check CloudWatch logs**:
   ```bash
   aws logs tail /ecs/comp-jv21pat --follow
   ```

2. **Common causes**:
   - Application errors on startup
   - Missing environment variables
   - Port conflicts
   - JVM out of memory

#### Network Issues
1. **Verify security groups**:
   - Inbound rules allow traffic on port 8080
   - Outbound rules allow internet access

2. **Verify subnet routing**:
   - Public subnets: Internet Gateway attached
   - Private subnets: NAT Gateway configured

3. **Check task ENI**:
   ```bash
   aws ecs describe-tasks --cluster comp-jv21pat-cluster --tasks <task-id> --query 'tasks[0].attachments[0].details'
   ```

#### Service Update Failures
1. **Check deployment events**:
   ```bash
   aws ecs describe-services --cluster comp-jv21pat-cluster --services comp-jv21pat-service --query 'services[0].events[0:5]'
   ```

2. **Common causes**:
   - Circuit breaker triggered (check health checks)
   - Resource constraints (CPU/memory limits)
   - Failed health checks

### Debug Commands

```bash
# Get task public IP
aws ecs describe-tasks \
    --cluster comp-jv21pat-cluster \
    --tasks <task-id> \
    --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' \
    --output text | xargs -I {} aws ec2 describe-network-interfaces \
    --network-interface-ids {} \
    --query 'NetworkInterfaces[0].Association.PublicIp' \
    --output text

# Force new deployment
aws ecs update-service \
    --cluster comp-jv21pat-cluster \
    --service comp-jv21pat-service \
    --force-new-deployment

# Scale service
aws ecs update-service \
    --cluster comp-jv21pat-cluster \
    --service comp-jv21pat-service \
    --desired-count 3
```

## Scaling and Management

### Manual Scaling
```bash
# Scale to 5 tasks
aws ecs update-service \
    --cluster comp-jv21pat-cluster \
    --service comp-jv21pat-service \
    --desired-count 5
```

### Auto Scaling
```bash
# Register scalable target
aws application-autoscaling register-scalable-target \
    --service-namespace ecs \
    --scalable-dimension ecs:service:DesiredCount \
    --resource-id service/comp-jv21pat-cluster/comp-jv21pat-service \
    --min-capacity 2 \
    --max-capacity 10

# Create scaling policy (CPU-based)
aws application-autoscaling put-scaling-policy \
    --service-namespace ecs \
    --scalable-dimension ecs:service:DesiredCount \
    --resource-id service/comp-jv21pat-cluster/comp-jv21pat-service \
    --policy-name cpu-scaling-policy \
    --policy-type TargetTrackingScaling \
    --target-tracking-scaling-policy-configuration file://scaling-policy.json
```

### Blue/Green Deployments
For zero-downtime deployments, use AWS CodeDeploy with ECS:

1. Create CodeDeploy application and deployment group
2. Update service to use CODE_DEPLOY deployment controller
3. Use appspec.yaml for deployment configuration

### Service Updates
```bash
# Update task definition (new version)
aws ecs update-service \
    --cluster comp-jv21pat-cluster \
    --service comp-jv21pat-service \
    --task-definition comp-jv21pat-task:2

# Update environment variables
# Modify task definition JSON, then:
aws ecs register-task-definition --cli-input-json file://updated-task-def.json
aws ecs update-service \
    --cluster comp-jv21pat-cluster \
    --service comp-jv21pat-service \
    --task-definition comp-jv21pat-task:3
```

## Security Best Practices

### 1. IAM Roles
- Use separate execution and task roles
- Follow principle of least privilege
- Rotate credentials regularly
- Never embed credentials in images

### 2. Network Security
- Use private subnets with NAT Gateway (production)
- Restrict security group rules to minimum required
- Use VPC endpoints for AWS services (reduce internet exposure)
- Enable VPC Flow Logs for network monitoring

### 3. Container Security
- Scan images for vulnerabilities (AWS ECR image scanning)
- Use minimal base images (eclipse-temurin JRE, not JDK)
- Run containers as non-root user
- Enable read-only root filesystem where possible

### 4. Secrets Management
- Use AWS Secrets Manager or Parameter Store for sensitive data
- Reference secrets in task definition:
  ```json
  "secrets": [
    {
      "name": "DB_PASSWORD",
      "valueFrom": "arn:aws:secretsmanager:region:account:secret:db-password"
    }
  ]
  ```

### 5. Logging and Monitoring
- Enable CloudWatch Logs for all containers
- Set up CloudWatch Alarms for critical metrics
- Use AWS X-Ray for distributed tracing
- Enable ECS Container Insights for detailed metrics

### 6. Java-Specific Security
- Keep Java runtime updated (use latest eclipse-temurin patch versions)
- Configure JVM security properties
- Disable unnecessary Java features
- Monitor JVM metrics (heap usage, GC pressure)

## Additional Resources

- [AWS ECS Documentation](https://docs.aws.amazon.com/ecs/)
- [AWS Fargate Documentation](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/AWS_Fargate.html)
- [ECS Best Practices](https://docs.aws.amazon.com/AmazonECS/latest/bestpracticesguide/intro.html)
- [Java Container Best Practices](https://docs.oracle.com/en/java/javase/21/docs/)

## Support

For issues or questions:
1. Check CloudWatch Logs: `/ecs/comp-jv21pat`
2. Review ECS service events
3. Consult AWS documentation
4. Contact AWS Support (if applicable)

---

**Generated**: 2026-01-30
**Platform**: AWS ECS Fargate
**Technology**: Java 21 + Maven
**Project**: comp-jv21pat