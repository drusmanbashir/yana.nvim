"""Run the line-delimited stdio MCP server."""

import asyncio
import json
import os
import sys

from mcpyana.mcp_server import McpServer, SocketHost


async def serve(host):
    server = McpServer(host, mode=os.environ.get("YANA_MCP_MODE", "inline"))
    try:
        for line in sys.stdin:
            response = await server.handle_line(line)
            if response is not None:
                sys.stdout.write(json.dumps(response) + "\n")
                sys.stdout.flush()
    finally:
        host.close()


def main():
    address = os.environ.get("YANA_MCP_SOCKET")
    if not address:
        raise SystemExit("YANA_MCP_SOCKET must name the Neovim buffer endpoint")
    try:
        host = SocketHost(address)
    except OSError as exc:
        raise SystemExit(f"cannot connect to YANA_MCP_SOCKET: {exc}") from exc
    asyncio.run(serve(host))


if __name__ == "__main__":
    main()
