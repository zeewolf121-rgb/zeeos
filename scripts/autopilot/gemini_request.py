#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""One text-only Gemini API request. No tools, redirects, proxies or retries.

Invoked as an isolated child by team.py; the parent enforces a wall-clock and
process-output bound. Never emit provider errors, environment values or keys.
"""
import json
import os
import ssl
import sys
import urllib.error
import urllib.request

MODEL = "gemini-3.8-flash"
ENDPOINT = f"https://generativelanguage.googleapis.com/v1beta/models/{MODEL}:generateContent"
MAX_INPUT = 48000
MAX_RESPONSE = 65536
HTTP_TIMEOUT = 90


class Rejected(ValueError):
    """An incomplete, blocked, malformed or non-text answer must hold work."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # A redirect must never forward the API-key header to another endpoint.
        return None


def request_answer(prompt, key):
    payload = {
        "contents": [{"role": "user", "parts": [{"text": prompt}]}],
        "systemInstruction": {"parts": [{"text": "Return the requested JSON object only. Do not use tools."}]},
        "generationConfig": {"candidateCount": 1, "maxOutputTokens": 4096,
                             "responseMimeType": "application/json"},
        "tools": [],
    }
    request = urllib.request.Request(
        ENDPOINT, data=json.dumps(payload).encode(), method="POST",
        headers={"Content-Type": "application/json", "x-goog-api-key": key},
    )
    # No user proxy/netrc configuration, custom CA environment or SDK defaults.
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}), NoRedirect(),
        urllib.request.HTTPSHandler(context=ssl.create_default_context()),
    )
    with opener.open(request, timeout=HTTP_TIMEOUT) as response:
        raw = response.read(MAX_RESPONSE + 1)
    if len(raw) > MAX_RESPONSE:
        raise Rejected()
    envelope = json.loads(raw)
    if not isinstance(envelope, dict) or envelope.get("error") or envelope.get("promptFeedback", {}).get("blockReason"):
        raise Rejected()
    candidates = envelope.get("candidates")
    if not isinstance(candidates, list) or len(candidates) != 1:
        raise Rejected()
    candidate = candidates[0]
    if not isinstance(candidate, dict) or candidate.get("finishReason") != "STOP":
        raise Rejected()
    content = candidate.get("content", {})
    if not isinstance(content, dict) or content.get("role") != "model":
        raise Rejected()
    parts = content.get("parts")
    if not isinstance(parts, list) or not parts:
        raise Rejected()
    for part in parts:
        if (not isinstance(part, dict) or not set(part) <= {"text", "thought", "thoughtSignature"}
                or not isinstance(part.get("text"), str) or part.get("thought", False) is not False):
            raise Rejected()
    text = "".join(part["text"] for part in parts)
    if not isinstance(json.loads(text), dict):
        raise Rejected()
    return {"response": text}


def main():
    try:
        key = os.environ.get("GEMINI_API_KEY", "").strip()
        if not key:
            print("gemini_key_missing", file=sys.stderr)
            return 41
        raw = sys.stdin.buffer.read(MAX_INPUT + 1)
        if not raw or len(raw) > MAX_INPUT:
            print("gemini_input_rejected", file=sys.stderr)
            return 42
        answer = request_answer(raw.decode("utf-8"), key)
        print(json.dumps(answer))
        return 0
    except urllib.error.HTTPError as exc:
        # Do not read or log error bodies/URLs: they may contain credentials.
        code = exc.code
        exc.close()
        print(f"gemini_http_{code}" if type(code) is int and 300 <= code <= 599 else "gemini_http_error",
              file=sys.stderr)
        return 1
    except (urllib.error.URLError, TimeoutError, ssl.SSLError, OSError):
        print("gemini_network_or_tls", file=sys.stderr)
        return 1
    except Exception:
        print("gemini_response_rejected", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
