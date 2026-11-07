// E1: write the bundle's "replicas" characteristic into the part's _CR_SPEC.
// Attached to the bundle (CFSS) twice: PRE_PROVISION (before the part is created) and
// SUPERVISION (whenever a characteristic of the running bundle changes). Same code both times.
int replicas = 1;
int max = 3;
try { replicas = Integer.parseInt(getCharValFromStringType("replicas").trim()); } catch (Exception e) { }
try { max = Integer.parseInt(getCharValFromStringType("maxReplicas").trim()); } catch (Exception e) { }
if (replicas > max) { replicas = max; }
if (replicas < 0) { replicas = 0; }
String cr = "apiVersion: colony.colonyos.io/v1\n"
  + "kind: Blueprint\n"
  + "metadata:\n"
  + "  name: echo\n"
  + "spec:\n"
  + "  kind: ExecutorDeployment\n"
  + "  locationName: @LOCATION@\n"
  + "  data:\n"
  + "    executorType: @TYPE@\n"
  + "    image: @IMAGE@\n"
  + "    replicas: " + replicas + "\n";
java.util.HashMap<String, String> vals = new java.util.HashMap<String, String>();
vals.put("_CR_SPEC", cr);
setServiceRefCharacteristicsValues("@RFSNAME@", vals);
