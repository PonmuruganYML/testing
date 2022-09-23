terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "4.11.0"
    }
  }
  backend "remote" {
    organization = "yml"
    workspaces {
      name = "ponmurugan-terraform-workspace"
    }
  }
}

# Configure the AWS Provider
provider "aws" {
  alias   = "primary"
  region  = "eu-west-1"
  profile = "dharmadev"
  # access_key = "AKIAVUCAKTYQXI2SGU52"
  # secret_key = "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"
}


provider "aws" {
  alias  = "us-east-1"
  region = "us-east-1"
}
