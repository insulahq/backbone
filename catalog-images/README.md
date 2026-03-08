# Workload Catalog Images

> **Status:** Scaffold placeholder — built during Phase 1 Week 2-3  
> **Spec:** [`../docs/01-core/PLATFORM_ARCHITECTURE.md`](../docs/01-core/PLATFORM_ARCHITECTURE.md) — Section 2

Each subdirectory contains the Dockerfile for one catalog image. All images are built, scanned with Trivy, and pushed to Harbor by CI.

| Directory | Image ID | Runtime |
|-----------|----------|---------|
| `apache-php84/` | `apache-php84` | Apache 2.4 + PHP 8.4 |
| `nginx-php84/` | `nginx-php84` | Nginx + PHP-FPM 8.4 |
| `node22/` | `node22` | Node.js 22 |
| ... | ... | ... |
