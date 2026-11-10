"""Exercise the API 14-compatible Emby client against a real local HTTP server."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import subprocess
import tempfile
import threading
from urllib.parse import urlsplit, parse_qs

root = Path(__file__).resolve().parents[2]
jdk = Path(os.environ.get("MARCOMOVIE_JDK") or os.environ["JAVA_HOME"]) / "bin"
jar = root / "android/tests/lib/json-20240303.jar"
errors = []
events = []

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/media/emby/Users/AuthenticateByName":
            if body.get("Pw") != "fixture-password":
                errors.append("authentication body")
            self.reply({"AccessToken": "fixture-token", "User": {"Id": "u1"}})
            return
        if self.headers.get("X-Emby-Token") != "fixture-token":
            errors.append("missing POST authorization")
        if self.path == "/media/emby/Items/e1/PlaybackInfo":
            source = body.get("MediaSourceId", "m1")
            if body.get("UserId") != "u1" or not body.get("DeviceProfile"):
                errors.append("missing playback profile")
            if source == "denied":
                self.reply({"ErrorCode": "NotAllowed"})
                return
            media = {"Id": source, "SupportsDirectStream": source == "m1",
                     "SupportsTranscoding": True,
                     "TranscodingUrl": "Videos/e1/master.m3u8?api_key=obsolete&VideoCodec=h264"}
            if source == "foreign":
                media["TranscodingUrl"] = "https://elsewhere.example/Videos/e1/master.m3u8"
            if source == "missing":
                media["Id"] = "unrequested-version"
            if source == "opening":
                media["RequiresOpening"] = True
            self.reply({"PlaySessionId": "session-" + source, "MediaSources": [media]})
        elif self.path.startswith("/media/emby/Sessions/Playing"):
            events.append((self.path, body))
            self.send_response(204)
            self.end_headers()
        else:
            errors.append("unexpected POST path")
            self.send_response(404)
            self.end_headers()

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/test-events":
            self.reply(events)
            return
        if self.headers.get("X-Emby-Token") != "fixture-token":
            errors.append("missing authorization")
        if path.endswith("/Views"):
            self.reply({"Items": [{"Id": "v1", "Name": "Library"}]})
        elif path.endswith("/Items"):
            query = parse_qs(urlsplit(self.path).query)
            if query.get("StartIndex") != ["40"] or query.get("SearchTerm") != ["movie"]:
                errors.append("search pagination")
            self.reply({"Items": [{"Id": "s1", "Name": "Series"}], "TotalRecordCount": 45})
        elif path.endswith("/Items/s1"):
            self.reply({"Id": "s1", "Name": "Series", "Type": "Series"})
        elif path.endswith("/Episodes"):
            self.reply({"Items": [{"Id": "e1", "Name": "Episode", "ParentIndexNumber": 1,
                                  "IndexNumber": 1, "MediaSources": [{"Id": "m1"}]}], "TotalRecordCount": 1})
        else:
            errors.append("unexpected path")
            self.reply({})

    def reply(self, body):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory() as output:
        subprocess.run([jdk/"javac", "-encoding", "UTF-8", "-cp", jar, "-d", output,
                        root/"shared/java/com/pilipala/emby/EmbyLibrary.java",
                        root/"android/tests/EmbyChecks.java"], check=True)
        subprocess.run([jdk/"java", "-cp", output+os.pathsep+str(jar), "EmbyChecks",
                        f"http://127.0.0.1:{server.server_port}/media"], check=True)
    if errors:
        raise AssertionError(errors)
    paths = [p.rsplit("/", 1)[-1] for p, _ in events]
    if paths[:3] != ["Playing", "Progress", "Stopped"]:
        raise AssertionError("check-in ordering: " + str(paths))
    if events[1][1]["PositionTicks"] != 125000000 or not events[1][1]["IsPaused"]:
        raise AssertionError("paused progress ticks")
    if not any(b["PlaySessionId"] == "session-transcode" and p.endswith("/Stopped") for p, b in events):
        raise AssertionError("coalesced reporter did not finish")
finally:
    server.shutdown()
