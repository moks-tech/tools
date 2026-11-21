# Role that mrjithendar/k8s-deployments' .github/workflows/create-mk-infrastructure.yml assumes through GitHub OIDC to read and write the
# minikube-infrastructure/ state. Any workflow in any repository of the mrjithendar organization can assume it
# (any branch, tag, pull request or environment). It has AdministratorAccess (full control of the AWS account).
# The GitHub OIDC provider already exists in the account; its ARN is fixed, so it is built, not looked up.
locals {
  minikube_state_bucket = "jithendardharmapuri"
  minikube_state_key    = "terraform/k3s-mk4.tfstate"
}

resource "aws_iam_role" "github_minikube_terraform" {
  name                 = "github-tools-minikube-terraform"
  description          = "GitHub Actions (any mrjithendar organization repository): AdministratorAccess"
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = "arn:aws:iam::${data.aws_caller_identity.bedrock.account_id}:oidc-provider/token.actions.githubusercontent.com" }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # Wildcards only work with StringLike. Any repo, branch, tag, PR or environment in the mrjithendar organization.
        # Every org repository uses GitHub's immutable subject, so sub carries the owner and repository IDs
        # (gh api repos/mrjithendar/<repo>/actions/oidc/customization/sub), e.g.
        # repo:mrjithendar@257155124/k8s-deployments@583559700:environment:mk4. Pinning the org ID 257155124 means a
        # future owner of the name "mrjithendar" (after another rename) gets nothing; a rename breaks this until updated.
        # Never "repo:*@257155124/*": branch names may contain "@" and "/", so another owner's branch could match.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:mrjithendar@257155124/*"
        }
      }
    }]
  })
}

# Full access to the AWS account for any workflow in any mrjithendar organization repository.
resource "aws_iam_role_policy_attachment" "github_minikube_terraform_admin" {
  role       = aws_iam_role.github_minikube_terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# resource "aws_iam_role_policy" "github_minikube_terraform_state" {
#   name = "minikube-terraform-state"
#   role = aws_iam_role.github_minikube_terraform.id
#   policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Effect    = "Allow"
#         Action    = "s3:ListBucket"
#         Resource  = "arn:aws:s3:::${local.minikube_state_bucket}"
#         Condition = { StringLike = { "s3:prefix" = ["${local.minikube_state_key}*"] } }
#       },
#       {
#         Effect   = "Allow"
#         Action   = ["s3:GetObject", "s3:PutObject"]
#         Resource = "arn:aws:s3:::${local.minikube_state_bucket}/${local.minikube_state_key}"
#       },
#       {
#         # use_lockfile = true: the S3 backend locks with "<key>.tflock".
#         Effect   = "Allow"
#         Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
#         Resource = "arn:aws:s3:::${local.minikube_state_bucket}/${local.minikube_state_key}.tflock"
#       },
#     ]
#   })
# }



# Role that this repository's .github/workflows/create-aws-infrastructure.yml assumes through GitHub OIDC to plan and
# apply infrastructure/ on a GitHub-hosted runner (the self-hosted runner used its EC2 instance role instead).
# Only master of mrjithendar/aws-infra can assume it; that workflow only runs on master. This repo manages IAM roles
# with AdministratorAccess, so the role needs the same.
# Bootstrap: this role must be applied once from a workstation before the workflow can use it (also after a rename).
# aws-infra uses GitHub's immutable subject (gh api repos/mrjithendar/aws-infra/actions/oidc/customization/sub).
resource "aws_iam_role" "github_tools_terraform" {
  name                 = "github-tools-terraform"
  description          = "GitHub Actions (mrjithendar/aws-infra, master): terraform apply of infrastructure/"
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = "arn:aws:iam::${data.aws_caller_identity.bedrock.account_id}:oidc-provider/token.actions.githubusercontent.com" }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:mrjithendar@257155124/aws-infra@696284066:ref:refs/heads/master"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "github_tools_terraform_admin" {
  role       = aws_iam_role.github_tools_terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
