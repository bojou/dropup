#!/usr/bin/env python3
"""Throwaway FTP and SFTP servers for DropUpIntegrationTests.

    pip install pyftpdlib asyncssh
    python3 scripts/test-servers.py &      # prints the env vars the tests read, then serves until killed

Both servers accept user "me" with password "secret" and share one root folder with
`drops/` and `drops/archive/` pre-created. The tests read the same folder to check what arrived.
"""
import asyncio
import os
import sys
import tempfile
import threading

import asyncssh
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler
from pyftpdlib.servers import ThreadedFTPServer

USER, PASSWORD = "me", "secret"
FTP_PORT = int(os.environ.get("DROPUP_IT_FTP_PORT", "2121"))
SFTP_PORT = int(os.environ.get("DROPUP_IT_SFTP_PORT", "2222"))
PASSIVE = (30000, 30010)


def start_ftp(root):
    authorizer = DummyAuthorizer()
    authorizer.add_user(USER, PASSWORD, root, perm="elradfmwMT")
    handler = FTPHandler
    handler.authorizer = authorizer
    handler.passive_ports = range(*PASSIVE)
    server = ThreadedFTPServer(("127.0.0.1", FTP_PORT), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()


class Server(asyncssh.SSHServer):
    def begin_auth(self, username):
        return True

    def password_auth_supported(self):
        return True

    def validate_password(self, username, password):
        return username == USER and password == PASSWORD


async def start_sftp(root):
    key = asyncssh.generate_private_key("ssh-ed25519")

    def factory(chan):
        return asyncssh.SFTPServer(chan, chroot=root.encode())

    await asyncssh.create_server(
        Server, "127.0.0.1", SFTP_PORT, server_host_keys=[key], sftp_factory=factory
    )


async def main():
    root = tempfile.mkdtemp(prefix="dropup-it-")
    os.makedirs(os.path.join(root, "drops", "archive"))
    start_ftp(root)
    await start_sftp(root)
    print(f"export DROPUP_IT_ROOT={root}", flush=True)
    print(f"export DROPUP_IT_FTP_PORT={FTP_PORT}", flush=True)
    print(f"export DROPUP_IT_SFTP_PORT={SFTP_PORT}", flush=True)
    print("ready", flush=True)
    await asyncio.Event().wait()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
