"""A stand-in for DAB and the mesh in front of it, for ci/tests/run-access-smoke-tests.sh. Test use only; binds 127.0.0.1.

    python3 -I fake-dab.py <portfile> <mode> <dab-entities.ops.json> <ops-columns.json>

It writes the port it bound to <portfile>, then serves until killed. Modes:
  dab           REST as DAB answers it: GET /api/<Entity> as the contract's role -> 200 with exactly the entity's
                fields.include; a $select or $filter naming any other column -> 400 (JSON); another role, or no role
                header ("authenticated") -> 403 (JSON); an unknown entity -> 404. /graphql -> 200.
  leak          as dab, but every row carries one field outside fields.include.
  canary        as dab, but one value is the CANARY fixture marker.
  select-open   as dab, but a $select of a column outside fields.include is answered 200.
  mesh-select   as dab, but a $select of a column outside fields.include is refused by the mesh, not by DAB.
  role-open     as dab, but another role is answered 200.
  mesh-closed   the prod mesh: /api and /graphql -> Envoy's 403 "RBAC: access denied" for every caller; /mcp -> 200.
  unauthorized  every request -> 401.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit

PORTFILE, MODE, ENTS, SPEC = sys.argv[1:5]
ENTITIES = json.load(open(ENTS, encoding="utf-8"))["entities"]
ROLE = json.load(open(SPEC, encoding="utf-8"))["role"]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # keep the test output clean
        pass

    def send(self, code, body, ctype="application/json"):
        data = body.encode("utf-8") if isinstance(body, str) else json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def mesh_refuse(self):
        self.send(403, "RBAC: access denied", "text/plain")

    def do_GET(self):
        url = urlsplit(self.path)
        path = url.path
        if MODE == "unauthorized":
            return self.send(401, {"error": {"code": "AuthenticationChallenge"}})
        if MODE == "mesh-closed":
            if path.startswith("/api") or path.startswith("/graphql"):
                return self.mesh_refuse()
            return self.send(200, {"ok": True})
        if path.startswith("/graphql"):
            return self.send(200, {"data": None})
        if not path.startswith("/api/") or path.rstrip("/") == "/api":
            return self.send(404, {"error": {"code": "EntityNotFound"}})
        name = path[len("/api/"):].strip("/")
        ent = ENTITIES.get(name)
        if ent is None:
            return self.send(404, {"error": {"code": "EntityNotFound"}})
        role = self.headers.get("X-MS-API-ROLE") or "authenticated"
        if role != ROLE and MODE != "role-open":
            return self.send(403, {"error": {"code": "AuthorizationCheckFailed", "message": "Authorization Failure: Access Not Allowed."}})
        include = ent["permissions"][0]["actions"][0]["fields"]["include"]
        qs = parse_qs(url.query, keep_blank_values=True)
        sel = qs.get("$select", [None])[0]
        flt = qs.get("$filter", [None])[0]
        named = []
        if sel:
            named += [c.strip() for c in sel.split(",")]
        if flt:
            named.append(unquote(flt).split(" ")[0])
        outside = [c for c in named if c not in include]
        if outside:
            if sel and outside[0] in [c.strip() for c in sel.split(",")]:
                if MODE == "select-open":
                    return self.send(200, {"value": [{outside[0]: "x"}]})
                if MODE == "mesh-select":
                    return self.mesh_refuse()
            return self.send(400, {"error": {"code": "BadRequest", "message": f"Invalid field: {outside[0]}"}})
        row = {c: 1 for c in include}
        if MODE == "leak":
            row["Email"] = "someone@example.com"
        if MODE == "canary":
            row[include[-1]] = "CANARY"
        return self.send(200, {"value": [row]})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORTFILE, "w", encoding="utf-8") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
