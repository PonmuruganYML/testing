resource "aws_ssm_parameter" "foo" {
  name  = "codebuild"
  type  = "String"
  value = "codebuildtest"
}
