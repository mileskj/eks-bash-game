#!/bin/bash
set -e

# Script that spins up an EKS cluster and adds a web page onto the cluster
# This script is mean't to streamline the process and only require minimal user input

echo "This script will create an EKS cluster on AWS, running a web page hosted on a docker image."
echo "For this script to run properly, the AWS CLI, eksctl and kubectl need to be pre-installed."
echo ""

# Gets clusterName and the region that will be used, and also saves the users AWS Account ID
read -p 'Name of the cluster?: ' clusterName
read -p 'What is your region?: ' region
awsAccountId=$(aws sts get-caller-identity --query 'Account' --output text)

echo "Your AWS Account Id is: $awsAccountId"

# Main command which creates the cluster on the specifications
# TODO - if this command fails for any reason, create cluster cannot be run again due CloudFormationStack remaining
# Sometimes CloudFormationStack doesn't delete because VPC doesn't want to delete and have to do it manually
# Need to come up with a solution to this problem in script
eksctl create cluster --name $clusterName --region $region --fargate

# TODO - if there are any errors from here past when the cluster is created, I want to automatically delete the cluster
# This will be to ensure when the script is run again, I won't have to do any cleanup before
# Ensures that AWS CLI uses the proper configurations for created cluster
aws eks update-kubeconfig --name $clusterName --region $region

# Creates the fargate profile to run the containers with
# TODO - Need to get the namespace from the yaml and put it in this command
eksctl create fargateprofile --cluster "$clusterName" --region "$region" --name alb-sample-app --namespace $namespace

# Applies the YAML provided to create the namespace, deployment, service, then ingress
kubectl apply -f ./snake_full.yaml

# Command to integrate the IAM into the ALB to communicate with those resources
eksctl utils associate-iam-oidc-provider --cluster "$clusterName" --approve

#Downloads the IAM Policy JSON
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.5.4/docs/install/iam_policy.json

# Creates an IAM policy for the ALB to use AWS resources
aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file://iam_policy.json

# Creates an IAM service account for the ALB to use
eksctl create iamserviceaccount \
  --cluster=$clusterName \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::$awsAccountId:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve

# Connects to the HELM repository if not already there
helm repo add eks https://aws.github.io/eks-charts

# Updates the HELM repository
helm repo update eks

#Gets the VPC ID of the created EKS cluster
vpcId=$(aws eks describe-cluster --name '$clusterName' | grep -Po '"vpcId": *\K"[^"]*"' | tr -d \")

# Uses Helm to install the ALB controller using the provided cluster, VPC and region information
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \            
  -n kube-system \
  --set clusterName=$clusterName \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=$region \
  --set vpcId=$vpcId

# Check if deployments are running
deploymentRunning=false
echo "Checking if deployment is running..."
while [ $deploymentRunning == false ]
do
  replicasNumber=$(kubectl get deployment -n kube-system aws-load-balancer-controller -o=jsonpath='{$.status.readyReplicas}' | tr -d \")
  if [ $((replicasNumber)) >= 1 ]; then
  echo "Deployment is now running!"
    deploymentRunning=true
  fi
done

#If deployments are running then print out the DNS address
#TODO - This might not be the DNS address you need, but instead the one on the ec2 load balancer
dnsAddress=$(aws eks describe-cluster --name '$clusterName' | grep -Po '"endpoint": *\K"[^"]*"' | tr -d \")
echo "The URL is $dnsAddress"
echo "Opening URL now!"

# Automatically open the DNS address on browser
xdg-open $dnsAddress

# Now that the URL is open, asks if wants to clean everything by deleting the cluster
read -p 'URL open! Would you like to delete this cluster? (y if yes, n if no): ' exitPrompt
if [ $exitPrompt == "y" ]; then
  eksctl delete cluster --name $clusterName --region $region
  #TODO - Deleting load balancer on EC2 can stall, might need to do it directly

  eksctl delete iamserviceaccount --cluster $clusterName --namespace kube-system --name aws-load-balancer-controller
  wait
  echo "Cluster deleted! Exiting now."
  exit 0
fi