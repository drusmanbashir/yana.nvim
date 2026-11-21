"""Run-copy text and file actions over the private Unix-socket bridge."""

import asyncio
import inspect
import json
import socket
from typing import Any

from mcpyana.read_tools import SCHEMAS as READ_SCHEMAS, TOOLS as READ_TOOLS, ReadTools


PROTOCOL_VERSION = "2025-11-25"
TOOLS = [
    {
        "name": "open_buffer",
        "description": "Open or obtain a named Neovim buffer and return its current text.",
        "inputSchema": {
            "type": "object",
            "properties": {"name": {"type": "string"}},
            "required": ["name"],
            "additionalProperties": False,
        },
    },
    {
        "name": "edit_buffer",
        "description": "Set the complete text of an opened buffer for a new file or whole rewrite. "
                       "Prefer replace_text when changing existing text.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "buffer_ref": {"type": "string"},
                "after_text": {"type": "string"},
            },
            "required": ["buffer_ref", "after_text"],
            "additionalProperties": False,
        },
    },
    {
        "name": "replace_text",
        "description": "Prefer this tool when changing existing text. Replace exact text in the named file's Run copy. "
                       "Each old_text must occur exactly once after earlier edits in this call. "
                       "If any edit fails, none apply. Returns only the file name and whether the text changed.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "minLength": 1},
                "edits": {
                    "type": "array",
                    "minItems": 1,
                    "items": {
                        "type": "object",
                        "properties": {
                            "old_text": {"type": "string", "minLength": 1},
                            "new_text": {"type": "string"},
                        },
                        "required": ["old_text", "new_text"],
                        "additionalProperties": False,
                    },
                },
            },
            "required": ["name", "edits"],
            "additionalProperties": False,
        },
    },
    {
        "name": "delete_file",
        "description": "Propose deleting a file at End; change only the Run copy.",
        "inputSchema": {"type": "object", "properties": {"name": {"type": "string"}},
                        "required": ["name"], "additionalProperties": False},
    },
    {
        "name": "rename_file",
        "description": "Propose renaming a file. Not available yet: the host refuses it until linked rename review is built.",
        "inputSchema": {"type": "object", "properties": {"from": {"type": "string"}, "to": {"type": "string"}},
                        "required": ["from", "to"], "additionalProperties": False},
    },
] + READ_TOOLS


class HostFailure(Exception):
    def __init__(self, error: dict[str, Any]):
        self.error = error
        super().__init__(str(error))


class SocketHost:
    """Use one host-owned socket for the fixed buffer operations."""

    def __init__(self, address: str):
        self.connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self.connection.connect(address)
        except OSError:
            self.connection.close()
            raise
        self.reader = self.connection.makefile("r", encoding="utf-8", newline="\n")
        self.writer = self.connection.makefile("w", encoding="utf-8", newline="\n")
        self.request_id = 0

    async def open_buffer(self, args: dict[str, Any]) -> dict[str, Any]:
        return await self._call("open_buffer", args)

    async def edit_buffer(self, args: dict[str, Any]) -> dict[str, Any]:
        return await self._call("edit_buffer", args)

    async def replace_text(self, args: dict[str, Any]) -> dict[str, Any]:  #AI
        """Forward the ordered edits to the Run's socket."""
        return await self._call("replace_text", args)

    async def delete_file(self, args: dict[str, Any]) -> dict[str, Any]:  #AI
        return await self._call("delete_file", args)

    async def rename_file(self, args: dict[str, Any]) -> dict[str, Any]:  #AI
        return await self._call("rename_file", args)

    async def copies(self, args: dict[str, Any]) -> dict[str, str | None]:  #AI
        """Retrieve existing Run text and deletion markers under one path."""
        return await self._call("copies", args)

    async def _call(self, operation: str, arguments: dict[str, Any]) -> dict[str, Any]:
        self.request_id += 1
        return await asyncio.to_thread(self._exchange, self.request_id, operation, arguments)

    def _exchange(self, request_id: int, operation: str, arguments: dict[str, Any]) -> dict[str, Any]:
        try:
            self.writer.write(json.dumps({"id": request_id, "operation": operation, "arguments": arguments}) + "\n")
            self.writer.flush()
            reply = json.loads(self.reader.readline())
        except (OSError, json.JSONDecodeError) as exc:
            raise HostFailure({"code": "host_disconnected", "message": str(exc) or "host closed the connection"}) from exc
        if not isinstance(reply, dict) or set(reply) not in ({"id", "result"}, {"id", "error"}):
            raise HostFailure({"code": "invalid_host_reply", "message": "host reply shape is invalid"})
        if type(reply["id"]) is not int or reply["id"] != request_id:
            raise HostFailure({"code": "correlation_error", "message": "host reply id did not match request"})
        if "error" in reply:
            if not isinstance(reply["error"], dict):
                raise HostFailure({"code": "invalid_host_reply", "message": "host error is not an object"})
            raise HostFailure(reply["error"])
        return reply["result"]

    def close(self) -> None:
        self.reader.close()
        self.writer.close()
        self.connection.close()


class McpServer:
    def __init__(self, host, mode="inline"):
        self.host = host
        self.reads = ReadTools(host)
        self.tools = READ_TOOLS if mode == "ask" else TOOLS

    async def handle_line(self, line: str) -> dict[str, Any] | None:
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            return self._error(None, -32700, "Parse error")
        if not isinstance(request, dict):
            return self._error(None, -32600, "Invalid request")

        raw_id = request["id"] if "id" in request else None
        request_id = raw_id if raw_id is None or type(raw_id) in (int, str) else None
        params = request["params"] if "params" in request else {}
        jsonrpc = request["jsonrpc"] if "jsonrpc" in request else None
        method = request["method"] if "method" in request else None
        if jsonrpc != "2.0" or type(method) is not str or not isinstance(params, dict):
            return self._error(request_id, -32600, "Invalid request")
        if request_id is None:
            return None
        if method == "initialize":
            client_version = params["protocolVersion"] if "protocolVersion" in params else None
            if (
                type(client_version) is not str
                or not isinstance(params["capabilities"] if "capabilities" in params else None, dict)
                or not isinstance(params["clientInfo"] if "clientInfo" in params else None, dict)
            ):
                return self._error(request_id, -32602, "Invalid params")
            return self._response(
                request_id,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": {"name": "mcpyana", "version": "0.0.1"},
                },
            )
        if method == "tools/list":
            return self._response(request_id, {"tools": self.tools})
        if method == "tools/call":
            return await self._call_tool(request_id, params)
        if method == "notifications/initialized":
            return None
        return self._error(request_id, -32601, "Method not found")

    async def _call_tool(self, request_id: int | str, params: dict[str, Any]) -> dict[str, Any]:
        if (
            not {"name", "arguments"}.issubset(params)
            or set(params) - {"name", "arguments", "_meta"}
            or type(params["name"]) is not str
            or not isinstance(params["arguments"], dict)
        ):
            return self._error(request_id, -32602, "Invalid params")
        name = params["name"]
        if name not in {tool["name"] for tool in self.tools}:
            return self._error(request_id, -32602, "Unknown tool")
        if name in READ_SCHEMAS:
            try:
                content = await self.reads.call(name, params["arguments"])
            except (HostFailure, OSError, ValueError) as exc:
                return self._response(request_id, {"content": [{"type": "text", "text": str(exc)}], "isError": True})
            return self._response(request_id, {"content": content, "isError": False})
        try:
            payload = getattr(self.host, name)(params["arguments"])
            if inspect.isawaitable(payload):
                payload = await payload
        except HostFailure as exc:
            return self._tool_error(request_id, exc.error)
        except Exception as exc:
            return self._tool_error(request_id, {"code": "host_error", "message": str(exc)})
        return self._response(
            request_id,
            {"content": [{"type": "text", "text": json.dumps(payload)}], "isError": False},
        )

    @staticmethod
    def _response(request_id: int | str, result: dict[str, Any]) -> dict[str, Any]:
        return {"jsonrpc": "2.0", "id": request_id, "result": result}

    @staticmethod
    def _error(request_id: int | str | None, code: int, message: str) -> dict[str, Any]:
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {"code": code, "message": message},
        }

    @classmethod
    def _tool_error(cls, request_id: int | str, error: dict[str, Any]) -> dict[str, Any]:
        return cls._response(
            request_id,
            {"content": [{"type": "text", "text": json.dumps({"error": error})}], "isError": True},
        )
