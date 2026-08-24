output "cluster_name" {
  description = "Name prefix used to tag and identify this testbed's AWS/kubeconfig resources"
  value       = var.cluster_name
}

output "control_plane_public_ip" {
  description = "Public IP of the control-plane node"
  value       = aws_instance.control_plane.public_ip
}

output "worker_public_ip" {
  description = "Public IP of the worker node"
  value       = aws_instance.worker.public_ip
}

output "ssh_private_key_path" {
  description = "Local path to the generated SSH private key"
  value       = abspath(local_sensitive_file.private_key.filename)
}

output "ssh_control_plane" {
  description = "Command to SSH into the control-plane node"
  value       = "ssh -i ${abspath(local_sensitive_file.private_key.filename)} ubuntu@${aws_instance.control_plane.public_ip}"
}

output "ssh_worker" {
  description = "Command to SSH into the worker node"
  value       = "ssh -i ${abspath(local_sensitive_file.private_key.filename)} ubuntu@${aws_instance.worker.public_ip}"
}

output "kubeconfig_path" {
  description = "Local path to the cluster's kubeconfig, fetched automatically after provisioning (server address rewritten to the control-plane's public IP)"
  value       = abspath(local.local_kubeconfig_path)
}

output "kubectl_local" {
  description = "Command to point kubectl at the fetched kubeconfig"
  value       = "export KUBECONFIG=${abspath(local.local_kubeconfig_path)}"
}
