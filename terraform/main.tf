# ponytail: default VPC. Own VPC/private subnets only if the client requires network isolation.
data "aws_vpc" "default" {
  default = true
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }
}

# --- Security groups ---------------------------------------------------------

resource "aws_security_group" "web" {
  name   = "${var.name}-web"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
  ingress {
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
  # No port 22: SSH goes through SSM Session Manager (see ansible/ansible.cfg).
  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_security_group" "db" {
  name   = "${var.name}-db"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }
}

# --- RDS Postgres ------------------------------------------------------------

# Alphanumeric only: it goes straight into DATABASE_URL without URL-encoding.
resource "random_password" "db" {
  length  = 32
  special = false
}

resource "aws_db_instance" "main" {
  identifier                = "${var.name}-db"
  engine                    = "postgres"
  engine_version            = var.db_engine_version
  instance_class            = var.db_instance_class
  allocated_storage         = 20
  max_allocated_storage     = 50
  storage_type              = "gp3"
  storage_encrypted         = true
  db_name                   = var.name
  username                  = var.name
  password                  = random_password.db.result
  vpc_security_group_ids    = [aws_security_group.db.id]
  publicly_accessible       = false
  backup_retention_period   = 7
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name}-db-final"
  apply_immediately         = true
}

# --- S3 + CloudFront ---------------------------------------------------------

resource "aws_s3_bucket" "media" {
  bucket = var.media_bucket_name
}

resource "aws_s3_bucket_public_access_block" "media" {
  bucket                  = aws_s3_bucket.media.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "media" {
  name                              = "${var.name}-media"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "media" {
  enabled     = true
  price_class = "PriceClass_100" # US/EU edges only — cheapest

  origin {
    origin_id                = "s3"
    domain_name              = aws_s3_bucket.media.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.media.id
  }

  default_cache_behavior {
    target_origin_id       = "s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # Managed-CachingOptimized
    compress               = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

resource "aws_s3_bucket_policy" "media" {
  bucket = aws_s3_bucket.media.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.media.arn}/*"
      Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.media.arn } }
    }]
  })
}

# --- IAM role for the app server --------------------------------------------

resource "aws_iam_role" "app" {
  name = "${var.name}-ec2"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

# Browser shell (EC2 → Connect → Session Manager) as a fallback to SSH.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "media" {
  name = "media-bucket"
  role = aws_iam_role.app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:ListBucket"], Resource = aws_s3_bucket.media.arn },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "${aws_s3_bucket.media.arn}/*" },
    ]
  })
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.name}-ec2"
  role = aws_iam_role.app.name
}

# --- EC2 ---------------------------------------------------------------------

# Only used when the instance is first created; team access afterwards is managed
# by Ansible (team_ssh_keys). ignore_changes so a teammate without this file can apply.
resource "aws_key_pair" "deploy" {
  key_name   = "${var.name}-deploy"
  public_key = try(file(pathexpand(var.ssh_public_key_path)), "unused-after-create")
  lifecycle {
    ignore_changes = [public_key]
  }
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.deploy.key_name
  iam_instance_profile   = aws_iam_instance_profile.app.name
  vpc_security_group_ids = [aws_security_group.web.id]

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required" # IMDSv2
    # 2 hops: the app runs in a Docker container and must reach IMDS for the role's S3 creds.
    http_put_response_hop_limit = 2
  }

  tags = { Name = "${var.name}-app" }

  lifecycle {
    ignore_changes = [ami] # new Ubuntu AMIs must not replace the running server
  }
}

resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"
}

# --- Hand-off to Ansible -----------------------------------------------------

resource "local_file" "inventory" {
  filename        = "${path.module}/../ansible/inventory.ini"
  file_permission = "0644"
  content         = <<-EOT
    [app]
    ${aws_instance.app.id} ansible_user=ubuntu
  EOT
}

resource "local_sensitive_file" "tf_vars" {
  filename        = "${path.module}/../ansible/group_vars/all/terraform.yml"
  file_permission = "0600"
  content = yamlencode({
    aws_region     = var.region
    public_ip      = aws_eip.app.public_ip
    db_host        = aws_db_instance.main.address
    db_name        = aws_db_instance.main.db_name
    db_user        = aws_db_instance.main.username
    db_password    = random_password.db.result
    media_bucket   = aws_s3_bucket.media.bucket
    media_base_url = "https://${aws_cloudfront_distribution.media.domain_name}"
  })
}
