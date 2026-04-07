# alepbloyd.computer

## Pull WMATA vehicle positions for a date

Use this script to download all `wmata/vehicle_positions` protobuf files in S3 for a specific day.

```bash
python3 scripts/pull_vehicle_positions.py 2026-04-06 --bucket busybusybusy-dc
```

Optional flags:

- `--list-only` only prints matching S3 keys.
- `--output-dir <path>` writes files to a custom folder.
- `--profile <aws_profile>` uses a named AWS profile.
- `--region <aws_region>` sets region explicitly.
