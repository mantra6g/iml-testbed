resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "cluster" {
  key_name   = "${var.cluster_name}-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_sensitive_file" "private_key" {
  filename        = "${path.module}/${var.cluster_name}-key.pem"
  content         = tls_private_key.ssh.private_key_pem
  file_permission = "0400"
}
