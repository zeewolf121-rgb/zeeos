#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline adversarial tests of the credential-bearing Gemini transport."""
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import ssl
import unittest
import urllib.error
from unittest.mock import Mock, patch

SPEC = importlib.util.spec_from_file_location("gemini_request", Path(__file__).with_name("gemini_request.py"))
api = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(api)


def envelope():
    return {"candidates": [{"finishReason": "STOP", "content": {
        "role": "model", "parts": [{"text": '{"verdict":"pass","findings":[]}'}]}}]}


class GeminiTests(unittest.TestCase):
    def opener(self, value):
        response = Mock()
        response.read.return_value = value
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        opener = Mock()
        opener.open.return_value = response
        return opener, response

    def invoke(self, data=b"Return JSON", key="test-only-key", error=None):
        stdout, stderr = io.StringIO(), io.StringIO()
        stdin = Mock(buffer=io.BytesIO(data))
        with patch.dict(os.environ, {"GEMINI_API_KEY": key}, clear=True), \
                patch.object(api.sys, "stdin", stdin), patch.object(api.sys, "stdout", stdout), \
                patch.object(api.sys, "stderr", stderr), \
                patch.object(api, "request_answer", side_effect=error, return_value={"response": "{}"}) as request:
            code = api.main()
        return code, stdout.getvalue(), stderr.getvalue(), request

    def test_one_fixed_post_has_no_tools_and_key_only_in_header(self):
        opener, response = self.opener(json.dumps(envelope()).encode())
        key = "fake-sensitive-value"
        with patch.object(api.urllib.request, "build_opener", return_value=opener) as build:
            answer = api.request_answer("Review these words", key)
        self.assertEqual(json.loads(answer["response"]), {"verdict": "pass", "findings": []})
        opener.open.assert_called_once()
        request = opener.open.call_args.args[0]
        self.assertEqual(request.full_url, api.ENDPOINT)
        self.assertTrue(request.full_url.startswith("https://generativelanguage.googleapis.com/"))
        self.assertNotIn(key, request.full_url)
        self.assertNotIn(key.encode(), request.data)
        self.assertEqual(request.get_header("X-goog-api-key"), key)
        self.assertEqual(request.get_method(), "POST")
        payload = json.loads(request.data)
        self.assertEqual(payload["tools"], [])
        self.assertEqual(payload["contents"], [{"role": "user", "parts": [{"text": "Review these words"}]}])
        self.assertEqual(payload["generationConfig"], {
            "candidateCount": 1, "maxOutputTokens": 4096, "responseMimeType": "application/json"})
        self.assertEqual(opener.open.call_args.kwargs["timeout"], 90)
        response.read.assert_called_once_with(65537)
        handlers = build.call_args.args
        self.assertEqual(handlers[0].proxies, {})
        self.assertIsInstance(handlers[1], api.NoRedirect)
        self.assertEqual(handlers[2]._context.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(handlers[2]._context.check_hostname)

    def test_redirect_never_builds_a_second_credential_bearing_request(self):
        handler = api.NoRedirect()
        request = api.urllib.request.Request(api.ENDPOINT, headers={"x-goog-api-key": "fake-key"})
        for code in (301, 302, 303, 307, 308):
            with self.subTest(code=code):
                self.assertIsNone(handler.redirect_request(request, None, code, "redirect", {}, "https://evil.invalid/"))

    def test_http_error_is_not_retried_and_body_is_never_read(self):
        body = Mock()
        failure = urllib.error.HTTPError("https://secret.invalid/fake-key", 429, "fake-key", {}, body)
        opener = Mock()
        opener.open.side_effect = failure
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.dict(os.environ, {"GEMINI_API_KEY": "fake-key"}, clear=True), \
                patch.object(api.sys, "stdin", Mock(buffer=io.BytesIO(b"prompt"))), \
                patch.object(api.sys, "stdout", stdout), patch.object(api.sys, "stderr", stderr), \
                patch.object(api.urllib.request, "build_opener", return_value=opener):
            self.assertEqual(api.main(), 1)
        opener.open.assert_called_once()
        body.read.assert_not_called()
        self.assertEqual(stdout.getvalue(), "")
        self.assertEqual(stderr.getvalue(), "gemini_http_429\n")

    def test_incomplete_blocked_tool_and_malformed_responses_hold(self):
        cases = [[], {}, {"error": {"message": "secret"}}, {"promptFeedback": {"blockReason": "SAFETY"}}]
        for reason in ("MAX_TOKENS", "SAFETY", "RECITATION", None):
            value = envelope()
            value["candidates"][0]["finishReason"] = reason
            cases.append(value)
        value = envelope()
        value["candidates"] *= 2
        cases.append(value)
        for parts in ([], [{"functionCall": {"name": "exec"}}],
                      [{"text": "{}", "inlineData": {"data": "secret"}}],
                      [{"text": "{}", "thought": True}], [{"text": "[]"}],
                      [{"text": "not json"}], [{"text": "{}", "unknown": True}]):
            value = envelope()
            value["candidates"][0]["content"]["parts"] = copy.deepcopy(parts)
            cases.append(value)
        for value in cases:
            with self.subTest(value=value):
                opener, _ = self.opener(json.dumps(value).encode())
                with patch.object(api.urllib.request, "build_opener", return_value=opener), \
                        self.assertRaises((api.Rejected, ValueError)):
                    api.request_answer("prompt", "fake-key")
                opener.open.assert_called_once()

    def test_oversized_response_is_rejected_after_bounded_read(self):
        opener, response = self.opener(b" " * 65537)
        with patch.object(api.urllib.request, "build_opener", return_value=opener), self.assertRaises(api.Rejected):
            api.request_answer("prompt", "fake-key")
        response.read.assert_called_once_with(65537)

    def test_missing_key_and_bad_input_never_contact_provider(self):
        for data, key, expected in ((b"prompt", "", 41), (b"", "fake", 42), (b"x" * 48001, "fake", 42)):
            with self.subTest(size=len(data), key=bool(key)):
                code, stdout, stderr, request = self.invoke(data, key)
                self.assertEqual(code, expected)
                self.assertEqual(stdout, "")
                self.assertIn(stderr, ("gemini_key_missing\n", "gemini_input_rejected\n"))
                request.assert_not_called()

    def test_network_and_unexpected_errors_emit_only_fixed_labels(self):
        for error, label in ((urllib.error.URLError("fake-key"), "gemini_network_or_tls"),
                             (TimeoutError("fake-key"), "gemini_network_or_tls"),
                             (ValueError("fake-key"), "gemini_response_rejected")):
            with self.subTest(kind=type(error).__name__):
                code, stdout, stderr, request = self.invoke(error=error)
                self.assertEqual((code, stdout, stderr), (1, "", label + "\n"))
                request.assert_called_once()

    def test_success_is_a_single_json_envelope(self):
        code, stdout, stderr, request = self.invoke()
        self.assertEqual((code, stderr), (0, ""))
        self.assertEqual(json.loads(stdout), {"response": "{}"})
        request.assert_called_once()


if __name__ == "__main__":
    unittest.main()
