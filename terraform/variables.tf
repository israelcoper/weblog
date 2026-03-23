variable "region" {
  default = "ap-southeast-1"
}

variable "db_password" {
  sensitive = true
}

variable "secret_key_base" {
  sensitive = true
}

variable "github_repo" {
  description = "GitHub repository in owner/repo format (e.g. octocat/weblog)"
  default = "israelcoper/weblog"
}
