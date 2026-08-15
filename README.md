# rcsb-seqsearch
Helm chart repository for the RCSB PDB sequence search service.

This Helm chart creates a Kubernetes deployment for the [MMseqs2-App](https://github.com/soedinglab/MMseqs2-App), similar to what the original
[docker-compose setup](https://github.com/soedinglab/MMseqs2-App/tree/master/docker-compose) did. Note that the setup is customised for the needs of the RCSB PDB. 
 
## Architecture

### Two paths, two datasets

Everything is deployed twice, as path `a` and path `b`, each with its own copy of the
sequence data (typically one week apart). The path-operator points the main service at
one of them, switched weekly; new data is loaded into the standby path, which is then
redeployed and becomes live. FASTA files come from the `sequence-pvc` volume, under
`work-dir/sequence_files/{a,b}`, and are refreshed by an Airflow workflow that triggers
the redeployment once the data is ready.

### A pod

Each pod runs the mmseqs2-app api, a worker, and an nginx serving the UI and proxying
`/api` to the api on `127.0.0.1:3000`, plus a query-warmer that submits one search so
that users do not pay for the cold caches. Two init containers run first: one loads and
decompresses the FASTA files, the second builds the mmseqs databases and indexes, and
only exits once every non-empty database is marked COMPLETE. Building here rather than
letting the running app do it is what lets a pod start serving in ~7 minutes and
guarantees it never serves searches against half-built databases.

### State is shared within a path, never across paths

All pods of a path share one redis (job status and the pending queue) and one RWX jobs
volume (the results cache):

- any pod can answer any ticket poll or result fetch, so clients need no session
  stickiness to a pod, and any worker can pick up any queued job
- the results cache survives restarts, so a redeploy no longer starts cold

State is deliberately **not** shared between paths: mmseqs2-app derives ticket ids from
the query and the database names only, never the data version, so a common cache would
serve path `a`'s results for path `b`'s data.

The mmseqs databases and indexes stay per pod, on an ephemeral volume rebuilt at
startup.

### Health

Readiness asserts that the api advertises the database configured in
`probes.requiredDatabase` and that a ticket lookup works, which is the cheapest call
proving the api can reach its redis. A plain `/api/databases` 200 would pass with redis
down or with databases missing. The api container has no probe of its own: it listens on
127.0.0.1 only, which the kubelet cannot reach.

### Notes for operators

- **Redis image is pinned to a patch version.** With a floating tag, nodes cache
  different versions, and a redis rescheduled onto an older one cannot read the
  persisted RDB, crash-loops, and takes the whole path out of service.
- **Nothing prunes the jobs volume or redis yet.** Both used to be wiped by twice-daily
  restarts, which are gone: the rolling restart workflow is now manual only. A cleanup
  job is still to be written; it must delete the redis status key *before* the job
  directory, otherwise a cached COMPLETE points at results that no longer exist. It
  should also flush a path when that path receives new data, since results cached
  against the previous dataset would otherwise keep being served.
- **The worker CPU limit is deliberately high.** mmseqs sizes its thread count from the
  host's cores and ignores the cgroup quota, so a low limit throttles searches badly.
- Deployment is by ArgoCD, watching `master`. Changes to pod templates roll the pods on
  their own; changes to config alone are picked up through the `checksum/config`
  annotation.
