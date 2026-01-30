# Deployment Guide - comp-jv21pat

Complete deployment guide for the Java application on AWS ECS Fargate.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Local Development with Docker Compose](#local-development-with-docker-compose)
3. [Building and Pushing Docker Images](#building-and-pushing-docker-images)
4. [AWS ECS Fargate Prerequisites](#aws-ecs-fargate-prerequisites)
5. [ECS Fargate Setup](#ecs-fargate-setup)
6. [ECS Task Definition Explained](#ecs-task-definition-explained)
7. [ECS Service Configuration](#ecs-service-configuration)
8. [ECS Fargate Deployment Walkthrough](#ecs-fargate-deployment-walkthrough)
9. [Troubleshooting](#troubleshooting)
10. [Scaling and Management](#scaling-and-management)
11. [Security Considerations](#security-considerations)

---

## Prerequisites

### Required Software

- **Docker**: Version 20.10 or higher
- **Docker Compose**: Version 2.0 or higher
- **AWS CLI**: Version 2.x
- **Java**: JDK 21 (for local development)
- **Maven**: 3.9.x (for local builds)
- **jq**: JSON processor (for deployment scripts)

### AWS Account Requirements

- Active AWS account with appropriate permissions
- AWS CLI configured with credentials
- IAM permissions for ECS, ECR, CloudWatch, VPC, and Load Balancer resources

---

## Local Development with Docker Compose

### Starting the Application Locally

1. **Build and start the application**:

```bash
docker-compose up --build
```

2. **Access the application**:

- Application: http://localhost:8080

3. **View logs**:

```bash
docker-compose logs -f comp-jv21pat
```

4. **Stop the application**:

```bash
docker-compose down
```

### Volume Mounts

The docker-compose.yml configuration includes the following volumes:

- `./logs:/app/logs` - Application logs
- `./config:/app/config` - Configuration files

---

## Building and Pushing Docker Images

### Linux/macOS

Use the `build-push.sh` script:

```bash
cd scripts
chmod +x build-push.sh
./build-push.sh
```

The script will:
1. Prompt for image tag (defaults to 'latest')
2. Ask for registry selection (AWS ECR or Docker Hub)
3. Request registry credentials
4. Build the Docker image
5. Push to the selected registry

### Windows

Use the `build-push.bat` script:

```cmd
cd scripts
build-push.bat
```

### Manual Build Process

If you prefer manual control:

```bash
# Build the image
docker build -t comp-jv21pat:latest .

# Tag for registry
docker tag comp-jv21pat:latest <registry>/comp-jv21pat:latest

# Push to registry
docker push <registry>/comp-jv21pat:latest
```

---

## AWS ECS Fargate Prerequisites

### 1. VPC Configuration

Ensure you have a VPC with:
- At least 2 subnets in different Availability Zones
- Internet Gateway attached
- Route table with route to Internet Gateway
- Subnets have "Auto-assign public IPv4 address" enabled

### 2. Security Group

Create a security group with the following inbound rules:

| Type | Protocol | Port Range | Source |
|------|----------|------------|--------|
| HTTP | TCP | 80 | 0.0.0.0/0 |
| Custom TCP | TCP | 8080 | 0.0.0.0/0 |

Outbound rules:
- Allow all traffic to 0.0.0.0/0

### 3. IAM Roles

#### ECS Task Execution Role

Create role `ecsTaskExecutionRole` with the following policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
```

#### ECS Task Role (Optional)

Create role `ecsTaskRole` for application-specific AWS service access.

### 4. CloudWatch Log Group

The deployment script will automatically create the log group:
- Log Group Name: `/ecs/comp-jv21pat`
- Region: Your selected AWS region

---

## ECS Fargate Setup

### Architecture Overview

```
[Internet] -> [Application Load Balancer] -> [ECS Service] -> [Fargate Tasks]
                                                  |
                                          [CloudWatch Logs]
```

### Key Components

1. **ECS Cluster**: Logical grouping of services and tasks
2. **Task Definition**: Blueprint for your application (CPU, memory, container config)
3. **ECS Service**: Manages desired number of tasks and deployment
4. **Application Load Balancer**: Distributes traffic to tasks (optional)
5. **CloudWatch Logs**: Centralized logging

---

## ECS Task Definition Explained

### Fargate CPU and Memory Combinations

Fargate requires specific CPU/memory combinations:

| CPU (vCPU) | Memory (MB) |
|------------|-------------|
| 256 (.25) | 512, 1024, 2048 |
| 512 (.5) | 1024, 2048, 3072, 4096 |
| 1024 (1) | 2048-8192 (increments of 1024) |
| 2048 (2) | 4096-16384 (increments of 1024) |
| 4096 (4) | 8192-30720 (increments of 1024) |

**Default Configuration**: CPU: 512, Memory: 1024

### Container Definition

Key configuration elements:

```json
{
  "name": "comp-jv21pat",
  "image": "<ECR_URI>/comp-jv21pat:latest",
  "essential": true,
  "portMappings": [
    {
      "containerPort": 8080,
      "protocol": "tcp"
    }
  ],
  "environment": [
    {
      "name": "JAVA_OPTS",
      "value": "-Xmx768m -Xms256m -XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0"
    }
  ],
  "logConfiguration": {
    "logDriver": "awslogs",
    "options": {
      "awslogs-group": "/ecs/comp-jv21pat",
      "awslogs-region": "us-east-1",
      "awslogs-stream-prefix": "ecs"
    }
  }
}
```

### Java-Specific Configuration

- **JAVA_OPTS**: Configured for container memory limits
- **UseContainerSupport**: Enables container-aware JVM
- **MaxRAMPercentage**: Limits heap to 75% of container memory
- **Timezone**: Set to UTC for consistency

---

## ECS Service Configuration

### Service Properties

- **Launch Type**: FARGATE
- **Network Mode**: awsvpc (required for Fargate)
- **Desired Count**: 2 (for high availability)
- **Deployment Configuration**:
  - Maximum Percent: 200% (allows rolling updates)
  - Minimum Healthy Percent: 50% (ensures availability)
  - Circuit Breaker: Enabled with automatic rollback

### Network Configuration

```json
{
  "awsvpcConfiguration": {
    "subnets": ["subnet-xxx", "subnet-yyy"],
    "securityGroups": ["sg-xxx"],
    "assignPublicIp": "ENABLED"
  }
}
```

### Load Balancer Integration

If using Application Load Balancer:

```json
{
  "loadBalancers": [
    {
      "targetGroupArn": "arn:aws:elasticloadbalancing:...",
      "containerName": "comp-jv21pat",
      "containerPort": 8080
    }
  ],
  "healthCheckGracePeriodSeconds": 300
}
```

---

## ECS Fargate Deployment Walkthrough

### Step 1: Build and Push Image

```bash
# Linux/macOS
cd scripts
./build-push.sh

# Windows
cd scripts
build-push.bat
```

### Step 2: Deploy to ECS

```bash
# Linux/macOS
./deploy-image.sh

# Windows
deploy-image.bat
```

### Step 3: Provide Configuration

The script will prompt for:

1. **AWS Region**: e.g., us-east-1
2. **ECS Cluster Name**: e.g., production-cluster
3. **VPC ID**: e.g., vpc-12345678
4. **Subnet IDs**: Comma-separated, e.g., subnet-111,subnet-222
5. **Security Group ID**: e.g., sg-12345678
6. **Docker Image URI**: e.g., 123456789.dkr.ecr.us-east-1.amazonaws.com/comp-jv21pat:latest
7. **Load Balancer**: y/n (script will create ALB if needed)

### Step 4: Verify Deployment

After deployment, the script will:
- Wait for service stability
- Display service status
- Show CloudWatch log group
- Display Load Balancer DNS (if created)

### Step 5: Access Application

If Load Balancer was created:
```
http://<load-balancer-dns>
```

Or access tasks directly via their public IPs (if no LB).

---

## Troubleshooting

### Task Failures

#### Problem: Tasks fail to start

**Check:**
1. CloudWatch logs:
```bash
aws logs tail /ecs/comp-jv21pat --follow --region us-east-1
```

2. Task stopped reason:
```bash
aws ecs describe-tasks --cluster <cluster> --tasks <task-id> --region <region>
```

**Common Causes:**
- Image not found in ECR
- Insufficient IAM permissions
- Invalid CPU/memory combination
- Application errors during startup

#### Problem: Cannot pull image from ECR

**Solution:**
- Verify `ecsTaskExecutionRole` has ECR permissions
- Check image URI is correct
- Ensure task is in same region as ECR repository

### Network Issues

#### Problem: Cannot access application

**Check:**
1. Security group allows inbound traffic on port 8080
2. Subnets have route to Internet Gateway
3. Tasks have public IPs assigned
4. Load Balancer target group health checks are passing

#### Problem: Health checks failing

**Solution:**
- Verify application is listening on port 8080
- Check health endpoint returns 200 status
- Increase `healthCheckGracePeriodSeconds` if application takes time to start
- Review application logs for startup errors

### CPU/Memory Errors

#### Problem: Tasks stopped with OutOfMemory

**Solution:**
- Increase task memory in task definition
- Adjust JAVA_OPTS heap settings
- Use valid Fargate CPU/memory combinations

#### Problem: Task throttling or slow performance

**Solution:**
- Increase task CPU allocation
- Scale out with more tasks
- Review application performance metrics

### Deployment Issues

#### Problem: Service update stuck

**Solution:**
```bash
# Force new deployment
aws ecs update-service \
  --cluster <cluster> \
  --service comp-jv21pat-service \
  --force-new-deployment \
  --region <region>
```

#### Problem: Circuit breaker triggered

**Solution:**
- Check CloudWatch logs for application errors
- Verify health check configuration
- Review recent code changes
- Rollback to previous task definition if needed

---

## Scaling and Management

### Manual Scaling

```bash
# Scale to 5 tasks
aws ecs update-service \
  --cluster <cluster> \
  --service comp-jv21pat-service \
  --desired-count 5 \
  --region <region>
```

### Service Auto Scaling

Configure target tracking scaling:

```bash
# Register scalable target
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --scalable-dimension ecs:service:DesiredCount \
  --resource-id service/<cluster>/comp-jv21pat-service \
  --min-capacity 2 \
  --max-capacity 10 \
  --region <region>

# Create scaling policy
aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --scalable-dimension ecs:service:DesiredCount \
  --resource-id service/<cluster>/comp-jv21pat-service \
  --policy-name cpu-scaling-policy \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration file://scaling-policy.json \
  --region <region>
```

scaling-policy.json:
```json
{
  "TargetValue": 70.0,
  "PredefinedMetricSpecification": {
    "PredefinedMetricType": "ECSServiceAverageCPUUtilization"
  },
  "ScaleOutCooldown": 60,
  "ScaleInCooldown": 120
}
```

### Blue/Green Deployments

For zero-downtime deployments:

1. Use AWS CodeDeploy with ECS
2. Configure deployment configuration
3. Set up ALB with two target groups
4. Define traffic shifting strategy

### Monitoring

#### CloudWatch Metrics

Key metrics to monitor:
- CPUUtilization
- MemoryUtilization
- TargetResponseTime (if using ALB)
- HealthyHostCount
- UnhealthyHostCount

#### View Logs

```bash
# Tail logs
aws logs tail /ecs/comp-jv21pat --follow --region <region>

# Filter logs
aws logs filter-log-events \
  --log-group-name /ecs/comp-jv21pat \
  --filter-pattern "ERROR" \
  --region <region>
```

### Updating the Application

1. Build new image with updated tag
2. Push to registry
3. Update task definition with new image
4. Update service (triggers rolling deployment)

```bash
# Quick update
aws ecs update-service \
  --cluster <cluster> \
  --service comp-jv21pat-service \
  --force-new-deployment \
  --region <region>
```

---

## Security Considerations

### Container Security

- ✅ Non-root user in container
- ✅ Minimal runtime image (eclipse-temurin JRE)
- ✅ No unnecessary packages installed
- ✅ Regular base image updates

### Network Security

- Use private subnets for production
- Restrict security group rules to minimum required
- Enable VPC Flow Logs for network monitoring
- Use AWS PrivateLink for ECR access (no internet required)

### Secrets Management

For sensitive configuration:

1. **AWS Secrets Manager**:
```json
{
  "secrets": [
    {
      "name": "DB_PASSWORD",
      "valueFrom": "arn:aws:secretsmanager:region:account:secret:db-password"
    }
  ]
}
```

2. **AWS Systems Manager Parameter Store**:
```json
{
  "secrets": [
    {
      "name": "API_KEY",
      "valueFrom": "arn:aws:ssm:region:account:parameter/api-key"
    }
  ]
}
```

### IAM Best Practices

- Use separate task execution and task roles
- Follow principle of least privilege
- Regularly audit IAM policies
- Enable CloudTrail for API logging

### Image Security

- Scan images for vulnerabilities (ECR scanning)
- Use specific image tags (not 'latest' in production)
- Implement image signing
- Regular dependency updates

---

## Java-Specific Considerations

### JVM Memory Management

For containerized Java applications:

- Set `-XX:+UseContainerSupport` (enabled by default in Java 11+)
- Use `-XX:MaxRAMPercentage` instead of fixed heap sizes
- Leave memory for non-heap (recommended: 75% for heap)
- Monitor GC metrics in CloudWatch

### Performance Tuning

```bash
JAVA_OPTS="
  -Xmx768m 
  -Xms256m 
  -XX:+UseContainerSupport 
  -XX:MaxRAMPercentage=75.0 
  -XX:+UseG1GC 
  -XX:MaxGCPauseMillis=200 
  -Djava.security.egd=file:/dev/./urandom
"
```

### Startup Optimization

- Use Spring Boot lazy initialization if applicable
- Consider AppCDS for faster startup
- Optimize dependencies and classpath
- Use healthCheckGracePeriodSeconds for slow-starting applications

---

## Additional Resources

- [AWS ECS Developer Guide](https://docs.aws.amazon.com/ecs/)
- [AWS Fargate Documentation](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/AWS_Fargate.html)
- [Docker Best Practices](https://docs.docker.com/develop/dev-best-practices/)
- [Java Container Best Practices](https://www.eclipse.org/openj9/docs/xxusecontainersupport/)

---

## Support

For issues or questions:
1. Check CloudWatch logs for application errors
2. Review ECS service events
3. Consult AWS Support for infrastructure issues
4. Review application documentation

---

**Last Updated**: 2026-01-30
**Version**: 1.0.0
