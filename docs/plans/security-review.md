# Security Review Plan

Application: `darwin-photos`
Purpose: sync/back up iCloud Photos to secondary storage
Review date: 2026-06-08

## Summary

The application is a local macOS CLI that reads the Photos database, copies local originals, and downloads cloud-only originals using iCloud browser-cookie authentication. In the normal single-user local-CLI threat model, no obvious remote code execution or credential-exfiltration issue was found. However, several hardening items should be addressed before treating the tool as robust around untrusted backup directories, untrusted Photos libraries/databases, or shared machines.

`go test ./...` passed at review time.

## Findings and Remediation Plan

### 1. High: Backup/export can overwrite arbitrary files via symlink or TOCTOU race

Affected code:

- `internal/icloud/download.go` — final cloud download write uses `os.Create(outputPath)`
- `cmd/backup.go` — local backup copy uses `os.Create(dst)`
- `cmd/export.go` — existing-file checks happen before download/copy and are raceable

#### Risk

`os.Create` follows symlinks and truncates existing files. If an attacker can write to the backup/export directory, they can create or swap a symlink named like `<UUID>.jpg` pointing to another file the user can write. The backup/export operation may then overwrite or truncate that target.

#### Remediation

- Write to a temporary file in the same directory.
- Open temporary files with exclusive creation.
- Use restrictive file permissions by default, e.g. `0600` or `0644` depending on desired behavior.
- On macOS/Unix, use `O_NOFOLLOW` where available.
- Verify the destination does not exist immediately before finalizing.
- Atomically rename the temp file into place.
- Clean up temp files on failure.

#### Acceptance criteria

- Existing destination files are never truncated.
- Symlink destinations are not followed for final backup/export writes.
- Failed/interrupted downloads do not leave a completed-looking output file.
- Unit or integration tests cover symlink destination behavior and existing-file behavior.

---

### 2. High: Malicious Photos database values can escape expected paths

Affected code:

- `cmd/utils.go` — `buildLocalPath` trusts `asset.Directory` and `asset.Filename` from `Photos.sqlite`
- `cmd/sync.go` — temp output path uses `asset.OriginalFilename` / `asset.Filename`

#### Risk

A user can provide `--library` pointing to any Photos library path. If that library/database is malicious, path fields may contain `..`, absolute paths, or path separators. This can cause reads outside the intended Photos library, or writes outside a temporary directory during sync.

#### Remediation

- Treat all path and filename values from `Photos.sqlite` as untrusted.
- Reject absolute paths.
- Reject `..` path elements.
- Reject path separators in filename fields where only filenames are expected.
- For source paths, clean and verify the result remains under `<library>/originals`.
- For temporary sync output, use a generated safe filename rather than a database-provided filename.
- Keep original filenames only for display/metadata where appropriate.

#### Acceptance criteria

- Malicious `Directory`/`Filename` values cannot cause reads outside the Photos library.
- Malicious `OriginalFilename`/`Filename` values cannot cause writes outside temp directories.
- Tests cover absolute paths, `..`, slash-containing names, and normal Photos paths.

---

### 3. Medium: Cloud download uses `http.Get` without configured timeout or URL validation

Affected code:

- `internal/icloud/download.go` — `downloadOnce` uses package-level `http.Get(downloadURL)`

#### Risk

Package-level `http.Get` uses the default client and does not apply the configured client timeout. The code also does not enforce `https` or validate that the URL points to an expected Apple/iCloud download host.

#### Remediation

- Parse `downloadURL` before use.
- Require `https`.
- Use `c.httpClient` or a dedicated downloader client with a timeout.
- Consider an allowlist for known Apple/iCloud CDN hosts if stable enough.
- Use request contexts for cancellation in future long-running workflows.

#### Acceptance criteria

- Non-HTTPS download URLs are rejected.
- Downloads use a client with a finite timeout.
- Tests verify rejection of invalid schemes and malformed URLs.

---

### 4. Medium: No checksum verification for downloaded originals

Affected code:

- `internal/icloud/photos.go` captures CloudKit `Checksum`
- `internal/icloud/download.go` only verifies `Content-Length`

#### Risk

Content length detects truncation but not corruption or malicious substitution. CloudKit provides a checksum value that is currently unused.

#### Remediation

- Determine the CloudKit checksum algorithm and encoding.
- Stream downloads through a hashing reader/writer.
- Verify the checksum before finalizing the output file.
- Keep using size verification as an additional check.

#### Acceptance criteria

- Downloads with mismatched checksums are rejected and temp files are removed.
- Successful downloads verify both size and checksum when checksum is available.
- Tests cover checksum mismatch and success cases.

---

### 5. Medium: Session directory permissions are only secure on first creation

Affected code:

- `internal/icloud/session.go`

#### Risk

The session file is written with `0600`, which is good. The session directory is created with `0700`, also good. However, if `~/.darwin-photos` already exists with permissive permissions, `os.MkdirAll` will not correct it. Symlinked session paths are also not explicitly guarded.

#### Remediation

- After creating or locating the session directory, `stat` it and enforce owner-only permissions.
- Refuse symlinked session directories/files, or resolve and validate them deliberately.
- Prefer secure `OpenFile` patterns for writing the session file.

#### Acceptance criteria

- The app warns or fails when the session directory is group/world-readable or writable.
- The app does not write session secrets through unexpected symlinks.
- Tests cover pre-existing permissive session directories.

---

### 6. Low: Error messages may print sensitive Apple response bodies

Affected code:

- `internal/icloud/client.go`
- `internal/icloud/photos.go`

#### Risk

Some iCloud/CloudKit error paths include full response bodies. These bodies may contain account, session, or diagnostic details depending on Apple’s response.

#### Remediation

- Redact response bodies from normal errors.
- Include status code and high-level Apple error code/message where possible.
- Add an explicit verbose/debug mode for full response bodies if needed.

#### Acceptance criteria

- Default error output does not include raw Apple response bodies.
- Debug output remains opt-in.

## Positive Security Notes

- SQL queries generally use parameter binding for user-provided values.
- The saved iCloud session file is written with `0600` permissions.
- The default session directory is created with `0700` when absent.
- The tool does not expose a listening service.
- Photos database access is read-only.
- Failed UUID files do not contain secrets.

## Recommended Implementation Order

1. Add safe file-writing helpers for backup/export/download flows.
2. Add path/filename validation helpers for all Photos database path fields.
3. Update cloud downloading to enforce HTTPS and use a timeout-bound client.
4. Add checksum verification for CloudKit downloads.
5. Harden session directory/file handling.
6. Redact raw Apple response bodies from default errors.

## Suggested Tests

- Backup to directory containing symlink named `<UUID>.jpg` must not follow/truncate target.
- Backup/export must not overwrite existing destination files.
- Partial failed download leaves no final destination file.
- Database filename with `../escape.jpg` is rejected.
- Database filename with `/tmp/escape.jpg` is rejected.
- Database directory with `../../` is rejected.
- Sync temp path cannot escape temp directory.
- HTTP download rejects `http://`, `file://`, and malformed URLs.
- Session directory with unsafe permissions is rejected or fixed.
