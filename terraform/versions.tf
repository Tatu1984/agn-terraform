terraform {
  required_version = ">= 1.6"

  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
    local  = { source = "hashicorp/local", version = "~> 2.5" }
  }

  # Shared state (bucket created by state.tf). Contains the DB password — the bucket
  # is private and only pigeonpulse-deployers can read it. use_lockfile stops two
  # people applying at once.
  backend "s3" {
    bucket       = "pigeonpulse-tfstate-066686950435"
    key          = "pigeonpulse/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = var.name, ManagedBy = "terraform" }
  }
}
