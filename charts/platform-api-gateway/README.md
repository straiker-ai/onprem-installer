# Straiker API Gateway Helm Chart

This Helm chart deploys the Straiker API Gateway to Kubernetes with AWS integration.

## Prerequisites

- Kubernetes cluster (1.29.0+)
- Helm 3.x
- AWS EKS cluster with IAM roles for service accounts (IRSA) configured
- AWS ECR repository with the API Gateway image
- AWS Cognito User Pool configured
- AWS DynamoDB table for environment lookup

## Quick Start

```bash
# Add the Helm repository (if using a repository)
# helm repo add straiker https://charts.straiker.ai

# Install the API Gateway
helm upgrade --install api-gateway ./deploy/helm/api-gateway \
  --namespace straiker \
  --create-namespace \
  --values ./deploy/helm/api-gateway/values.yaml
```

## Configuration

### Required Values

Update the following values in `values.yaml`:

```yaml
straiker:
  apiGateway:
    aws:
      cognito:
        issuerUrl: "https://cognito-idp.us-east-1.amazonaws.com/YOUR_USER_POOL_ID"
        jwkSetUri: "https://cognito-idp.us-east-1.amazonaws.com/YOUR_USER_POOL_ID/.well-known/jwks.json"
      dynamodb:
        region: "us-east-1"
        environmentTable: "YOUR_ENVIRONMENT_TABLE"
      secretManager:
        secretName: "YOUR_SECRET_NAME"
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: "arn:aws:iam::YOUR_ACCOUNT:role/YOUR_POD_ROLE"
    image:
      registry: "YOUR_ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/straiker"
      version: "latest"
```

### Environment-Specific Values

Create environment-specific values files:

```bash
# Development
helm upgrade --install api-gateway ./deploy/helm/api-gateway \
  --namespace straiker-dev \
  --values ./deploy/helm/api-gateway/values.yaml \
  --values ./deploy/helm/api-gateway/values-dev.yaml

# Production
helm upgrade --install api-gateway ./deploy/helm/api-gateway \
  --namespace straiker-prod \
  --values ./deploy/helm/api-gateway/values.yaml \
  --values ./deploy/helm/api-gateway/values-prod.yaml
```

## Architecture

The chart creates the following Kubernetes resources:

1. **ServiceAccount**: For AWS IAM role integration
2. **Deployment**: API Gateway application with health checks
3. **Service**: LoadBalancer service with SSL termination
4. **ConfigMap**: Application configuration
5. **Secret**: Sensitive configuration values

## Security

### AWS IAM Integration

The API Gateway uses IAM roles for service accounts (IRSA) to access AWS services:

- **Cognito**: JWT token validation
- **Secrets Manager**: API key storage
- **DynamoDB**: Environment lookup via API key

### SSL/TLS Configuration

The service is configured with:
- AWS Certificate Manager (ACM) certificate
- TLS 1.3 security policy
- HTTP/2 preferred ALPN policy

## Monitoring

### Health Checks

- **Liveness Probe**: `/management/health/liveness`
- **Readiness Probe**: `/management/health/readiness`

### Metrics

- **Prometheus**: `/management/prometheus`
- **Actuator**: `/management/metrics`

## Troubleshooting

### Common Issues

1. **Image Pull Errors**
   ```bash
   # Check if the image exists in ECR
   aws ecr describe-images --repository-name straiker/api-gateway
   ```

2. **Service Account Issues**
   ```bash
   # Verify IRSA is configured
   kubectl describe serviceaccount straiker-api-gateway-sa -n straiker
   ```

3. **Health Check Failures**
   ```bash
   # Check pod logs
   kubectl logs -f deployment/api-gateway-deployment -n straiker
   
   # Check pod status
   kubectl describe pod -l app.straiker.io/app=api-gateway -n straiker
   ```

### Logs

```bash
# View application logs
kubectl logs -f deployment/api-gateway-deployment -n straiker

# View logs with timestamps
kubectl logs -f deployment/api-gateway-deployment -n straiker --timestamps
```

## Uninstall

```bash
# Remove the deployment
helm uninstall api-gateway -n straiker

# Delete the namespace (optional)
kubectl delete namespace straiker
```

## Values Reference

| Parameter | Description | Default |
|-----------|-------------|---------|
| `straiker.apiGateway.aws.region` | AWS region | `us-east-1` |
| `straiker.apiGateway.aws.cognito.issuerUrl` | Cognito issuer URL | Required |
| `straiker.apiGateway.aws.cognito.jwkSetUri` | Cognito JWK set URI | Required |
| `straiker.apiGateway.dynamodb.region` | DynamoDB region | `us-east-1` |
| `straiker.apiGateway.dynamodb.environmentTable` | DynamoDB table name | Required |
| `straiker.apiGateway.replicas` | Number of replicas | `1` |
| `straiker.apiGateway.resources.limits.cpu` | CPU limit | `1000m` |
| `straiker.apiGateway.resources.limits.memory` | Memory limit | `1Gi` |
| `straiker.apiGateway.resources.requests.cpu` | CPU request | `1000m` |
| `straiker.apiGateway.resources.requests.memory` | Memory request | `1Gi` |