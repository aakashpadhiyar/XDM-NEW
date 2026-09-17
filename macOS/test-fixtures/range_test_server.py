#!/usr/bin/env python3
"""Small local-only HTTP server used to verify XDM byte-range downloads."""

from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os
import re
import sys


class RangeHandler(SimpleHTTPRequestHandler):
    range_to_send = None

    def send_head(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path):
            return super().send_head()
        try:
            source = open(path, "rb")
        except OSError:
            self.send_error(404, "File not found")
            return None

        size = os.fstat(source.fileno()).st_size
        start, end = 0, size - 1
        requested = self.headers.get("Range")
        if requested:
            match = re.fullmatch(r"bytes=(\d*)-(\d*)", requested.strip())
            if not match:
                source.close()
                self.send_error(416, "Invalid byte range")
                return None
            start = int(match.group(1) or 0)
            end = int(match.group(2) or size - 1)
            if start >= size or end < start:
                source.close()
                self.send_error(416, "Range not satisfiable")
                return None
            end = min(end, size - 1)
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        else:
            self.send_response(200)

        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        self.range_to_send = (start, end - start + 1)
        return source

    def copyfile(self, source, outputfile):
        start, remaining = self.range_to_send or (0, None)
        source.seek(start)
        while remaining is None or remaining > 0:
            chunk = source.read(64 * 1024 if remaining is None else min(64 * 1024, remaining))
            if not chunk:
                break
            outputfile.write(chunk)
            if remaining is not None:
                remaining -= len(chunk)


if __name__ == "__main__":
    root = sys.argv[1]
    os.chdir(root)
    ThreadingHTTPServer(("127.0.0.1", 48126), RangeHandler).serve_forever()
