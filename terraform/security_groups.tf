resource "aws_security_group" "control_plane" {
  name        = "${var.cluster_name}-control-plane-sg"
  description = "Control-plane node: SSH, Kubernetes API server, and cluster-internal traffic"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name = "${var.cluster_name}-control-plane-sg"
  }
}

resource "aws_security_group" "worker" {
  name        = "${var.cluster_name}-worker-sg"
  description = "Worker node: SSH, kubelet, and NodePort traffic"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name = "${var.cluster_name}-worker-sg"
  }
}

# --- SSH ---

resource "aws_security_group_rule" "ssh_control_plane" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [var.allowed_ssh_cidr]
  security_group_id = aws_security_group.control_plane.id
  description       = "SSH"
}

resource "aws_security_group_rule" "ssh_worker" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [var.allowed_ssh_cidr]
  security_group_id = aws_security_group.worker.id
  description       = "SSH"
}

# --- Kubernetes API server (kubectl access from outside) ---

resource "aws_security_group_rule" "api_server" {
  type              = "ingress"
  from_port         = 6443
  to_port           = 6443
  protocol          = "tcp"
  cidr_blocks       = [var.allowed_k8sapi_cidr]
  security_group_id = aws_security_group.control_plane.id
  description       = "Kubernetes API server"
}

# --- k3s API server: reachable from worker nodes joining the cluster ---

resource "aws_security_group_rule" "api_server_from_worker" {
  type                     = "ingress"
  from_port                = 6443
  to_port                  = 6443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.worker.id
  security_group_id        = aws_security_group.control_plane.id
  description              = "Kubernetes API server from worker"
}

# --- kubelet API: reachable between control plane and worker ---

resource "aws_security_group_rule" "kubelet_self_control_plane" {
  type                     = "ingress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.control_plane.id
  security_group_id        = aws_security_group.control_plane.id
  description              = "kubelet API self"
}

resource "aws_security_group_rule" "kubelet_from_worker" {
  type                     = "ingress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.worker.id
  security_group_id        = aws_security_group.control_plane.id
  description              = "kubelet API from worker"
}

resource "aws_security_group_rule" "kubelet_from_control_plane" {
  type                     = "ingress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.control_plane.id
  security_group_id        = aws_security_group.worker.id
  description              = "kubelet API from control plane"
}

# --- NodePort services ---

resource "aws_security_group_rule" "nodeport_control_plane" {
  type              = "ingress"
  from_port         = 30000
  to_port           = 32767
  protocol          = "tcp"
  cidr_blocks       = [var.allowed_ssh_cidr]
  security_group_id = aws_security_group.control_plane.id
  description       = "NodePort services"
}

resource "aws_security_group_rule" "nodeport_worker" {
  type              = "ingress"
  from_port         = 30000
  to_port           = 32767
  protocol          = "tcp"
  cidr_blocks       = [var.allowed_ssh_cidr]
  security_group_id = aws_security_group.worker.id
  description       = "NodePort services"
}

# --- Flannel VXLAN overlay between the two nodes ---

resource "aws_security_group_rule" "flannel_vxlan_from_worker" {
  type                     = "ingress"
  from_port                = 8472
  to_port                  = 8472
  protocol                 = "udp"
  source_security_group_id = aws_security_group.worker.id
  security_group_id        = aws_security_group.control_plane.id
  description              = "Flannel VXLAN from worker"
}

resource "aws_security_group_rule" "flannel_vxlan_from_control_plane" {
  type                     = "ingress"
  from_port                = 8472
  to_port                  = 8472
  protocol                 = "udp"
  source_security_group_id = aws_security_group.control_plane.id
  security_group_id        = aws_security_group.worker.id
  description              = "Flannel VXLAN from control plane"
}

# --- Egress ---

resource "aws_security_group_rule" "egress_control_plane" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.control_plane.id
  description       = "Allow all outbound"
}

resource "aws_security_group_rule" "egress_worker" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.worker.id
  description       = "Allow all outbound"
}
