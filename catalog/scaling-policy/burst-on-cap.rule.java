// SUPERVISION rule on the bundle: tier 2 of the scaling loop, through the platform. When the
// in-domain tier is at its cap (replicas == maxReplicas and the part reports them running) and
// the demand (queueWaiting) still reaches scaleUpQueue, place a service order for the burst
// bundle whose specification id is in burstSpec; the order's id is kept in burstOrder so that
// only one burst is ordered. The burst bundle releases itself when the queue is empty (see
// burst-release.rule.java); burstOrder is cleared here at the same condition, so the next peak
// can order again. createServiceOrder creates the item ACKNOWLEDGED, so OSOM runs it at once.
int queue = 0; int replicas = 1; int max = 3; int up = 10; int running = -1;
try { queue = Integer.parseInt(getCharValFromStringType("queueWaiting").trim()); } catch (Exception e) { }
try { replicas = Integer.parseInt(getCharValFromStringType("replicas").trim()); } catch (Exception e) { }
try { max = Integer.parseInt(getCharValFromStringType("maxReplicas").trim()); } catch (Exception e) { }
try { up = Integer.parseInt(getCharValFromStringType("scaleUpQueue").trim()); } catch (Exception e) { }
try { running = Integer.parseInt(getServiceRefPropValue("@RFSNAME@", "serviceCharacteristicValue", "status.currentData.runningInstances").trim()); } catch (Exception e) { }
String burstSpec = ""; String burstName = ""; String burstOrder = "";
try { burstSpec = getCharValFromStringType("burstSpec").trim(); } catch (Exception e) { }
try { burstName = getCharValFromStringType("burstName").trim(); } catch (Exception e) { }
try { burstOrder = getCharValFromStringType("burstOrder").trim(); } catch (Exception e) { }
if (burstOrder.isEmpty() && !burstSpec.isEmpty() && queue >= up && replicas >= max && running >= max) {
	String json = "{\"description\":\"Burst capacity ordered by the scaling policy\",\"orderItem\":[{\"id\":\"1\",\"action\":\"add\","
		+ "\"service\":{\"name\":\"" + burstName + "\",\"serviceSpecification\":{\"id\":\"" + burstSpec + "\"},"
		+ "\"serviceCharacteristic\":[{\"name\":\"queueWaiting\",\"value\":{\"value\":\"" + queue + "\",\"alias\":\"\"},\"valueType\":\"TEXT\"}]}}]}";
	String created = createServiceOrder(json);
	String oid = "";
	try { oid = getJsonValueAsStringFromField(created, "id"); } catch (Exception e) { }
	if (oid == null || oid.isEmpty()) { oid = "failed"; }
	setCharValFromStringType("burstOrder", oid);
	logtext("burst-on-cap: queueWaiting=" + queue + " at cap " + max + " running=" + running + " -> ordered burst " + oid);
} else if (!burstOrder.isEmpty() && queue == 0) {
	setCharValFromStringType("burstOrder", "");
	logtext("burst-on-cap: queue empty, burst " + burstOrder + " released");
}
