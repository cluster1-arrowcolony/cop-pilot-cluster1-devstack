// SUPERVISION rule on the bundle: tier 1 of the scaling loop. Reads the demand characteristic
// queueWaiting (written by a reporter), the policy replicas and maxReplicas, the threshold
// scaleUpQueue, and the part's running executors (status.currentData.runningInstances, which
// CRIDGE copies from the Blueprint status once a minute). One step per evaluation, and only when
// the previous step has landed (running >= replicas), so the once-a-minute evaluations and the
// reporter's PATCHes cannot run ahead of the executors. Writing replicas here makes OSOM
// evaluate the bundle again, and the cr-spec rule then puts the new value into the part's
// _CR_SPEC; that rule stays the only writer of _CR_SPEC.
int queue = 0; int replicas = 1; int max = 3; int up = 10; int running = -1;
try { queue = Integer.parseInt(getCharValFromStringType("queueWaiting").trim()); } catch (Exception e) { }
try { replicas = Integer.parseInt(getCharValFromStringType("replicas").trim()); } catch (Exception e) { }
try { max = Integer.parseInt(getCharValFromStringType("maxReplicas").trim()); } catch (Exception e) { }
try { up = Integer.parseInt(getCharValFromStringType("scaleUpQueue").trim()); } catch (Exception e) { }
try { running = Integer.parseInt(getServiceRefPropValue("@RFSNAME@", "serviceCharacteristicValue", "status.currentData.runningInstances").trim()); } catch (Exception e) { }
int target = replicas;
if (running >= replicas) {
	if (queue >= up && replicas < max) { target = replicas + 1; }
	else if (queue == 0 && replicas > 1) { target = replicas - 1; }
}
if (target != replicas) {
	setCharValFromStringType("replicas", "" + target);
	logtext("scale-on-queue: queueWaiting=" + queue + " running=" + running + " replicas " + replicas + " -> " + target);
}
