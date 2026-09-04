# List of TODO Tasks

- [x] **Validate Talos nocloud CIDATA**: Confirmed mkisofs seed ISO is read
  correctly by Talos machined on aarch64/HVF (Talos v1.13.0)
- [ ] **Iterate on BGP policies**: Experiment with route filtering
- [ ] **Add network policies**: Test Cilium network policy enforcement
- [ ] **Stress test**: Deploy resource-intensive workloads
- [ ] **Observability**: Configure Prometheus + Grafana for metrics
- [ ] **Disaster recovery**: Practice etcd backup/restore via talosctl
- [ ] **Explore Talos system extensions**: Custom images via Image Factory
- [ ] **Dual Route Reflectors**: Add second RR for HA (production alignment)
- [ ] **Talos native BGP**: Evaluate Talos 1.14's `BGPInstanceConfig` (embedded
  GoBGP) as a replacement for the FRR Route Reflector pod
- [ ] **Workload isolation**: Talos 1.14 enables `SecurityProfileConfig
  workloadIsolation` for new clusters; confirm Cilium and the hostNetwork FRR
  pod behave under it, or pin it to `false`
- [ ] **CI e2e tier**: Talos-in-Docker smoke job on `ubuntu-latest`, and a
  self-hosted Apple Silicon runner for `make test-e2e`
