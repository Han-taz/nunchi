"""Run the MCP server: `python -m nunchi.mcp`. Streamable HTTP at /mcp, bearer JWT required."""

if __name__ == "__main__":
    import os

    from nunchi.auth.tokens import OidcSettings, TokenVerifier
    from nunchi.config import Settings
    from nunchi.db import open_pool
    from nunchi.mcp.server import build_server

    server = build_server(
        open_pool(Settings()),
        TokenVerifier(OidcSettings()),
        os.environ.get("NUNCHI_MCP_PUBLIC_URL", "http://127.0.0.1:8000"),
    )
    server.settings.host = os.environ.get("NUNCHI_MCP_HOST", "127.0.0.1")
    server.settings.port = int(os.environ.get("NUNCHI_MCP_PORT", "8000"))
    server.run(transport="streamable-http")
