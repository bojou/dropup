#!/usr/bin/env python3
"""Throwaway FTP and SFTP servers for DropUpIntegrationTests.

    pip install pyftpdlib asyncssh bcrypt
    python3 scripts/test-servers.py &      # prints the env vars the tests read, then serves until killed

Both servers accept user "me" with password "secret" and share one root folder with
`drops/`, `drops/archive/` and `ops/` pre-created. The tests read the same folder to check what arrived.

The SFTP server also takes SSH keys. A folder of private key files, outside the served root, is made for the tests
(`DROPUP_IT_KEY_DIR`): keys the server knows, one it doesn't, keys with and without a passphrase (`key-secret`),
kinds DropUp can't sign in with, and files that aren't keys. A second SFTP server (`DROPUP_IT_SFTP_MODERN_PORT`) is like
a current OpenSSH: it refuses the SHA-1 signature that RSA keys are limited to here.
"""
import asyncio
import inspect
import os
import sys
import tempfile
import threading
import warnings

import asyncssh
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler
from pyftpdlib.servers import ThreadedFTPServer

async def _lenient_rename(self, packet):
    """Accept RENAME the way OpenSSH's sftp-server does: ignore bytes after the two paths.

    Citadel (the SFTP client DropUp uses) appends a version 5 `flags` field to the version 3 request.
    asyncssh refuses that ("Unexpected data at end of packet"); OpenSSH and most other servers ignore it.
    """
    oldpath = packet.get_string()
    newpath = packet.get_string()
    result = self._server.rename(oldpath, newpath)
    if inspect.isawaitable(result):
        await result


# asyncssh looks handlers up in a table built when the class was defined, so replace the entry too.
asyncssh.sftp.SFTPServerHandler._process_rename = _lenient_rename
asyncssh.sftp.SFTPServerHandler._packet_handlers[asyncssh.sftp.FXP_RENAME] = _lenient_rename

# The keys made here are throwaway ones; few bcrypt rounds keep the tests quick.
warnings.filterwarnings("ignore", message="Warning: bcrypt.kdf")

async def _start_like_current_openssh(self, packet):
    """Public key auth the way OpenSSH 8.8 and later do it: a server marked `refuses_sha1_rsa` fails a login whose
    RSA key signs with the old SHA-1 `ssh-rsa`, as the SSH library DropUp uses always does. It is otherwise asyncssh's."""
    sig_present = packet.get_boolean()
    algorithm = packet.get_string()
    key_data = packet.get_string()
    if sig_present:
        msg = packet.get_consumed_payload()
        signature = packet.get_string()
    else:
        msg = signature = b""
    packet.check_end()
    if algorithm == b"ssh-rsa" and getattr(self._conn._owner, "refuses_sha1_rsa", False):
        self.send_failure()
    elif await self._conn.validate_public_key(self._username, key_data, msg, signature):
        if sig_present:
            await self.send_success()
        else:
            self.send_packet(asyncssh.auth.MSG_USERAUTH_PK_OK, asyncssh.packet.String(algorithm), asyncssh.packet.String(key_data))
    else:
        self.send_failure()


asyncssh.auth._ServerPublicKeyAuth._start = _start_like_current_openssh

USER, PASSWORD = "me", "secret"
PASSPHRASE = "key-secret"
FTP_PORT = int(os.environ.get("DROPUP_IT_FTP_PORT", "2121"))
SFTP_PORT = int(os.environ.get("DROPUP_IT_SFTP_PORT", "2222"))
MODERN_PORT = int(os.environ.get("DROPUP_IT_SFTP_MODERN_PORT", "2223"))
PASSIVE = (30000, 32000)


def start_ftp(root):
    authorizer = DummyAuthorizer()
    authorizer.add_user(USER, PASSWORD, root, perm="elradfmwMT")
    handler = FTPHandler
    handler.authorizer = authorizer
    handler.passive_ports = range(*PASSIVE)
    server = ThreadedFTPServer(("127.0.0.1", FTP_PORT), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()


def write_keys(directory):
    """Makes the key files the tests sign in with and returns the public keys the server accepts."""
    accepted = []

    def save(name, key, passphrase=None, fmt="openssh", known=True):
        path = os.path.join(directory, name)
        key.write_private_key(path, fmt, passphrase=passphrase, **(
            {"cipher_name": "aes256-ctr", "rounds": 16} if passphrase and fmt == "openssh" else {}
        ))
        os.chmod(path, 0o600)
        if known:
            accepted.append(key.convert_to_public())

    save("ed25519", asyncssh.generate_private_key("ssh-ed25519"))
    save("ed25519-pass", asyncssh.generate_private_key("ssh-ed25519"), PASSPHRASE)
    # A different cipher than the ssh-keygen default: aes128-ctr.
    key = asyncssh.generate_private_key("ssh-ed25519")
    path = os.path.join(directory, "ed25519-aes128")
    key.write_private_key(path, "openssh", passphrase=PASSPHRASE, cipher_name="aes128-ctr", rounds=16)
    accepted.append(key.convert_to_public())
    # One only the SSH library can't open: AES-GCM, which `ssh-keygen -Z aes256-gcm@openssh.com` makes.
    key = asyncssh.generate_private_key("ssh-ed25519")
    key.write_private_key(os.path.join(directory, "ed25519-gcm"), "openssh", passphrase=PASSPHRASE,
                          cipher_name="aes256-gcm@openssh.com", rounds=16)
    accepted.append(key.convert_to_public())
    save("rsa", asyncssh.generate_private_key("ssh-rsa", key_size=2048))
    save("rsa-pass", asyncssh.generate_private_key("ssh-rsa", key_size=2048), PASSPHRASE)
    # The old PEM format, which `ssh-keygen -m PEM` and older tools make.
    save("rsa-pem", asyncssh.generate_private_key("ssh-rsa", key_size=2048), fmt="pkcs1-pem")
    for curve, name in (("ecdsa-sha2-nistp256", "ecdsa-p256"), ("ecdsa-sha2-nistp384", "ecdsa-p384"),
                        ("ecdsa-sha2-nistp521", "ecdsa-p521")):
        save(name, asyncssh.generate_private_key(curve))
    # A valid key the server has never been told about.
    save("ed25519-unknown", asyncssh.generate_private_key("ssh-ed25519"), known=False)
    save("rsa-unknown", asyncssh.generate_private_key("ssh-rsa", key_size=2048), known=False)
    with open(os.path.join(directory, "not-a-key.txt"), "w") as handle:
        handle.write("this is not a key\n")
    # The public half of a key, which isn't a private key.
    asyncssh.generate_private_key("ssh-ed25519").convert_to_public().write_public_key(
        os.path.join(directory, "ed25519.pub"), "openssh")
    # A key cut off in the middle.
    with open(os.path.join(directory, "ed25519"), "r") as handle:
        lines = handle.read().splitlines()
    with open(os.path.join(directory, "ed25519-truncated"), "w") as handle:
        handle.write("\n".join(lines[: len(lines) // 2]) + "\n")
    return accepted


def make_server(accepted, modern=False):
    class Server(asyncssh.SSHServer):
        refuses_sha1_rsa = modern

        def begin_auth(self, username):
            return True

        def password_auth_supported(self):
            return True

        def validate_password(self, username, password):
            return username == USER and password == PASSWORD

        def public_key_auth_supported(self):
            return True

        def validate_public_key(self, username, key):
            return username == USER and any(key == known for known in accepted)

    return Server


async def start_sftp(root, accepted):
    key = asyncssh.generate_private_key("ssh-ed25519")

    def factory(chan):
        return asyncssh.SFTPServer(chan, chroot=root.encode())

    await asyncssh.create_server(
        make_server(accepted), "127.0.0.1", SFTP_PORT, server_host_keys=[key], sftp_factory=factory
    )
    # Like a current OpenSSH: the old SHA-1 signature of an RSA key is refused.
    await asyncssh.create_server(
        make_server(accepted, modern=True), "127.0.0.1", MODERN_PORT, server_host_keys=[key], sftp_factory=factory
    )


async def main():
    root = tempfile.mkdtemp(prefix="dropup-it-")
    os.makedirs(os.path.join(root, "drops", "archive"))
    # Tests that create and delete files and folders use ops/, so they never change what a test listing drops/ sees.
    os.makedirs(os.path.join(root, "ops"))
    keys = tempfile.mkdtemp(prefix="dropup-keys-")
    start_ftp(root)
    await start_sftp(root, write_keys(keys))
    print(f"export DROPUP_IT_ROOT={root}", flush=True)
    print(f"export DROPUP_IT_KEY_DIR={keys}", flush=True)
    print(f"export DROPUP_IT_SFTP_MODERN_PORT={MODERN_PORT}", flush=True)
    print(f"export DROPUP_IT_FTP_PORT={FTP_PORT}", flush=True)
    print(f"export DROPUP_IT_SFTP_PORT={SFTP_PORT}", flush=True)
    print("ready", flush=True)
    await asyncio.Event().wait()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
