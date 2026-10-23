# Phase 0 results

This file records the results of the Phase 0 spikes in `swift-port-plan.md`. The spike code was removed after the port. It is in the git history.

## Spike 1: iCloud login in a SwiftUI WebView

Status: passed.

- The macOS 26 `WebView` and `WebPage` APIs show the iCloud sign-in, including two-factor authentication.
- The sign-in puts 19 cookies on `.icloud.com`, including `X-APPLE-WEBAUTH-TOKEN`.
- With these cookies, a native `URLSession` client gets 200 from `setup.icloud.com/setup/ws/1/validate` and 200 from CloudKit `zones/list`. `zones/list` returns `PrimarySync` and the shared zones.
- `validate` returned 200 on the first host. No partition redirect was necessary.
- The cookies saved as `cookies.txt` work with `darwin-photos export import-cookies`. The Go export in spike 2 used them.

### Rules for the port

- The client must set the `Cookie` header itself. A new `HTTPCookieStorage` assigned to the session configuration did not send the cookies. Apple then returned 421 with a partition header on every request, which caused a redirect loop.
- A 421 redirect loop means the request has no valid session. The port must report it as "sign in again", not as a network error.
- The client must send a Safari user agent.

### Open item

The sign-in did not survive an app restart, although the app uses a persistent `WKWebsiteDataStore`. The auth cookies are probably session cookies. The spike now prints each cookie's expiry date to confirm this. The port stores the cookies in the Keychain, so a restart does not lose them. The open question is how long Apple accepts them.

## Spike 2: PhotoKit downloads

Status: passed. Test set: 10 cloud-only photos and 3 cloud-only videos, 505.7 MB in total.

| Measurement | Go, iCloud web API | PhotoKit, `PHAssetResourceManager` |
|---|---|---|
| Result | 13 of 13 | 13 of 13 |
| Time, concurrency 4 | 9.3 s | 19.2 s (first run) |
| Throughput | about 54 MB/s | 26.4 MB/s |
| Bytes | Same SHA-256 for all 13 files | Same SHA-256 for all 13 files |
| Needs an iCloud web session | Yes | No |

- PhotoKit returns the same original bytes as the iCloud web API.
- PhotoKit does not change the library status. All 13 assets were still "Cloud" after the download.
- A second PhotoKit run of the same assets took 0.3 s. Some system cache keeps the downloaded resources, but the library does not record them as local. The location and the size limit of this cache are unknown.
- The two methods ran at different times, so the speed comparison is approximate.
- For small photos, PhotoKit spent 0.5 to 1.9 s on each request. Its throughput for videos was 15 to 22 MB/s.

### Decision

The port uses PhotoKit for all cloud-only downloads. It does not port the iCloud web API or the cookie sign-in. The results of spike 1 are therefore not used in the port.

### Defect found in the Go tool

`ls` reports a size of 0 MB for the three videos, and `export` reports a total of 23.7 MB. The real total is 505.7 MB. The video size comes from the wrong field. The port must not copy this behavior.

## Spike 3: S3 with the AWS SDK for Swift

Status: passed with the `gstark` profile. The static-key test is not run.

| Check | Result |
|---|---|
| Conditional put of a new key | Passed. 4.7 s, which includes the 1Password `credential_process` prompt |
| Conditional put of an existing key | 412 `PreconditionFailed` |
| Head object | Content type and all three metadata keys round-trip |
| Conditional multipart upload of a new key | Passed. 2 parts, 6 MB |
| Conditional multipart upload of an existing key | 412 `PreconditionFailed` from `CompleteMultipartUpload` |
| List objects with the paginator | Passed |

- The AWS SDK for Swift resolves `credential_process` from the profile. 1Password asked for Touch ID once.
- The SDK has no modeled error type for 412. It throws `UnknownAWSHTTPServiceError`. The port must detect 412 through `AWSServiceError.errorCode == "PreconditionFailed"` or the HTTP status, not through an error type.
- For a multipart upload, S3 checks `If-None-Match` only at `CompleteMultipartUpload`. All parts upload before the 412. The key scan before the upload prevents this cost in normal runs.
- A clean debug build of the SDK took about 1.5 minutes. A cached build took 4 s.
- The spike objects stay in the bucket under `darwin-photos-spike/1791979909/`.

## Spike 5: PhotoKit instead of Photos.sqlite

Status: run. The decision is open.

### Asset set

| Source | Assets |
|---|---|
| Go `ls` (`Photos.sqlite`, trash excluded) | 44,163 |
| PhotoKit, user library | 30,847 |
| PhotoKit, shared albums | 13,055 |
| Only in Go | 261 |
| Only in PhotoKit | 0 |

The 261 assets that only Go lists are photos with the status "Cloud". They are not in a shared album, so the Go `backup` uploads them.

`ZSAVEDASSETTYPE` in `Photos.sqlite` (trash excluded):

| Type | Assets | In a shared album | PhotoKit source |
|---|---|---|---|
| 3 | 12,942 | 0 | User library |
| 6 | 17,909 | 0 | User library |
| 4 | 12,632 | All | Shared album |
| 16 | 423 | All | Shared album |
| 12 | 257 | 0 | Not visible |

- Type 12 assets come from Messages (`ZIMPORTEDBYBUNDLEIDENTIFIER = com.apple.MobileSMS`). PhotoKit does not return them.
- The Photos app shows a type 12 asset in search with a Messages badge. It is a real photo, not only a duplicate.
- Types 3 and 6 have 30,851 assets, but PhotoKit returns 30,847. The 4 missing assets are type 3 photos from 2012 with `ZHIDDEN = 1`. The fetch sets `includeHiddenAssets = true`, but PhotoKit does not return them.

### PhotoKit cannot reach these assets

- A full PhotoKit fetch with `includeHiddenAssets = true` returns 0 hidden assets. `Photos.sqlite` has 4.
- `PHAsset.fetchAssets(withLocalIdentifiers:)` finds 0 of the 261 assets.
- All 261 assets are cloud-only. PhotoKit can therefore not download them.

### What the Go tool gets today

`~/.darwin-photos/failures.db` has 430 assets that the Go tool cannot download.

| Assets | Go result |
|---|---|
| 257 Messages assets (type 12) | All fail: "no supported CloudKit download record" |
| 4 hidden assets | Not in `failures.db`. The iCloud web API downloads them |
| 175 other assets | Fail: "no supported CloudKit download record" or CloudKit `NOT_FOUND`. PhotoKit can see them |

- No tool can download the 257 Messages assets now. A possible source is the Messages attachments folder, `~/Library/Messages/Attachments`. This is not tested.
- The 4 hidden assets need the iCloud web API.
- Of the 175 other assets, 62 are still in the library. PhotoKit found and downloaded all 62, including videos of 31 MB, 40 MB, and 179 MB.
- The other 113 are not in the current `ls` output. They are deleted or in Recently Deleted. Their rows in `failures.db` are stale.

### Result

With the hybrid design, the backup can get every non-shared asset in the library except the 257 Messages assets. That is 62 more assets than the Go tool backs up.

### Fields

| Field | Source | Match with Go |
|---|---|---|
| Media type | Public | 100% |
| Creation date | Public | 100% |
| Original file name | Public | 100% |
| Modification date | Public | Present for 86% |
| Backup extension from the original file name | Public | 12.6% (48.0% if case is ignored) |
| Backup extension from `UTType` | Public | 71.2% |
| `ZFILENAME` from `PHAsset.filename` | Private | 100% |
| Size from `PHAssetResource.fileSize` | Private | 65.1%. The other values are 0 |
| Status from `PHAssetResource.locallyAvailable` | Private | Key does not exist |

- The backup extension comes from `ZFILENAME`. Only the private `filename` key gives it for all assets. Examples of differences: `.MP4` against `mp4`, and `.JPG` against `jpeg`. Some assets have a `.JPG` file in the library and an original name that ends in `.HEIC`.
- PhotoKit has no way to tell local assets from cloud assets.
- Reading the resources of all 43,902 assets took 89.5 s. The fetch of the assets alone took 0.2 s.

### Local copy speed

- 49 local assets: the same bytes through PhotoKit and through a direct copy.
- Direct copy: about 3,200 MB/s. PhotoKit: 166 MB/s.
- One asset failed: Go reports it as local, but the file is not at `originals/<first UUID character>/<ZFILENAME>`.

## Spike 4: Full Disk Access after a rebuild

Status: not run.
