## Summary
<!-- What does this PR do? -->

## Type
- [ ] Infrastructure / Ansible
- [ ] Documentation
- [ ] Bug fix

## Testing
- [ ] Ansible playbook run with `--check` first
- [ ] Deployed to test server
- [ ] `ansible-lint` passes

## Rollback Plan
<!-- How do we undo this if it breaks production? -->

## Checklist
- [ ] No secrets committed (use ansible-vault or `.generated_secrets/`)
- [ ] `ansible-lint` passes (if Ansible change)
- [ ] Docker images pinned to specific versions (no `:latest`)
- [ ] Docs updated if behaviour changed
