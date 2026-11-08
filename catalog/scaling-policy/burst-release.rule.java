// SUPERVISION rule on the burst bundle: when the demand it was ordered for is gone (queueWaiting
// 0, written by the same reporter as for the main bundle), place a service order that terminates
// this bundle and its part. OSOM's delete action terminates the services listed as the item's
// supportingService, so the bundle lists itself and its part there. "released" keeps the rule
// from ordering twice while the termination runs.
int queue = -1;
try { queue = Integer.parseInt(getCharValFromStringType("queueWaiting").trim()); } catch (Exception e) { }
String released = "";
try { released = getCharValFromStringType("released").trim(); } catch (Exception e) { }
String state = "";
try { state = getCurrentServicePropValue("state"); } catch (Exception e) { }
if (queue == 0 && released.isEmpty() && "ACTIVE".equals(state)) {
	String self = getCurrentServicePropValue("serviceObjectasJSON");
	String selfId = getJsonValueAsStringFromField(self, "id");
	String selfName = getJsonValueAsStringFromField(self, "name");
	String specId = getCurrentServicePropValue("serviceSpecificationID");
	String part = getServiceRefPropValue("@RFSNAME@", "serviceObjectasJSON");
	String partId = "";
	try { partId = getJsonValueAsStringFromField(part, "id"); } catch (Exception e) { }
	String supporting = "{\"id\":\"" + selfId + "\"}";
	if (partId != null && !partId.isEmpty()) { supporting = supporting + ",{\"id\":\"" + partId + "\"}"; }
	String json = "{\"description\":\"Burst capacity released by the scaling policy\",\"orderItem\":[{\"id\":\"1\",\"action\":\"delete\","
		+ "\"service\":{\"id\":\"" + selfId + "\",\"name\":\"" + selfName + "\",\"serviceSpecification\":{\"id\":\"" + specId + "\"},"
		+ "\"supportingService\":[" + supporting + "]}}]}";
	String created = createServiceOrder(json);
	String oid = "";
	try { oid = getJsonValueAsStringFromField(created, "id"); } catch (Exception e) { }
	if (oid == null || oid.isEmpty()) { oid = "failed"; }
	setCharValFromStringType("released", oid);
	logtext("burst-release: queue empty, termination order " + oid + " for " + selfId + " and part " + partId);
}
