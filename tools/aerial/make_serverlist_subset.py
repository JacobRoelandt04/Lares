#!/usr/bin/env python3
"""A small committed subset of Proton's serverlist.json with the REAL schema (the helper's catalog digest is tested on it).

  python3 -I tools/aerial/make_serverlist_subset.py [<serverlist.json>]

3 exit countries (NL, BE, IS), ~20 logical servers: a few plain ones per city, the Secure Core ones that exit there, one Tor, one
P2P, one Tier-3 server (the digest must leave it out: top-level MaxTier is 2). Entry / exit IPs become documentation addresses
(192.0.2.x), keys and IDs placeholders: nothing in the subset reaches a real server.
"""
import json, os, sys, copy
SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.cache/Proton/VPN/serverlist.json")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "modules", "aerial", "data", "fixtures", "serverlist_subset.json")
d = json.load(open(SRC))
want = {"NL": 7, "BE": 5, "IS": 4}
picked, per_city = [], {}
for s in d["LogicalServers"]:
    cc = s["ExitCountry"]
    if cc not in want or s["Tier"] > d["MaxTier"]:
        continue
    key = (cc, s["City"], bool(s["Features"] & 1), s["Features"] & 6)
    if per_city.get(key, 0) >= (2 if s["Features"] & 1 else 3):
        continue
    if sum(1 for p in picked if p["ExitCountry"] == cc) >= want[cc]:
        continue
    per_city[key] = per_city.get(key, 0) + 1
    picked.append(copy.deepcopy(s))
# a second Dutch city, so the country centroid is a mean of two (the real list has several)
for s_ in picked:
    if s_["Name"] == "NL#87":
        s_["City"], s_["Location"] = "Rotterdam", {"Lat": 51.92, "Long": 4.48}
tier3 = copy.deepcopy(picked[0])
tier3["Name"], tier3["Tier"] = "NL#999", 3
picked.append(tier3)
for i, s in enumerate(picked):
    s["ID"] = "fake-id-%d==" % i
    for j, n in enumerate(s["Servers"]):
        n.update(EntryIP="192.0.2.%d" % (10 + i), ExitIP="192.0.2.%d" % (10 + i), X25519PublicKey="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                 ID="fake-node-%d-%d==" % (i, j))
out = {"Code": 1000, "MaxTier": d["MaxTier"], "LastModifiedTime": 0, "ExpirationTime": 0, "LoadsExpirationTime": 0,
       "ResponseMetadata": {}, "LogicalServers": picked}
json.dump(out, open(OUT, "w"), indent=1)
print(len(picked), "servers")
