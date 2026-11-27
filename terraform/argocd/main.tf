# Argo CD, installed once by Terraform and then left to reconcile itself.
#
# Installed here rather than by an Application: an Argo that manages its own
# installation cannot be debugged by the thing it manages when it breaks. After
# this, Terraform owns the cluster and the account; Argo owns what runs on the
# cluster.
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = true

  values = [file("${path.module}/../../argocd/install/values.yaml")]

  # Applied means running: its CRDs and controller have to be ready before
  # anything is pointed at them.
  wait    = true
  timeout = 900
}
