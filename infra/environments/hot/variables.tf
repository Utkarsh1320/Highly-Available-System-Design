variable "node_instance_type" {
  type    = string
  default = "t3.small"
}

variable "node_count" {
  type    = number
  default = 1
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/ha-assignment.pub"
}

variable "ssh_ingress_cidr" {
  description = "Your own IP, e.g. 203.0.113.4/32 — never leave this as 0.0.0.0/0"
  type        = string
}
