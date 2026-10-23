# Shoebox

Shoebox backs up your iCloud Photos library to an external drive or an S3 bucket. You can keep "Optimize Mac Storage" on while it runs.

Shoebox has two parts:

- `Shoebox.app`, a menu bar app that runs backups on a schedule.
- `shoebox`, a command-line tool for backups and for looking around your library.

Both parts use the same Swift library, so a backup from the app and a backup from the CLI give the same result.

## Where Shoebox comes from

Shoebox started as a fork of [darwin-photos](https://github.com/cleanexit0/darwin-photos) by [cleanexit0](https://github.com/cleanexit0). darwin-photos is a Go CLI that reads the Photos database directly, copies local originals, and downloads cloud-only originals from iCloud. That approach is the core of Shoebox, and the credit for it goes to darwin-photos.

The plan was to add a few features to the Go tool. It turned into a rewrite. Shoebox is now a separate macOS app in Swift. It is inspired by darwin-photos and derived from it, but it does not track upstream and it does not send changes back.

What changed in the rewrite:

- The code is Swift 6.2 for macOS 26. The original Go code is gone from this branch. It is in the git history and in the upstream repository.
- A menu bar app runs scheduled backups. It waits for power, an allowed network, and the backup drive before it starts.
- PhotoKit downloads cloud-only originals first. The iCloud web API is the fallback for assets that PhotoKit cannot see.
- An in-app login window signs in to iCloud. You do not need to export browser cookies.
- The app keeps a history of runs with a log for each run.

Backups stay compatible with darwin-photos. The file names, S3 object keys, and S3 metadata are the same, so you can point Shoebox at an existing darwin-photos backup and it skips the files that are already there. See [docs/swift-port-plan.md](docs/swift-port-plan.md) for the full list of compatibility rules.

Shoebox keeps its own files in `~/.shoebox`. It does not read `~/.darwin-photos`. To use the iCloud session that darwin-photos saved, run `shoebox export import-session`.

## Install

Shoebox has no release builds yet. To build and install from source, you need Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and an Apple Development signing certificate.

```bash
make install
```

This command:

1. Builds `Shoebox.app` and the `shoebox` CLI.
2. Signs both with your development certificate.
3. Installs the app in `/Applications`.
4. Links the CLI to `~/.local/bin/shoebox`.

Set `SIGNING_IDENTITY`, `APPLICATIONS`, or `BIN_DIR` to change the defaults.

## Requirements

- macOS 26 or later.
- Full Disk Access for Shoebox (System Settings > Privacy & Security > Full Disk Access).
- Access to your Photos library. The app asks for it the first time it runs.
- For assets that PhotoKit cannot download, an iCloud sign-in from the app.

## Quick start

```bash
# See what is in your library
shoebox stats

# List recent photos
shoebox ls

# Back up everything to an external drive
shoebox backup /Volumes/External/photos-backup

# Or back up to S3 or an S3-compatible service
shoebox backup s3://my-bucket/photos-backup
```

## Commands

| Command | Description |
|---------|-------------|
| `stats` | Library overview: counts, sizes, local and cloud |
| `ls` | List photos with filters (date, album, type, cloud or local) |
| `cat` | Show detailed metadata for one photo |
| `albums` | List all albums |
| `backup` | Incremental backup to a local folder or an S3 prefix |
| `export` | Export specific photos by UUID |
| `sync` | Download cloud photos into your Photos library |
| `failures` | List or clear assets that failed before |
| `version` | Print the version |

## Skipped failures

`backup`, `export`, and `sync` record each asset that they cannot find locally or download from iCloud. The list is in `~/.shoebox/failures.db`. Later runs skip these assets by default, so a few broken items do not slow down every backup. A successful attempt removes the asset from the list.

```bash
# Show the skipped assets
shoebox failures

# Try the failed assets again
shoebox backup --retry-failed /Volumes/External/photos-backup

# Forget some assets, or all of them
shoebox failures clear <UUID>
shoebox failures clear --all
```

## S3 backups

```bash
# Use a profile from your AWS config
shoebox backup --s3-profile photos-backup s3://my-bucket/photos-backup

# Use an S3-compatible provider
shoebox backup s3://my-bucket/photos-backup \
  --s3-endpoint https://s3.us-west-004.backblazeb2.com \
  --s3-region us-west-004

# Show what would happen without uploading
shoebox backup --dry-run s3://my-bucket/photos-backup
```

S3 backups use the same layout as local backups: `<UUID>.<ext>` under the prefix. Shoebox skips objects that already exist. Backups only add objects. They never delete remote objects.

The app can also use an IAM user's access key from the Keychain. `scripts/create-backup-iam-user.sh` creates a user with the minimum permissions.

## How it works

Shoebox opens a copy of `Photos.sqlite`, the database that Apple Photos uses. It never writes to the original. This gives it:

- A fast library scan, because the scan is one SQLite query.
- The correct cloud and local status for each asset, from the flags that Photos uses.

For each asset, Shoebox copies the local original if it exists. If the original is only in iCloud, Shoebox downloads it with PhotoKit, or with the iCloud web API as a fallback.

## Configuration

Shoebox keeps its files in `~/.shoebox`:

- `config.json`: settings. The CLI flags override them.
- `failures.db`: the assets to skip.
- `history.json`: recent runs from the app and the CLI.

## License

MIT. Shoebox is derived from darwin-photos, Copyright (c) 2026 cleanexit0. See [LICENSE](LICENSE).

## Disclaimer

Shoebox is unofficial. It is not affiliated with Apple. Use it at your own risk, and keep more than one backup.
