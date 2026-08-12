# One ECR repo per image mirrored from Straiker's source registry (GAR), named
# "<prefix>/<relative image path>" so they're clearly Straiker-managed and never
# collide with unrelated repos in the customer's account.
# MUTABLE tags — the hauling Job re-pushing the same tag on retry must not fail.
resource "aws_ecr_repository" "mirror" {
  for_each = toset(local.image_names)

  name                 = "${var.prefix}/${each.value}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.common_tags
}
