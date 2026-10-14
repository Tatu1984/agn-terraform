# Shared Terraform state (backend in versions.tf). Versioned so a bad apply can be
# rolled back; never destroyed by Terraform.
resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.name}-tfstate-${data.aws_caller_identity.current.account_id}"
  lifecycle {
    prevent_destroy = true
  }
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
