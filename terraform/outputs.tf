output "ecr_url" {
  value = aws_ecr_repository.weblog.repository_url
}

output "rds_endpoint" {
  value = aws_db_instance.weblog.address
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}
