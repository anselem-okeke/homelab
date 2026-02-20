#!/bin/bash

cat > /mnt/data/homelab/k8s/manifest/alloy-audit-values.yaml <<'YAML'
controller:
  type: daemonset
  nodeSelector:
    node-role.kubernetes.io/control-plane: ""
  tolerations:
    - operator: Exists
  volumes:
    extra:
      - name: auditlog
        hostPath:
          path: /var/log/audit/kube
          type: DirectoryOrCreate

alloy:
  configMap:
    create: true
    content: |
      local.file_match "k8s_audit" {
        path_targets = [{
          __address__ = "localhost",
          __path__    = "/var/log/audit/kube/kube-apiserver*.log",
        }]
      }

      loki.source.file "audit" {
        targets      = local.file_match.k8s_audit.targets
        forward_to   = [loki.process.audit.receiver]
        start_at_end = true
      }

      loki.process "audit" {
        forward_to = [loki.write.local.receiver]

        stage.static_labels {
          values = {
            job    = "k8s-audit",
            stream = "k8s-audit",
            source = "apiserver-audit",
            node   = constants.hostname,
          }
        }

        stage.json {
          expressions = {
            stage     = "stage",
            verb      = "verb",
            user      = "user.username",
            namespace = "objectRef.namespace",
            resource  = "objectRef.resource",
            code      = "responseStatus.code",
            uri       = "requestURI",
          }
        }

        # Keep only final outcome (drops RequestReceived/ResponseStarted duplicates)
        stage.match {
          selector = "{job=\"k8s-audit\"}"
          stages {
            stage.match {
              expression = "stage != \"ResponseComplete\""
              action     = "drop"
            }
          }
        }

        # Drop leader-election / coordination noise
        stage.match {
          selector = "{job=\"k8s-audit\"}"
          stages {
            stage.match {
              expression = "resource == \"leases\" && code =~ \"^2\""
              action     = "drop"
            }
          }
        }

        # Drop successful WATCH (biggest remaining volume)
        stage.match {
          selector = "{job=\"k8s-audit\"}"
          stages {
            stage.match {
              expression = "verb == \"watch\" && code =~ \"^2\""
              action     = "drop"
            }
          }
        }

        # Drop successful reads
        stage.match {
          selector = "{job=\"k8s-audit\"}"
          stages {
            stage.match {
              expression = "(verb == \"get\" || verb == \"list\" || verb == \"watch\") && code =~ \"^2\""
              action     = "drop"
            }
          }
        }

        # LOW-cardinality labels only (prevents stream/cardinality explosion)
        stage.labels {
          values = {
            verb = "verb",
            code = "code",
          }
        }
      }

      loki.write "local" {
        endpoint {
          url = "http://loki.logging.svc.cluster.local:3100/loki/api/v1/push"
          headers = {
            "X-Scope-OrgID" = "1",
          }
        }
      }

  mounts:
    extra:
      - name: auditlog
        mountPath: /var/log/audit/kube
        readOnly: true
YAML



