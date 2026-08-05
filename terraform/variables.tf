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

variable "k3s_channel" {
  description = "k3s release channel to install (e.g. \"stable\", \"latest\", or a minor-version channel like \"v1.30\")"
  type        = string
  default     = "stable"
}

variable "pod_network_cidr" {
  description = "Pod network CIDR passed to k3s as --cluster-cidr, used by the bundled Flannel CNI"
  type        = string
  default     = "10.244.0.0/16"
}

variable "root_volume_size" {
  description = "Root EBS volume size (GiB) for both nodes"
  type        = number
  default     = 30
}
