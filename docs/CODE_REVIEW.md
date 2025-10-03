# Code Review Summary

## Critical / Bug-Risk Issues

1. **Docker architecture mapping can break on unknown architectures.**  
   The architecture lookup in the Docker role indexes a hard-coded dictionary directly with `ansible_facts.architecture`. If an unexpected architecture string arrives (for example `riscv64` or `loongarch64`), Jinja will raise an `UndefinedError` before the `default` filter is applied, aborting the play. Prefer using `dict.get(key, default)` or the `default` filter on the whole expression instead of the indexed lookup. 【F:ansible/roles/docker/tasks/main.yml†L33-L47】

2. **Hub IP derivation assumes the `hub` inventory group always exists.**  
   The iperf tasks index `groups['hub'][0]` directly; when the `hub` group is missing (for example in standalone-node smoke tests) the play will fail even though the firewall task is skipped. Wrap the access in `groups.get('hub', [])` and guard the lookup before dereferencing. 【F:ansible/roles/node/tasks/iperf.yml†L68-L123】

3. **Basic-auth password handling is logged in plain text.**  
   The htpasswd loop explicitly sets `no_log: false`, causing user passwords (or their hashed form) to be emitted into Ansible logs. Set `no_log: true` (or remove the override entirely) to keep secrets out of logs. 【F:ansible/roles/nginx/tasks/main.yml†L51-L101】

## Refactoring Opportunities

1. **Consolidate WireGuard IP discovery logic.**  
   Both the node and node_exporter roles repeat the same `wg_ip` lookup from `vpn_nodes`. Consider moving this into a reusable fact (e.g. via `set_fact` in `group_vars/all`, a role dependency, or a custom filter) so you only maintain the lookup in one place. 【F:ansible/roles/node/tasks/iperf.yml†L18-L37】【F:ansible/roles/node_exporter/tasks/main.yml†L1-L34】

2. **Encapsulate UFW rule authoring.**  
   Firewall rules for node services (iperf3, node_exporter, potentially others) are scattered across roles. Extracting them into a dedicated role or task file with parameters (port, comment, CIDR) will make adding new exporters easier and ensure consistent behavior.

## Additional Suggestions

- Add molecule/CI coverage for the edge cases above (missing hub group, alternative architectures) so regressions are caught automatically.
- Where possible prefer `ansible.builtin.package` over `ansible.builtin.apt` to widen OS support; most tasks are Debian-specific but a package abstraction would reduce duplication if you later need RPM support.

