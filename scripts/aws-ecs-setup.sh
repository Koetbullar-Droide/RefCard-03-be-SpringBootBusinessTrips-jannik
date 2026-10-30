#!/usr/bin/env bash
# EX-03: Legt die komplette AWS-Infrastruktur für Backend + Frontend auf ECS (Fargate) an.
# Einmalig ausführen, nachdem die Learner-Lab-Credentials im Profil "learner-lab" stehen:
#   ./scripts/aws-ecs-setup.sh [pfad-zum-frontend-repo]
set -euo pipefail

export AWS_PROFILE=learner-lab
export AWS_REGION=us-east-1
export AWS_PAGER=""

FE_REPO="${1:-../refcard-03-fe-react-vite-1-start}"
DB_PASSWORD="${DB_PASSWORD:-Biztrips$(openssl rand -hex 6)}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "AWS-Account: $ACCOUNT_ID (Region $AWS_REGION)"

# --- Netzwerk: Default-VPC mit zwei Subnets (für den Load Balancer nötig) ---
VPC_ID=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query "Vpcs[0].VpcId" --output text)
SUBNETS=$(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values="$VPC_ID" Name=availability-zone,Values=us-east-1a,us-east-1b \
  --query "Subnets[].SubnetId" --output text)
SUBNET_CSV=$(echo "$SUBNETS" | tr '\t' ',')
echo "VPC $VPC_ID, Subnets $SUBNET_CSV"

# --- Security Groups: ALB (80 aus Internet) -> Tasks -> RDS (3306 nur von Backend-Tasks) ---
sg() { aws ec2 create-security-group --group-name "$1" --description "$1" --vpc-id "$VPC_ID" --query GroupId --output text; }
SG_ALB=$(sg biztrips-alb-sg)
SG_BE=$(sg biztrips-backend-tasks-sg)
SG_FE=$(sg biztrips-frontend-tasks-sg)
SG_DB=$(sg biztrips-db-sg)
aws ec2 authorize-security-group-ingress --group-id "$SG_ALB" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG_BE" --protocol tcp --port 8080 --source-group "$SG_ALB" >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG_FE" --protocol tcp --port 80 --source-group "$SG_ALB" >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG_DB" --protocol tcp --port 3306 --source-group "$SG_BE" >/dev/null

# --- RDS MariaDB (dauert ~5-10 Minuten) + Passwort in Secrets Manager ---
aws rds create-db-instance \
  --db-instance-identifier biztrips-backend-db \
  --db-instance-class db.t3.micro \
  --engine mariadb \
  --master-username admin \
  --master-user-password "$DB_PASSWORD" \
  --allocated-storage 20 \
  --db-name db_biztrips \
  --vpc-security-group-ids "$SG_DB" \
  --no-publicly-accessible >/dev/null
# ECS braucht die volle Secrets-Manager-ARN (nur der Name würde im SSM Parameter Store gesucht)
SECRET_ARN=$(aws secretsmanager create-secret --name biztrips-backend-db-password --secret-string "$DB_PASSWORD" --query ARN --output text)

# --- ECR-Repositories + ECS-Cluster ---
aws ecr create-repository --repository-name biztrips-backend >/dev/null
aws ecr create-repository --repository-name biztrips >/dev/null
aws ecs create-cluster --cluster-name biztrips-backend-cluster >/dev/null
aws ecs create-cluster --cluster-name biztrips-cluster >/dev/null

# --- Load Balancer + Target Groups (Typ ip, weil Fargate-Tasks eigene IPs haben) ---
alb() { aws elbv2 create-load-balancer --name "$1" --subnets $SUBNETS --security-groups "$SG_ALB" --query "LoadBalancers[0].LoadBalancerArn" --output text; }
ALB_BE=$(alb biztrips-backend-alb)
ALB_FE=$(alb biztrips-frontend-alb)
TG_BE=$(aws elbv2 create-target-group --name biztrips-backend-tg --protocol HTTP --port 8080 --vpc-id "$VPC_ID" \
  --target-type ip --health-check-path /actuator/health --query "TargetGroups[0].TargetGroupArn" --output text)
TG_FE=$(aws elbv2 create-target-group --name biztrips-frontend-tg --protocol HTTP --port 80 --vpc-id "$VPC_ID" \
  --target-type ip --health-check-path / --query "TargetGroups[0].TargetGroupArn" --output text)
aws elbv2 create-listener --load-balancer-arn "$ALB_BE" --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn="$TG_BE" >/dev/null
aws elbv2 create-listener --load-balancer-arn "$ALB_FE" --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn="$TG_FE" >/dev/null
BE_URL="http://$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_BE" --query "LoadBalancers[0].DNSName" --output text)/"
FE_URL="http://$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_FE" --query "LoadBalancers[0].DNSName" --output text)/"

# --- Auf RDS warten und Endpoint in die Task Definition eintragen ---
echo "Warte auf RDS (kann bis zu 10 Minuten dauern) ..."
aws rds wait db-instance-available --db-instance-identifier biztrips-backend-db
RDS_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier biztrips-backend-db \
  --query "DBInstances[0].Endpoint.Address" --output text)

sed -i.bak -e "s/<ACCOUNT_ID>/$ACCOUNT_ID/g" -e "s/<RDS_ENDPOINT>/$RDS_ENDPOINT/g" -e "s#<DB_SECRET_ARN>#$SECRET_ARN#g" task-definition.json && rm task-definition.json.bak
sed -i.bak -e "s/<ACCOUNT_ID>/$ACCOUNT_ID/g" "$FE_REPO/task-definition.json" && rm "$FE_REPO/task-definition.json.bak"

# --- Task Definitions registrieren und Services anlegen (je 2 Tasks) ---
# Die Images baut und pusht erst GitHub Actions beim nächsten Push auf main. Bis dahin
# schlagen die Tasks mit "CannotPullContainerError" fehl - das ist erwartet.
aws ecs register-task-definition --cli-input-json file://task-definition.json >/dev/null
aws ecs register-task-definition --cli-input-json "file://$FE_REPO/task-definition.json" >/dev/null
aws ecs create-service --cluster biztrips-backend-cluster --service-name biztrips-backend-service \
  --task-definition biztrips-backend --desired-count 2 --launch-type FARGATE \
  --health-check-grace-period-seconds 180 \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_CSV],securityGroups=[$SG_BE],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=$TG_BE,containerName=biztrips-backend,containerPort=8080" >/dev/null
aws ecs create-service --cluster biztrips-cluster --service-name biztrips-service \
  --task-definition biztrips --desired-count 2 --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_CSV],securityGroups=[$SG_FE],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=$TG_FE,containerName=biztrips,containerPort=80" >/dev/null

# --- Backend-URL als GitHub-Variable im Frontend-Repo setzen (wird beim Build einkompiliert) ---
(cd "$FE_REPO" && gh variable set VITE_API_BASE_URL --body "$BE_URL")

echo
echo "Infrastruktur fertig. Nach dem ersten Pipeline-Lauf erreichbar unter:"
echo "  Backend:  ${BE_URL}v1/trips   (Health: ${BE_URL}actuator/health)"
echo "  Frontend: $FE_URL"
