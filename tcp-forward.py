#!/usr/bin/env python3
import argparse
import select
import socket
import threading


def relay(left, right):
    sockets = [left, right]
    try:
        while True:
            readable, _, _ = select.select(sockets, [], [])
            for src in readable:
                dst = right if src is left else left
                data = src.recv(65536)
                if not data:
                    return
                dst.sendall(data)
    finally:
        for sock in sockets:
            try:
                sock.close()
            except OSError:
                pass


def handle_client(client, target_host, target_port):
    try:
        upstream = socket.create_connection((target_host, target_port), timeout=15)
    except OSError:
        client.close()
        return
    relay(client, upstream)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--target-host", required=True)
    parser.add_argument("--target-port", required=True, type=int)
    args = parser.parse_args()

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.listen, args.port))
    server.listen(256)

    while True:
        client, _ = server.accept()
        thread = threading.Thread(
            target=handle_client,
            args=(client, args.target_host, args.target_port),
            daemon=True,
        )
        thread.start()


if __name__ == "__main__":
    main()
