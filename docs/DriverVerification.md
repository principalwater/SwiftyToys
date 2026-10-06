# Native driver-file verification

The preparatory Swift module uses Windows CNG (`BCrypt`) for SHA-256 and
`WinVerifyTrust` for Authenticode. It requires exactly 64 ASCII hex digits,
checks trust with exact-zero success, enables certificate revocation checking,
validates the leaf publisher, and closes verification state on every path.

Combined verification keeps one read-only file handle open without write/delete
sharing across hashing and signature validation. The same handle is supplied to
WinTrust after rewinding. Verification is read-only and needs no administrator
rights; it never installs a package, modifies a device or changes trust settings.

```text
SwiftyToys.exe --test-driver-trust
SwiftyToys.exe --verify-driver-file <file> <pinned-SHA-256> apple
SwiftyToys.exe --verify-driver-file <catalog> <pinned-SHA-256> microsoft-hardware
```

The self-check covers known SHA-256 vectors, streaming, strict hash parsing and
publisher separation. Local real-file validation checks the pinned Apple archive
and a Microsoft-signed Precision Bluetooth catalog; wrong hashes/publishers fail.

This is not a replacement installer yet. Native installation still requires
protected staging/extraction, validated catalog membership for INF/SYS files,
exact hardware matching, retained driver backups and transactional rollback.
Do not enable installation until those boundaries match the existing installer.
Certificate subject matching alone is not a package pin or catalog-membership
check. Offline/revocation failures stop verification rather than lowering trust.
