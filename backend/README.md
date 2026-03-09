# Management API

> **Status:** Scaffold placeholder — implementation starts Phase 1 Week 3  
> **Stack:** Node.js 22 + Fastify + TypeScript  
> **Spec:** [`../docs/04-deployment/MANAGEMENT_API_SPEC.md`](../docs/04-deployment/MANAGEMENT_API_SPEC.md)

The Management API is the core backend for the hosting platform. It handles all client provisioning, domain management, DNS record management, database allocation, and the admin/client panel APIs.

## Getting Started

```bash
npm install
npm run dev
```

## Structure (planned)

```
src/
├── routes/
│   ├── clients/
│   ├── domains/
│   ├── dns/
│   ├── databases/
│   └── admin/
├── services/
│   ├── powerdns/
│   ├── kubernetes/
│   └── billing/
├── middleware/
└── db/
```
