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
  `replicas`, which paces the loop to about one step per minute. Measured on the devstack: a
  second executor about 60 s after the demand appears, a third after about 160 s, back to one
  about 100 s after the demand is gone.

Conventions:

- `*.cr.yaml`: the custom resource an RFS deploys (`_CR_SPEC`), with `@TOKEN@` placeholders that
  the applying script fills (cluster, location, image).
- `*.rule.java`: the body of an LCM rule's `exec()`; OpenSlice wraps it in a class that extends
  `LcmBaseExecutor`, so only its helper methods and `java.lang` are available unqualified.
- Specs are created through `scripts/osl.sh` helpers, never by hand in a portal, so that every
  OpenSlice they are applied to gets the same objects.
