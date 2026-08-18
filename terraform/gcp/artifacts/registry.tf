# One Artifact Registry Docker repo holds every mirrored image, addressed by
# path within it (<region>-docker.pkg.dev/<project>/<prefix>/<image-name>) —
# unlike ECR's one-repository-per-image model in terraform/aws/artifacts/ecr.tf,
# this is Artifact Registry's own idiomatic shape (a single repo is already a
# namespace for arbitrarily many image names) and needs no per-image
# Terraform resource, so charts/straiker-artifact's imageMirror.images list
# can keep growing without a matching Terraform change here.
resource "google_artifact_registry_repository" "mirror" {
  project       = var.project_id
  location      = var.region
  repository_id = var.prefix
  format        = "DOCKER"
  description   = "Straiker onprem image mirror"
  labels        = local.common_labels

  depends_on = [google_project_service.required]
}
