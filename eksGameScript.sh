#!/bin/bash
set -e

# Script that spins up an EKS cluster and adds a web page onto the cluster
# This script is mean't to streamline the process and only require minimal user input

echo "This script will create an EKS cluster on AWS, running a web page hosted on a docker image."
echo "For this script to run properly, the AWS CLI, eksctl and kubectl need to be pre-installed."
echo ""

read -p 'Name of the cluster?: ' clusterName
read -p 'What is your region?: ' region
awsAccountId=$(aws sts get-caller-identity --query 'Account' --output text)

echo "Your AWS Account Id is: $awsAccountId"

eksctl create cluster --name "$clusterName" --region "$region" --fargate
wait

aws eks update-kubeconfig --name "$clusterName"
wait

eksctl create fargateprofile --cluster "$clusterName" --region "$region" --name alb-sample-app --namespace game-2048
wait

kubectl apply -f ./snake_full.yaml
wait

eksctl utils associate-iam-oidc-provider --cluster "$clusterName" --approve
wait

aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file://iam_policy.json
wait

eksctl create iamserviceaccount \
  --cluster=$clusterName \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::$awsAccountId:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve
wait

helm repo add eks https://aws.github.io/eks-charts
wait

helm repo update eks
wait

#need a command that returns the vpc id of the cluster I made

vpcId=$(aws eks describe-cluster --name '$clusterName' | grep -Po '"vpcId": *\K"[^"]*"' | tr -d \")
#read -p 'What is your VPC id of this cluster?: ' vpcId

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \            
  -n kube-system \
  --set clusterName=$clusterName \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=$region \
  --set vpcId=$vpcId
wait

#check if deployments are running
deploymentRunning=false
echo "Checking if deployment is running..."
while [ $deploymentRunning == false ]
do
  replicasNumber=$(kubectl get deployment -n kube-system aws-load-balancer-controller -o=jsonpath='{$.status.availableReplicas}' | tr -d \")
  if [ $((replicasNumber)) >= 1 ]; then
  echo "Deployment is now running!"
    deploymentRunning=true
  fi
done

#if deployments are running, then run command to get the DNS address, so it can be printed out
dnsAddress=$(aws eks describe-cluster --name '$clusterName' | grep -Po '"endpoint": *\K"[^"]*"' | tr -d \")
echo "The URL is $dnsAddress"
echo "Opening URL now!"

#then script will complete, maybe see if theres a command that will open DNS up on your browser?
xdg-open $dnsAddress
wait

#if open up have a prompt that asks if you want to delete the cluster or not
read -p 'URL open! Would you like to delete this cluster? (y if yes, n if no): ' exitPrompt
if [ $exitPrompt == "y" ]; then
  eksctl delete cluster --name $clusterName --region $region
  wait
  echo "Cluster deleted! Exiting now."
  exit 0
fi