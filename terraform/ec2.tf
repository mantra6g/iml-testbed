resource "aws_instance" "control_plane" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.control_plane_instance_type
  subnet_id                   = data.aws_subnet.selected.id
  vpc_security_group_ids      = [aws_security_group.control_plane.id]
  key_name                    = aws_key_pair.cluster.key_name
  associate_public_ip_address = true

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }

  tags = {
    Name = "${var.cluster_name}-control-plane"
    Role = "control-plane"
  }
}

resource "aws_instance" "worker" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.worker_instance_type
  subnet_id                   = data.aws_subnet.selected.id
  vpc_security_group_ids      = [aws_security_group.worker.id]
  key_name                    = aws_key_pair.cluster.key_name
  associate_public_ip_address = true

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }

  tags = {
    Name = "${var.cluster_name}-worker"
    Role = "worker"
  }
}
