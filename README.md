# LWT Psiphon Runner

Run multiple Psiphon proxy instances concurrently from one shared binary.

Each instance gets its own working directory, generated config, logs, PID files, and public ports. The requested port is exposed as SOCKS5 on `0.0.0.0`; HTTP is exposed on `port + 1`.

## Files

```text
/home/lwtdzh999/lwt-psiphon-runner/
  run-psiphon.sh              Main runner
  test-proxy.sh               Proxy test helper
  tcp-forward.py              Public-port forwarder
  psiphon-tunnel-core-x86_64  Psiphon binary
  client.config               Base config template
  instances/                  Per-instance runtime folders
```

## Direct Run

Start an instance directly:

```bash
cd /home/lwtdzh999/lwt-psiphon-runner
./run-psiphon.sh run -l us -p 1000
```

Equivalent long options:

```bash
./run-psiphon.sh run --location ca --port 2000
```

The old default form also works:

```bash
./run-psiphon.sh -l us -p 1000
```

If no parameters are provided, the script asks for the location and SOCKS5 port:

```bash
./run-psiphon.sh run
```

## Service Mode

Create, enable, and start a supervised systemd service:

```bash
./run-psiphon.sh service start -l us -p 1000
```

Stop and disable the service:

```bash
./run-psiphon.sh service stop -l us -p 1000
```

The generated unit name uses the location and port:

```text
lwt-psiphon-us-1000.service
lwt-psiphon-ca-2000.service
```

Service mode uses `run-psiphon.sh supervise` as the systemd main process. It
starts the Psiphon process and both TCP forwarders, watches them, and exits
non-zero if any of them disappear. The generated unit uses `Restart=always`, so
systemd starts the whole instance again after a crash and also starts it on boot.

## Concurrent Instances

Use different ports for each instance:

```bash
./run-psiphon.sh run -l us -p 1000
./run-psiphon.sh run -l ca -p 2000
./run-psiphon.sh run -l jp -p 3000
```

Result:

```text
US SOCKS5: 0.0.0.0:1000
US HTTP:   0.0.0.0:1001

CA SOCKS5: 0.0.0.0:2000
CA HTTP:   0.0.0.0:2001

JP SOCKS5: 0.0.0.0:3000
JP HTTP:   0.0.0.0:3001
```

Do not reuse a port. If SOCKS uses `1000`, HTTP uses `1001`, so both ports are occupied.

## Status

Show all managed instances:

```bash
./run-psiphon.sh status
```

Example:

```text
US-1000 running psiphon_pid=1234 socks=0.0.0.0:1000 socks_forward_pid=1235 http=0.0.0.0:1001 http_forward_pid=1236
CA-2000 running psiphon_pid=2234 socks=0.0.0.0:2000 socks_forward_pid=2235 http=0.0.0.0:2001 http_forward_pid=2236
```

## Stop Direct Instance

Stop a directly-run instance:

```bash
./run-psiphon.sh stop -l us -p 1000
```

For service-managed instances, prefer:

```bash
./run-psiphon.sh service stop -l us -p 1000
```

## Test Proxy

Test both SOCKS5 and HTTP for a port:

```bash
./test-proxy.sh 1000
```

Manual SOCKS5 test:

```bash
curl --socks5-hostname 127.0.0.1:1000 https://ipinfo.io/country
```

Manual HTTP test:

```bash
curl -x http://127.0.0.1:1001 https://ipinfo.io/country
```

## Locations

List supported location inputs:

```bash
./run-psiphon.sh locations
```

Common examples:

```text
US  United States
CA  Canada
GB  United Kingdom
DE  Germany
FR  France
NL  Netherlands
JP  Japan
SG  Singapore
AU  Australia
```

## How Concurrency Works

Multiple processes can use the same binary file at the same time. The runner avoids conflicts by separating runtime state:

```text
instances/US-1000/client.config
instances/US-1000/psiphon.log
instances/US-1000/psiphon.pid

instances/CA-2000/client.config
instances/CA-2000/psiphon.log
instances/CA-2000/psiphon.pid
```

Psiphon itself listens on private `127.0.0.1` ports. `tcp-forward.py` exposes the requested public ports on `0.0.0.0`.

## Current Verified Example

These were verified working:

```text
US: SOCKS5 0.0.0.0:1000, HTTP 0.0.0.0:1001
CA: SOCKS5 0.0.0.0:2000, HTTP 0.0.0.0:2001
```
