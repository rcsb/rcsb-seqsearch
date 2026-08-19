# rcsb-seqsearch
Helm chart repository for the RCSB PDB sequence search service.

This Helm chart creates a Kubernetes deployment for the [MMseqs2-App](https://github.com/soedinglab/MMseqs2-App), similar to what the original
[docker-compose setup](https://github.com/soedinglab/MMseqs2-App/tree/master/docker-compose) did. Note that the setup is customised for the needs of the RCSB PDB.

It runs **our own fork** of the app rather than an upstream image (see `image.web_api`):
upstream keeps job results on a filesystem shared by every pod, and the fork keeps them
in redis instead. That difference is what the architecture below is about.

## What the fork changes

The app is [rcsb/MMseqs2-App](https://github.com/rcsb/MMseqs2-App), **forked from upstream
tag `v7-8e1704f`** on the `master-rcsb` branch. v7 is the last release that keeps job
status in redis and uses the nested `.params` format, both of which this chart depends
on; v8 moves status onto a shared volume and flattens the params, which is the wrong
direction for what follows.

**Job inputs and results live in redis, not on a shared filesystem**

- the server puts the whole job request, query included, in `mmseqs:job:<ticket>` and
  writes no files at all: it is not going to run the job and need not share a disk with
  whoever does
- the worker stages the job onto its own disk, runs mmseqs, renders exactly what
  `/api/result/<ticket>/<entry>` serves, stores it gzipped in `mmseqs:result:<ticket>`,
  and deletes the directory
- any pod answers any fetch, having never seen the files, so pods share no filesystem and
  adding pods adds capacity rather than contention
- `SearchJob` and `MsaJob` carry the query as an exported field, so a request fully
  describes its job and can travel through redis

**Everything in redis expires**

- a finished job's status, input and results expire together on `results.ttl`, so a
  ticket is never COMPLETE with nothing behind it
- a running job's status is refreshed by its worker and expires on `results.lease`
  otherwise. In v7 a worker killed mid-job left its ticket RUNNING for ever
- a queued ticket expires on `results.queue`, which is what gives the queue prune a clock
  that is not a filesystem

**Only `/api/result/<ticket>/<entry>` is rendered**

- `/api/result/download/...` and `/api/result/queries/...` still read files, so they work
  only on the worker that ran the job and only until it finishes. The UI depends on them
  and is not deployed
- msa jobs produce files rather than alignments, so nothing renders them and their
  directories are kept instead of being dropped silently

**Logging**

- `quietmmseqs` drops mmseqs' own output, about 200 lines per search, while keeping the
  app's. Under load that is the difference between a container log holding hours and one
  holding seconds, and the app's own lines are the ones incidents are reconstructed from
- the completion line names the job type, the ticket and how long the work took
  (`job search f8Qy... finished in 412ms`), rather than "Process finished gracefully"

**Startup**

- the server no longer submits an index job for a database that is already
  COMPLETE. The `database-builder` init container has just built them, so those
  jobs only made a worker re-verify an index and page it back in — measured at
  seven jobs and 4.3 minutes on one pod, during which it was Ready, taking
  queries, and running none of them. A search submitted into that window waited
  over a minute for a 37ms job
- it also stopped databases being marked RUNNING after startup, which is what
  used to drop them out of `/api/databases` and make readiness flap

**Fixes carried in the fork**

- two result endpoints dereferenced a nil error when a job was simply not COMPLETE,
  which expiry makes easy to hit
- `Reader.Delete` panicked on a database whose files were missing

**Build**

- built in CI to `harbor.devops.k8s.rcsb.org/rcsb/rcsb-mmseqs-app` rather than pulled from
  Docker Hub, since none of the above exists upstream
- `CGO_ENABLED=0`: the builder image is a current Debian and the mmseqs runtime image is
  Debian 10, so a cgo build passes CI and then dies at startup on `GLIBC_2.34 not found`
- the golang builder image is pinned to a minor line rather than `latest`

## Architecture

### Two paths, two datasets

Everything is deployed twice, as path `a` and path `b`, each with its own copy of the
sequence data (typically one week apart). The path-operator points the main service at
one of them, switched weekly; new data is loaded into the standby path, which is then
redeployed and becomes live. FASTA files come from the `sequence-pvc` volume, under
`work-dir/sequence_files/{a,b}`, and are refreshed by an Airflow workflow that triggers
the redeployment once the data is ready.

### A pod

Each pod runs the mmseqs2-app api and a worker, plus a query-warmer that submits one
search so that users do not pay for the cold caches. Two init containers run first: one
loads and decompresses the FASTA files, the second builds the mmseqs databases and
indexes, and only exits once every non-empty database is marked COMPLETE. Building here
rather than letting the running app do it is what lets a pod start serving in ~7 minutes
and guarantees it never serves searches against half-built databases.

There is no nginx. It used to serve the UI and proxy `/api` to the api on loopback,
stripping the prefix on the way through (`rewrite ^/api(/.*) $1`). The UI is not used —
arches only ever calls `/api/result/<ticket>/0` — so the api now binds the pod IP and
serves the `/api` prefix itself (`server.pathprefix`), and the Service targets it
directly. Two consequences worth knowing: nothing enforces an upload size limit any more
(nginx capped bodies at 100M; the api's own 128M multipart limit is all that is left),
and there is no UI to load, only the API.

### State lives in redis, per path

All pods of a path share one redis, which holds that path's job inputs, ticket statuses,
pending queue and **rendered results**:

- any pod can answer any ticket poll or result fetch, so clients need no session
  stickiness, and any worker can pick up any queued job
- pods share no filesystem at all, so adding pods adds capacity instead of adding
  contention

A worker still needs real files while a job runs, because mmseqs is a command line tool.
So it stages the job from redis onto its own disk, runs it, renders exactly what
`/api/result/<ticket>/<entry>` serves, stores that gzipped in redis, and **deletes the
directory**. The `jobs` volume is therefore an `emptyDir` holding only jobs in flight —
in production it sits at one directory of a few hundred KB per pod under full load.

This replaced an RWX cephfs volume shared by every pod of a path, which was the real
limit on the service: measured on six dev pods against the same query set, throughput
went from 331 to 874 searches/min and **per-job service time from 1.09s to 0.41s**. The
workers had not been waiting on each other, they had been waiting on the filesystem.

State is deliberately **not** shared between paths: mmseqs2-app derives ticket ids from
the query and the database names only, never the data version, so a common store would
serve path `a`'s results for path `b`'s data.

The mmseqs databases and indexes stay per pod, on an ephemeral volume rebuilt at startup.

### Expiry

`results.ttlMinutes` is the whole retention policy. A finished job's status, input and
results expire **together**, so a ticket is never COMPLETE with nothing behind it. Keep
it just long enough for a client to poll and then fetch: this is memory, and a repeat of
the same query simply runs again.

Two shorter clocks cover the other states, so a ticket expires whatever it is doing:

- `results.leaseSeconds` — a RUNNING job's status is refreshed by its worker while it
  runs. A worker killed mid-job stops being RUNNING after one lease, and the ticket
  becomes resubmittable instead of stuck for ever, which is what used to happen.
- `results.queueMinutes` — a queued ticket. It is also the clock the queue prune runs
  on: nothing records when a job was submitted, so an entry still queued with no status
  is by definition one nobody is waiting for.

### Health

Readiness and liveness are both an httpGet on `/api/databases` against the api. The api
binds the pod IP now, so the kubelet can reach it directly — which also means a wedged
api finally gets **restarted**, where the old probe on nginx could only take the pod out
of the service.

The probe does not assert that a particular database is advertised, as the old exec
probe did: httpGet cannot look at the response body, and it no longer needs to. The
database-builder init container blocks until every non-empty database is COMPLETE, and
the fork does not re-submit index jobs for databases that are already built, so nothing
marks one RUNNING after startup. That re-indexing is what used to make pods flap here,
each database dropping out of `/api/databases` for about a minute while it was
re-verified.

### Cleanup

A CronJob per path prunes abandoned **queue entries**, every 10 minutes. Clients give up
after ~30s, so a job still waiting to start minutes later will never be collected. Left
alone these accumulate until the queue is deeper than the client timeout allows, at which
point every query fails even though the workers are keeping up — the queue is what takes
the service down.

It finds them by set difference: an entry in `mmseqs:pending` whose status key has
already expired. No filesystem is involved, and none is available to it.

Nothing else needs pruning. Results expire in redis on their TTL, and job directories are
deleted by the worker that created them.

### Notes for operators

- **Redis holds the results now, not just a few status strings.** It is sized with
  `maxmemory` below the container memory limit and `maxmemory-policy volatile-lru`, so
  that it evicts rather than being OOM killed. `volatile-lru` and never `allkeys-lru`:
  only finished jobs carry a TTL, so eviction can drop results that were expiring anyway
  but never the pending queue or a job still queued or running. An evicted result behaves
  exactly like an expired one. Under real production load a path sits at 40-80MB against
  a 700MB cap.
- **Redis image is pinned to a patch version.** With a floating tag, nodes cache
  different versions, and a redis rescheduled onto an older one cannot read the persisted
  RDB, crash-loops, and takes the whole path out of service.
- **Upgrading a path from stock v7 leaves dead tickets behind.** v7 wrote
  `mmseqs:status:*` with no expiry, and those keys survive in the persisted RDB. They
  report COMPLETE with no result behind them for ever, so a repeat of any query run
  shortly before the upgrade fails. Every key this fork writes has a TTL in every state,
  so `TTL = -1` identifies them exactly:
  `redis-cli --scan --pattern 'mmseqs:status:*' | while read k; do [ "$(redis-cli ttl "$k")" = "-1" ] && redis-cli del "$k"; done`
- **Searches pass `--threads` explicitly** (in each database's `.params`). Without it
  mmseqs sizes its thread count from the node's core count and ignores the cgroup quota,
  spawning tens of surplus threads per job. The worker CPU limit is a budget for
  `threads x concurrently running jobs`; a worker runs one job at a time today, so most
  of it sits idle.
- **Capacity is sized against the queue, not CPU.** A search uses about one core, so CPU
  utilisation never approaches anything an HPA would trigger on; queue depth is the
  signal. If demand exceeds total drain for long enough the queue passes the client
  timeout and everything fails at once, so `replicaCount` needs margin to absorb losing a
  worker. To recover from a backlog, flush the queue rather than waiting for it to drain
  — everything in it is already older than any client will wait for.
- **The rolling restart workflow is manual only.**
- **The image tag `production` moves**, so the pull policy is `Always`; under
  `IfNotPresent` nodes keep serving whatever they cached first and pods quietly run
  different builds. Note that `helm upgrade` alone will not pick up a new build when the
  tag has not changed — use `kubectl rollout restart`.
- Deployment is by ArgoCD, watching `master`. Changes to pod templates roll the pods on
  their own; changes to config alone are picked up through the `checksum/config`
  annotation.
