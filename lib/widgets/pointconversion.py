import json
import csv
from io import StringIO

def convert_mission_json_to_csv(json_string, output_file="waypoints.csv"):
    # Parse the JSON string
    data = json.loads(json_string)

    # Handle if wrapped in mission object
    if isinstance(data, dict) and "waypoints" in data:
        waypoints = data["waypoints"]
    elif isinstance(data, list):
        waypoints = data
    else:
        raise ValueError("Invalid JSON: must contain 'waypoints' or be a list")

    # Open CSV for writing
    with open(output_file, "w", newline="") as csvfile:
        writer = csv.writer(csvfile)
        writer.writerow(["Waypoint", "Latitude", "Longitude"])

        for i, wp in enumerate(waypoints, start=1):
            writer.writerow([
                i,
                wp["position"]["latitude"],
                wp["position"]["longitude"],
            ])

    print(f"✅ Saved {len(waypoints)} waypoints to '{output_file}'")

# Example usage:
mission_json_string = '''
{
  "type": "start_mission",
  "waypoints": [
    {
      "position": {
        "latitude": 40.712793669732555,
        "longitude": -74.0060059059877
      },
      "altitude": 20.0,
      "sprayRate": 2.0,
      "sprayEnabled": true
    },
    {
      "position": {
        "latitude": 40.712533872770685,
        "longitude": -74.00613943318928
      },
      "altitude": 20.0,
      "sprayRate": 2.0,
      "sprayEnabled": true
    },
    {
      "position": {
        "latitude": 40.71268478904808,
        "longitude": -74.00644667220315
      },
      "altitude": 20.0,
      "sprayRate": 2.0,
      "sprayEnabled": true
    },
    {
      "position": {
        "latitude": 40.71268478904808,
        "longitude": -74.00558693440955
      },
      "altitude": 20.0,
      "sprayRate": 2.0,
      "sprayEnabled": true
    },
    {
      "position": {
        "latitude": 40.71283570532548,
        "longitude": -74.00546430452661
      },
      "altitude": 20.0,
      "sprayRate": 2.0,
      "sprayEnabled": true
    },
    {
      "position": {
        "latitude": 40.71283570532548,
        "longitude": -74.00640131656492
      },
      "altitude": 20.0,
      "sprayRate": 2.0,
      "sprayEnabled": true
    },
    {
      "position": {
        "latitude": 40.71298662160288,
        "longitude": -74.0062843954571
      },
      "altitude": 20.0,
      "sprayRate": 2.0,
      "sprayEnabled": true
    },
    {
      "position": {
        "latitude": 40.71298662160288,
        "longitude": -74.00534557990831
      },
      "altitude": 20.0,
      "sprayRate": 2.0,
      "sprayEnabled": true
    },
    {
      "position": {
        "latitude": 40.71313753788028,
        "longitude": -74.0057062974214
      },
      "altitude": 20.0,
      "sprayRate": 2.0,
      "sprayEnabled": true
    },
    {
      "position": {
        "latitude": 40.71313753788028,
        "longitude": -74.00616747434927
      },
      "altitude": 20.0,
      "sprayRate": 2.0,
      "sprayEnabled": true
    },
    {
      "position": {
        "latitude": 40.712382956493286,
        "longitude": -74.00583219417541
      },
      "altitude": 20.0,
      "sprayRate": 2.0,
      "sprayEnabled": true
    },
    {
      "position": {
        "latitude": 40.712533872770685,
        "longitude": -74.00570956429247
      },
      "altitude": 20.0,
      "sprayRate": 2.0,
      "sprayEnabled": true
    }
  ]
}

'''

convert_mission_json_to_csv(mission_json_string)
