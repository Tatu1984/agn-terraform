output "public_ip" {
  description = "Point the domain's A record here."
  value       = aws_eip.app.public_ip
}

output "rds_endpoint" {
  value = aws_db_instance.main.address
}

output "media_base_url" {
  value = "https://${aws_cloudfront_distribution.media.domain_name}"
}

output "ssm_shell" {
  description = "Browser shell fallback."
  value       = "EC2 console → ${aws_instance.app.id} → Connect → Session Manager"
}
