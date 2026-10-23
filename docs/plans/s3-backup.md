# S3 Backup Destination Plan

## Summary

Add support for using an S3 bucket/prefix as a destination for the existing `backup` command. The feature should preserve the current backup semantics as closely as possible: incremental, additive-only, UUID-based filenames, skip existing files/objects, and no delete/prune behavior.

Example:

```bash
darwin-photos backup s3://my-bucket/photos-backup
```

Local backup behavior remains unchanged:

```bash
darwin-photos backup /Volumes/External/photos-backup
```

## Goals

- Support `s3://bucket/prefix` as a `backup` destination.
- Support AWS S3 and S3-compatible providers.
- Use standard AWS SDK credential resolution.
- Preserve current object/file naming semantics: `<UUID>.<ext>`.
- Keep v1 additive and idempotent: upload missing objects only, skip existing objects, never delete.
- Stage cloud-only downloads locally before uploading to S3.
- Upload local Photos originals directly from the Photos library to S3.
- Add `backup --dry-run` for both local and S3 destinations.

## Non-Goals / Out of Scope

- Restore from S3.
- Pruning/deleting S3 objects for photos no longer in the library.
- Date-folder, album-folder, or original-filename-based layouts.
- Client-side encryption.
- Machine-readable `backup --json` output.
- Separate S3-specific worker count.
- Whole-backup local temp-space preflight.
- Managing bucket versioning or creating buckets automatically.

## CLI Behavior

### Destination detection

Use destination scheme:

- `s3://...` → S3 destination
- anything else → local filesystem destination, current behavior

Examples:

```bash
# AWS S3
darwin-photos backup s3://my-bucket/photos-backup

# S3-compatible provider
darwin-photos backup s3://my-bucket/photos-backup \
  --s3-endpoint https://s3.us-west-004.backblazeb2.com \
  --s3-region us-west-004

# MinIO/path-style-compatible provider
darwin-photos backup s3://my-bucket/photos-backup \
  --s3-endpoint https://minio.example.com \
  --s3-region us-east-1 \
  --s3-force-path-style
```

### New backup flags

```bash
--dry-run
--s3-endpoint string
--s3-region string
--s3-force-path-style
--s3-sse string          # AES256 or aws:kms
--s3-kms-key-id string
--s3-storage-class string
```

Existing flags continue to apply:

```bash
--workers int
--retry int
--start YYYY-MM-DD
--end YYYY-MM-DD
```

### Credentials

Use AWS SDK for Go v2 default credential and config chain only:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_SESSION_TOKEN`
- `AWS_PROFILE`
- `~/.aws/config`
- `~/.aws/credentials`
- SSO/process/web identity/role providers supported by the SDK

Do not add access-key or secret-key CLI flags.

## S3 URI Parsing

Accept:

- `s3://bucket`
- `s3://bucket/`
- `s3://bucket/photos`
- `s3://bucket/photos/2024`

Reject:

- `s3://`
- `s3:///missing-bucket`
- unsupported URI schemes like `file://...`

Normalize prefix internally:

- no leading slash
- no required trailing slash
- final object key is `prefix + "/" + filename` when prefix is non-empty

## Object Key Format

Use the same structure as the current local app behavior:

```text
<prefix>/<UUID>.<ext>
```

Extension behavior:

- Preserve `filepath.Ext(asset.Filename)` exactly, including casing.
- If no extension exists, default to `.jpg`.

Examples:

```text
s3://bucket/photos/F8A3B2C1-....HEIC
s3://bucket/photos/A1B2C3D4-....MOV
s3://bucket/photos/00000000-....jpg
```

## Incremental Semantics

Match current local backup behavior:

- Scan destination once before backup.
- Treat any existing object key `<UUID>.<ext>` under the prefix as already backed up.
- Skip existing objects by key name only.
- Do not compare size/checksum in v1.
- Do not overwrite existing objects.
- Do not delete remote objects.

For race protection:

- Pre-scan and skip existing objects.
- Use conditional create semantics where practical, such as `If-None-Match: *` for simple `PutObject` flows.
- Use AWS SDK multipart uploader for large objects; if strict no-overwrite cannot be guaranteed for multipart uploads, document that small race and rely on pre-scan for v1.

## Destination Abstraction

Introduce a small internal abstraction instead of spreading destination conditionals throughout backup code.

Sketch:

```go
type BackupDestination interface {
    Validate(ctx context.Context) error
    ScanExisting(ctx context.Context) (map[string]bool, error)
    StoreLocal(ctx context.Context, asset *models.Asset, srcPath string) error
    StoreStaged(ctx context.Context, asset *models.Asset, stagedPath string) error
}
```

Possible implementations:

- `LocalDestination`
- `S3Destination`

The existing backup orchestration can continue to:

1. Scan Photos library.
2. Scan destination.
3. Categorize missing assets into local vs cloud-only.
4. Copy/upload local originals.
5. Download/upload cloud-only originals.
6. Report failures.

## Local vs Cloud-Only Handling

### Local assets

For S3 destination:

- Open the Photos original directly.
- Upload directly to S3.
- Do not copy to a temp file first.

For local filesystem destination:

- Preserve existing copy behavior.

### Cloud-only assets

For S3 destination:

1. Fetch iCloud download URL.
2. Download to a local temp file.
3. Validate download using existing size checks and future checksum checks.
4. Upload temp file to S3.
5. Delete temp file immediately after upload or failure cleanup.

Default temp location: OS temp directory.

V1 will document that local temp space must be sufficient for concurrent staged downloads. No full temp-space preflight is required in v1.

## S3 Upload Implementation

Use AWS SDK for Go v2:

Likely packages:

```go
github.com/aws/aws-sdk-go-v2/config
github.com/aws/aws-sdk-go-v2/service/s3
github.com/aws/aws-sdk-go-v2/feature/s3/manager
```

Use `manager.Uploader` for multipart support instead of custom multipart logic.

Upload behavior:

- Reuse existing `backup --workers` for S3 upload concurrency.
- No separate `--s3-workers` in v1.
- Failed uploads are tracked by UUID.
- Retry behavior should integrate with the existing `--retry` flag where practical.

## S3 Object Metadata

Store the following user metadata for uploaded objects:

- `date-created`
- `date-modified`
- `original-filename`
- `darwin-photos-uuid`

Do not add GPS, album names, hidden/favorite flags, or camera EXIF as S3 metadata in v1.

Rationale: object metadata is easy to inventory via bucket APIs and logs. Keep metadata limited while still preserving useful restore context.

## Content Type

Set `Content-Type` when possible:

- `.heic` / `.heif` → `image/heic` / `image/heif`
- `.jpg` / `.jpeg` → `image/jpeg`
- `.png` → `image/png`
- `.gif` → `image/gif`
- `.mov` → `video/quicktime`
- `.mp4` → `video/mp4`
- fallback → `application/octet-stream`

Use UTI if already reliable; otherwise infer from extension.

## Server-Side Encryption

Support optional server-side encryption flags:

```bash
--s3-sse AES256
--s3-sse aws:kms
--s3-kms-key-id arn:aws:kms:...
```

Behavior:

- If no flags are provided, rely on bucket/provider defaults.
- `--s3-sse AES256` sets SSE-S3.
- `--s3-sse aws:kms` sets SSE-KMS.
- `--s3-kms-key-id` is only meaningful with KMS.
- No client-side encryption in v1.

## Storage Class

Support optional storage class:

```bash
--s3-storage-class STANDARD_IA
--s3-storage-class GLACIER_IR
--s3-storage-class DEEP_ARCHIVE
```

Default: omit storage class and use bucket/provider default.

For S3-compatible providers, invalid AWS storage classes may fail normally.

## Dry Run

Add `backup --dry-run` for both local and S3 destinations.

Dry run should:

- Scan Photos library.
- Validate destination.
- Scan destination for existing files/objects.
- Print counts and bytes that would be copied/uploaded/downloaded.
- For S3, validate bucket access/config.
- Not copy files.
- Not download from iCloud.
- Not upload to S3.
- Not write failed UUID files.

## Failure Handling

Match current backup/export failure handling:

- Track failed UUIDs.
- Write failures to `~/.darwin-photos/failed_backup_<timestamp>.txt` or reuse existing failed-export helper if not renamed yet.
- Print retry guidance:

```bash
darwin-photos backup s3://bucket/prefix
```

No manifest or separate state database in v1. Retries rely on destination object existence.

## Security Considerations

This feature should also account for the security review in `docs/plans/security-review.md`.

Important security requirements:

- Do not accept S3 credentials via CLI flags.
- Do not log credentials or signed URLs.
- Avoid printing raw AWS error details if they may contain sensitive request data.
- Never overwrite existing S3 objects intentionally.
- Preserve additive-only backup behavior.
- Validate S3 URI parsing carefully.
- Continue to validate/sanitize Photos database path fields before reading local files.
- For local staging, use secure temp files and cleanup on failure.
- Consider checksum verification before upload once iCloud checksum handling is implemented.

Recommended bucket practices to document:

- Enable bucket versioning.
- Enable default encryption.
- Use least-privilege IAM credentials limited to the backup bucket/prefix.
- Consider object lock or lifecycle policies if appropriate.

## Suggested IAM Policy Shape

For a prefix-scoped backup user, permissions should be roughly:

- `s3:ListBucket` on the bucket, restricted to the configured prefix.
- `s3:GetBucketLocation` on the bucket.
- `s3:PutObject` on `arn:aws:s3:::bucket/prefix/*`.
- `s3:AbortMultipartUpload` on `arn:aws:s3:::bucket/prefix/*`.
- `s3:ListMultipartUploadParts` on `arn:aws:s3:::bucket/prefix/*`.
- Optional KMS permissions if using SSE-KMS.

Do not require `s3:DeleteObject` for v1.

## Implementation Steps

1. Add S3 URI parser and tests.
2. Add destination abstraction with local implementation preserving existing behavior.
3. Add `S3Destination` using AWS SDK for Go v2.
4. Add S3 flags to `backup`.
5. Refactor backup orchestration to use destination interface.
6. Implement S3 destination validation and object listing.
7. Implement local-original direct upload.
8. Implement cloud-only temp staging and upload.
9. Add metadata, content type, SSE, endpoint, path-style, and storage-class support.
10. Add `backup --dry-run` for both local and S3.
11. Add tests for URI parsing, key generation, dry run, and destination behavior with mocked S3.
12. Update README usage docs.

## Future Work: Shared Album / Cloud Sharing Assets Without CloudKit Master GUIDs

Observed during S3 backup investigation: some cloud-only assets are skipped with messages like:

```text
Skipping 11824 cloud asset(s) without CloudKit GUIDs
```

Example asset UUID investigated:

```text
9B9B4697-AFCD-4618-8B5B-1EDBCA0D4BF2
```

Findings for that asset:

- The value is a `ZASSET.ZUUID`, not a `ZCLOUDMASTER.ZCLOUDMASTERGUID`.
- `ZASSET.ZMASTER` is `NULL`, so the current lookup path cannot find a `ZCLOUDMASTERGUID`.
- It belongs to a cloud-sharing collection/share named `St Louis` via `ZASSET.ZCOLLECTIONSHARE` / `ZSHARE`.
- `ZASSET.ZCLOUDASSETGUID` is populated (`2933755F-173F-42B7-9B6A-BE7CC7127253` in this case), suggesting shared assets may need a different CloudKit lookup path.
- The original file was not present under `originals/...`; only a small derivative existed under `scopes/cloudsharing/resources/derivatives/masters/...`.
- The skipped count matched assets with no master row in this library:
  - `ZASSET.ZMASTER IS NULL`: 11824
  - no-master assets in collection shares: 11565

Current implementation only supports cloud downloads via:

```sql
ZASSET.ZMASTER -> ZCLOUDMASTER.ZCLOUDMASTERGUID
```

A future implementation should investigate CloudKit lookup/download support for shared-album or cloud-sharing assets using `ZASSET.ZCLOUDASSETGUID` plus `ZSHARE.ZSCOPEIDENTIFIER` / share metadata instead of `ZCLOUDMASTERGUID`. Until then, these assets should be reported as an explicit unsupported category rather than generic missing GUID failures.

## Open Risks

- Multipart upload no-overwrite semantics may not be strict under concurrent writers depending on SDK/API behavior.
- S3-compatible providers vary in support for metadata, storage classes, SSE, and path-style behavior.
- Temp-file staging can consume local disk space proportional to concurrent cloud-only downloads.
- Shared album / cloud-sharing assets may not have `ZCLOUDMASTERGUID`s and currently cannot be downloaded by the S3 backup cloud-download path.
- The existing backup code also needs safe local file-writing improvements from the security review.
