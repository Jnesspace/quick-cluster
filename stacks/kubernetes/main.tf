terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

# This will be configured by Spacelift with the kubeconfig from the K3s cluster
provider "kubernetes" {
  # Kubeconfig will be provided by Spacelift
}

# Basic namespace for our applications
resource "kubernetes_namespace" "tofusible" {
  metadata {
    name = "tofusible"
    labels = {
      name = "tofusible"
      managed-by = "spacelift"
    }
  }
}

# Example deployment - simple nginx
resource "kubernetes_deployment" "nginx" {
  metadata {
    name      = "nginx-example"
    namespace = kubernetes_namespace.tofusible.metadata[0].name
    labels = {
      app = "nginx-example"
    }
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = "nginx-example"
      }
    }

    template {
      metadata {
        labels = {
          app = "nginx-example"
        }
      }

      spec {
        container {
          image = "nginx:latest"
          name  = "nginx"

          port {
            container_port = 80
          }

          resources {
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
            requests = {
              cpu    = "250m"
              memory = "128Mi"
            }
          }
        }
      }
    }
  }
}

# Service to expose nginx
resource "kubernetes_service" "nginx" {
  metadata {
    name      = "nginx-service"
    namespace = kubernetes_namespace.tofusible.metadata[0].name
  }

  spec {
    selector = {
      app = "nginx-example"
    }

    port {
      port        = 80
      target_port = 80
      node_port   = 30080
    }

    type = "NodePort"
  }
}

# Output information
output "namespace" {
  value = kubernetes_namespace.tofusible.metadata[0].name
}

output "nginx_service" {
  value = {
    name      = kubernetes_service.nginx.metadata[0].name
    namespace = kubernetes_service.nginx.metadata[0].namespace
    node_port = 30080
  }
}