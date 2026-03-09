## Summary
<!-- What does this PR do? -->

## Type
- [ ] Infrastructure / Ansible
- [ ] Backend API
- [ ] Frontend (admin panel)
- [ ] Frontend (client panel)
- [ ] Kubernetes manifests
- [ ] Terraform
- [ ] Documentation
- [ ] Bug fix

## Testing
- [ ] Tested locally (Docker Compose / minikube / kind)
- [ ] Tested on staging cluster
- [ ] Ansible playbook run with `--check` first

## Rollback Plan
<!-- How do we undo this if it breaks production? -->

## Checklist
- [ ] No secrets committed (use Sealed Secrets / ansible-vault)
- [ ] `terraform fmt` run (if Terraform change)
- [ ] `ansible-lint` passes (if Ansible change)
- [ ] Tests pass
- [ ] Docs updated if behaviour changed
