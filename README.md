# Jibril Releases

Release channel for Jibril, the Linux eBPF runtime sensor built and maintained
by Garnet Labs Inc. Binary distribution only; source is not public.

[`garnet-org/action`](https://github.com/garnet-org/action) pins and downloads
Jibril from this repository and runs it as a systemd service on supported
Linux runners.

## Verifying a Jibril release

Verifying that a Jibril release is authentic, untampered, and deterministic helps
to harden pipelines against supply chain attacks, configuration drifts, and
unauthorized code execution. Please check the [Verify Jibril release doc](./docs/release-verify.md)
for further details.

## License

Copyright © 2026 Garnet Labs Inc.

Released binaries are licensed under the terms in [LICENSE.md](./LICENSE.md).
Embedded components remain subject to their respective licenses. 
