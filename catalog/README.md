# Catalogue as code

Example catalogue entries: service specifications, LCM rules and characteristics kept as files
and applied by script, with tests that order them against the devstack's OpenSlice. Use them as
patterns for your own entries. One directory per entry.

- `scaling-policy/`: a bundle with a policy characteristic (`replicas`, capped by `maxReplicas`)
  that LCM rules write into the part's ExecutorDeployment Blueprint, at creation (PRE_PROVISION)
  and on every later change (SUPERVISION). `scripts/test-scaling-policy.sh` creates it, orders it
  and checks the day-2 behaviour of OpenSlice 2025Q4: a PATCH of the characteristic in the
  service inventory scales the executors within a minute; a modify order does not change a
  bundle's own characteristics; a modify order can set a part's `_CR_SPEC` through
  `<part name>::_CR_SPEC`, but only when no SUPERVISION rule owns `_CR_SPEC`, because the rule
  rewrites it before the patch is sent. So each characteristic has one writer: the rule for
  policy, the inventory PATCH for the people and programs that change the policy.
  `scale-on-queue.rule.java` (SUPERVISION) closes the loop: when `queueWaiting`, written by a
  reporter with a USER account from the colony's waiting processes, reaches `scaleUpQueue`, it
  raises `replicas` by one step up to `maxReplicas`, and lowers it when the queue is empty; a
  step is taken only once the part's `status.currentData.runningInstances` has caught up with
  `replicas`, which paces the loop to about one step per minute. `scripts/test-scale-on-queue.sh`
  orders the bundle, runs such a reporter, queues processes that no executor serves and checks
  the loop up to the cap and back down, and that the rule never steps ahead of the executors.
  Measured on the devstack: a second executor 45–60 s after the demand appears, a third after
  about 160 s, back to one 40–80 s after the demand is gone.

  Tier 2, through the platform: `burst-on-cap.rule.java` (SUPERVISION on the same bundle) places a
  service order for a second bundle when the cap is reached, the part reports the cap running and
  the queue still reaches `scaleUpQueue`; the second bundle's specification id is the
  characteristic `burstSpec`, its service name `burstName`, and the order id is kept in
  `burstOrder` so that one peak orders one burst. `burst-release.rule.java` (SUPERVISION on the
  burst bundle) orders the termination of that bundle and its part when the queue is empty: a
  `delete` order item whose `supportingService` lists them, which is what OSOM terminates. Rules
  place orders with `createServiceOrder`, whose items are created acknowledged, so no one has to
  approve them; the orders name the rule and the order they descend from. The burst bundle's
  Blueprint names another location, served by a second reconciler (`make reconciler
  LOCATION=cloud`). `scripts/test-burst-capacity.sh` orders both bundles' loop and checks the
  burst order, the executors at the second location, the release and the way back. Measured on
  the devstack: burst executors running about two minutes after tier 1 reached its cap, burst
  gone about one minute after the queue emptied. A Blueprint whose
  location no reconciler serves is accepted by every layer and never runs; check the location
  against `colonies executor ls` before ordering.

Categories are part of the catalogue too, but no category entries are kept here yet;
`scripts/osl.sh` has the primitives to apply them: `osl_category`, `osl_catalog_add_category`,
`osl_category_add_spec` (through the spec's candidate; a spec can be in several categories),
`osl_spec_lifecycle`, and `osl_category_delete` (OpenSlice refuses to delete a category that is
still in a catalogue or still holds candidates, and a spec whose candidate is still in a category).
Categories organise the catalogue for people using this OpenSlice's portal; HypO does not use
them (it files peered specifications in categories of its own). HypO's peering reads the whole
specification list, of every type and lifecycle status, and then fetches each specification it
keeps by id; the catalogue and category URLs given at peering are stored but not used, and the
filtering by type and name is done by the peering pipeline. The list carries name, version, type
and the bundle flag only, so lifecycle status and characteristics reach the peer from the fetch
by id. `make peering-check` reads both URLs.

Conventions:

- `*.cr.yaml`: the custom resource an RFS deploys (`_CR_SPEC`), with `@TOKEN@` placeholders that
  the applying script fills (cluster, location, image).
- Status mapping: a part's `_CR_CHECK_FIELD` names the CR status field that decides the
  service's state, and `_CR_CHECKVAL_AVAILABLE` the value that makes it available (CRIDGE
  compares the strings exactly; any other value is unknown). For an ExecutorDeployment use
  `status.currentData.runningInstances` with the replicas it should run, not `status.synced`:
  the Blueprint is synced as soon as ColonyOS has accepted it, also for a location whose
  reconciler is down, and the service would be active with nothing running. With the running
  count the service becomes active, and the order completes, when the executors run; a service
  that is active stays active whatever the count does later. `cr-spec-from-replicas.rule.java`
  keeps the check value equal to the replicas it writes. Measured on the devstack: with the
  reconciler of the Blueprint's location stopped, the order stays INPROGRESS and the services
  reserved; the part is active 61 s after the reconciler returns.
- `*.rule.java`: the body of an LCM rule's `exec()`; OpenSlice wraps it in a class that extends
  `LcmBaseExecutor`, so only its helper methods and `java.lang` are available unqualified.
- Specs are created through `scripts/osl.sh` helpers, never by hand in a portal, so that every
  OpenSlice they are applied to gets the same objects.
