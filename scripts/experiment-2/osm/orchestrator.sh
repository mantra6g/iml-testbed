#!/bin/bash

time {
  helm install p4sw-1 oci://ghcr.io/tomasagata/helm/p4-switch --version 0.1.0 \
    --set p4ProgramURL="https://raw.githubusercontent.com/mantra6g/iml/refs/heads/main/examples/simple/logger.p4" && \
  kubectl rollout status deployment/p4sw-1-p4-switch --timeout=120s && \
  kubectl logs -f deployment/p4sw-1-p4-switch | grep -m 1 "Starting simple_switch"
}