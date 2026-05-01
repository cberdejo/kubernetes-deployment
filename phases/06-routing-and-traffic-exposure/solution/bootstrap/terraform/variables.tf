variable "dockerhub_user" {
  type        = string
  description = "Docker Hub username — images must already be pushed"
}

variable "image_tag" {
  type    = string
  default = "1.0.0"
}

variable "postgres_user" {
  type    = string
  default = "admin"
}

variable "postgres_password" {
  type      = string
  sensitive = true
}

variable "postgres_db" {
  type    = string
  default = "domain"
}

variable "release_name" {
  type    = string
  default = "my-app"
}
