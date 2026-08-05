cd terraform/k8s-cluster
cp terraform.tfvars.example terraform.tfvars   # set your IP in allowed_ssh_cidr
terraform init
terraform apply
