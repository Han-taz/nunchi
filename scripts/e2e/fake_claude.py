"""A fake Anthropic /v1/messages endpoint for the e2e run: "<X>의 담당자는 <Y>" becomes a fact.

The value judge's questions get fixed answers: two values are never the same decision, and any two
values of one key share a topic (every story key is one question, the owner of A사)."""

import json
import re
from http.server import BaseHTTPRequestHandler, HTTPServer

OWNER = re.compile(r"^(?P<subject>\S+?)\s*담당자는\s*(?P<name>.+)$")


def judge_reply(system: str) -> dict[str, object]:
    return {"same": "answer replacing the first" in system, "reason": "fake"}


def reply_for(user_content: str) -> dict[str, object]:
    source = user_content.split("<source>\n", 1)[1].rsplit("\n</source>", 1)[0].strip()
    match = OWNER.match(source)
    if match is None:
        return {"items": []}
    return {
        "items": [
            {
                "relation": "new",
                "relation_id": None,
                "kind": "fact",
                "title": source,
                "body": source,
                "subject_name": match["subject"],
                "attribute": "담당자",
                "value": match["name"],
                "valid_from": None,
            }
        ]
    }


class Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        content = request["messages"][0]["content"]
        reply = reply_for(content) if "<source>" in content else judge_reply(request["system"])
        body = json.dumps(
            {
                "id": "msg_fake",
                "type": "message",
                "role": "assistant",
                "model": request["model"],
                "content": [{"type": "text", "text": json.dumps(reply, ensure_ascii=False)}],
                "stop_reason": "end_turn",
                "stop_sequence": None,
                "usage": {"input_tokens": 1, "output_tokens": 1},
            }
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 9000), Handler).serve_forever()  # noqa: S104
