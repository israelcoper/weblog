variable "region" {
  default = "ap-southeast-1"
}

variable "db_password" {
  sensitive = true
}

variable "secret_key_base" {
  sensitive = true
}
