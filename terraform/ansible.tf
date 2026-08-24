locals {
  ansible_dir           = "${path.module}/ansible"
  inventory_path        = "${local.ansible_dir}/inventory.ini"
  local_kubeconfig_path = "${path.module}/${var.cluster_name}-kubeconfig.yaml"
}

resource "local_file" "ansible_inventory" {
  filename = local.inventory_path
  content = templatefile("${local.ansible_dir}/inventory.tftpl", {
    control_plane_ip      = "${aws_instance.control_plane.public_ip}"
    worker_ip             = "${aws_instance.worker.public_ip}"
    private_key_path      = "${abspath(local_sensitive_file.private_key.filename)}"
    kubernetes_version    = "${var.kubernetes_version}"
    pod_network_cidr      = "${var.pod_network_cidr}"
    local_kubeconfig_path = "${abspath(local.local_kubeconfig_path)}"
  })
}

resource "null_resource" "run_ansible" {
  depends_on = [local_file.ansible_inventory]

  triggers = {
    control_plane_id = aws_instance.control_plane.id
    worker_id        = aws_instance.worker.id
    inventory_hash   = local_file.ansible_inventory.content_md5
  }

  provisioner "local-exec" {
    working_dir = local.ansible_dir
    command     = "ansible-playbook -i inventory.ini site.yml"
  }
}
