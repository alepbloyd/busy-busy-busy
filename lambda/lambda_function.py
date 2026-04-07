import os
import time
from datetime import datetime
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError
import boto3

S3 = boto3.client("s3")


def fetch_bytes(url, headers, timeout=30):
    request = Request(url, headers=headers)
    with urlopen(request, timeout=timeout) as response:
        return response.read()


def fetch_to_s3(bucket, headers, source_url, key, content_type):
    content = fetch_bytes(source_url, headers=headers)
    S3.put_object(Bucket=bucket, Key=key, Body=content, ContentType=content_type)
    return len(content)


def collect_realtime_sweep(bucket, headers, trip_updates_url, vehicle_positions_url, alerts_url):
    timestamp = datetime.utcnow().isoformat().replace(":", "-") + "Z"
    results = {}
    errors = {}

    feeds = [
        ("trip_updates", trip_updates_url, f"wmata/trip_updates/{timestamp}.pb"),
        ("vehicle_positions", vehicle_positions_url, f"wmata/vehicle_positions/{timestamp}.pb"),
        ("alerts", alerts_url, f"wmata/alerts/{timestamp}.pb"),
    ]

    for feed_name, url, key in feeds:
        try:
            byte_count = fetch_to_s3(bucket, headers, url, key, "application/x-protobuf")
            results[feed_name] = {"key": key, "bytes": byte_count}
        except Exception as error:
            errors[feed_name] = str(error)

    return {"timestamp": timestamp, "feeds": results, "errors": errors}


def daily_gtfs_static_handler(event, context):
    bucket = os.environ.get("BUCKET")
    api_key = os.environ.get("WMATA_API_KEY", "")
    static_url = os.environ.get("WMATA_STATIC_URL", "https://api.wmata.com/gtfs/bus-gtfs-static.zip")
    headers = {"api_key": api_key}
    timestamp = datetime.utcnow().isoformat().replace(":", "-") + "Z"
    key = f"wmata/static/{timestamp}.zip"

    try:
        byte_count = fetch_to_s3(bucket, headers, static_url, key, "application/zip")
        return {
            "status": "ok",
            "task": "daily_gtfs_static",
            "bucket": bucket,
            "key": key,
            "bytes": byte_count,
        }
    except HTTPError as error:
        return {"status": "error", "message": str(error)}
    except URLError as error:
        return {"status": "error", "message": str(error)}
    except Exception as error:
        return {"status": "error", "message": str(error)}


def trip_updates_handler(event, context):
    bucket = os.environ.get("BUCKET")
    api_key = os.environ.get("WMATA_API_KEY", "")
    trip_updates_url = os.environ.get("WMATA_TRIP_UPDATES_URL", "https://api.wmata.com/gtfs/bus-gtfsrt-tripupdates.pb")
    vehicle_positions_url = os.environ.get("WMATA_VEHICLE_POSITIONS_URL", "https://api.wmata.com/gtfs/bus-gtfsrt-vehiclepositions.pb")
    alerts_url = os.environ.get("WMATA_ALERTS_URL", "https://api.wmata.com/gtfs/bus-gtfsrt-alerts.pb")
    bus_incidents_url = os.environ.get("WMATA_BUS_INCIDENTS_URL", "http://api.wmata.com/Incidents.svc/json/BusIncidents")
    collection_interval_seconds = int(os.environ.get("GTFS_REALTIME_INTERVAL_SECONDS", "20"))
    sweeps_per_invocation = int(os.environ.get("GTFS_REALTIME_SWEEPS_PER_INVOCATION", "3"))
    headers = {"api_key": api_key}
    sweeps = []
    any_errors = False
    incidents = {}

    incidents_timestamp = datetime.utcnow().isoformat().replace(":", "-") + "Z"
    incidents_key = f"wmata/bus_incidents/{incidents_timestamp}.json"
    try:
        incidents_bytes = fetch_to_s3(bucket, headers, bus_incidents_url, incidents_key, "application/json")
        incidents = {"key": incidents_key, "bytes": incidents_bytes}
    except Exception as error:
        any_errors = True
        incidents = {"error": str(error)}

    for index in range(sweeps_per_invocation):
        sweep = collect_realtime_sweep(bucket, headers, trip_updates_url, vehicle_positions_url, alerts_url)
        sweeps.append(sweep)
        if sweep["errors"]:
            any_errors = True
        if index < sweeps_per_invocation - 1:
            time.sleep(collection_interval_seconds)

    if any_errors:
        return {
            "status": "partial",
            "task": "gtfs_realtime",
            "bucket": bucket,
            "incidents": incidents,
            "sweeps": sweeps,
        }

    return {
        "status": "ok",
        "task": "gtfs_realtime",
        "bucket": bucket,
        "incidents": incidents,
        "sweeps": sweeps,
    }


def handler(event, context):
    return daily_gtfs_static_handler(event, context)
