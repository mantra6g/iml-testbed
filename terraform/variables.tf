variable "aws_region" {
  description = "AWS region to deploy the cluster into"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name prefix used to tag and identify cluster resources"
  type        = string
  default     = "iml-k8s-testbed"
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to SSH and reach NodePort services. Set this to your own IP (e.g. 203.0.113.4/32) rather than leaving it open to the world."
  type        = string
}

variable "allowed_k8sapi_cidr" {
  description = "CIDR block allowed to reach the Kubernetes API server (port 6443). Set this to your own IP or trusted range (e.g. 203.0.113.4/32) rather than leaving it open to the world."
  type        = string
}

variable "control_plane_instance_type" {
  description = "EC2 instance type for the control-plane node"
  type        = string
  default     = "c7i-flex.large"
}

variable "worker_instance_type" {
  description = "EC2 instance type for the worker node"
  type        = string
  default     = "c7i-flex.large"
}

variable "kubernetes_version" {
  description = "Kubernetes minor version to install via the pkgs.k8s.io apt repo (e.g. \"1.34\")"
  type        = string
  default     = "1.34"
}

variable "pod_network_cidr" {
  description = "Pod network CIDR passed to kubeadm as --pod-network-cidr, used by the Flannel CNI"
  type        = string
  default     = "10.244.0.0/16"
}

variable "root_volume_size" {
  description = "Root EBS volume size (GiB) for both nodes"
  type        = number
  default     = 30
}
