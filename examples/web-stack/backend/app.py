"""Minimal demo backend for the drydock web-stack example.

Two endpoints over stdlib http.server:
  GET /health   -> {"ok": true}
  GET /db       -> {"version": "<SELECT version() result>"}

Reads postgres credentials from POSTGRES_{DB,USER,PASSWORD,HOST} env vars.
"""
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

import psycopg2


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self._json(200, {"ok": True})
        elif self.path == "/db":
            try:
                conn = psycopg2.connect(
                    host=os.environ["POSTGRES_HOST"],
                    dbname=os.environ["POSTGRES_DB"],
                    user=os.environ["POSTGRES_USER"],
                    password=os.environ["POSTGRES_PASSWORD"],
                )
                with conn, conn.cursor() as cur:
                    cur.execute("SELECT version()")
                    version = cur.fetchone()[0]
                self._json(200, {"version": version})
            except Exception as exc:
                self._json(500, {"error": str(exc)})
        else:
            self._json(404, {"error": "not found"})

    def _json(self, code, body):
        payload = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 18080), Handler).serve_forever()
