variable "region" {
  type    = string
  default = "us-west-2"
}

variable "name" {
  description = "Prefix for every resource name."
  type        = string
  default     = "pigeonpulse"
}

variable "media_bucket_name" {
  description = "Globally unique S3 bucket name for uploads."
  type        = string
}

variable "ssh_public_key_path" {
  description = "Public key Ansible connects with."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}


variable "instance_type" {
  type    = string
  default = "t4g.small"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_engine_version" {
  description = "Major version; must be >= the Neon source version."
  type        = string
  default     = "17"
}
