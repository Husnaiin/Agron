from fastapi import FastAPI, WebSocket
import asyncio
import random
from datetime import datetime

app = FastAPI()


@app.websocket("/ws/telemetry")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()

    # Initialize mock state
    latitude = 0.0
    longitude = 0.0
    altitude = 30.0
    speed = 5.0
    heading = 0.0
    battery_percentage = 100
    spray_level = 100
    mission_progress = 0

    # Emit telemetry once per second
    while True:
        # Simulate a small random walk for lat/lng
        latitude += random.uniform(-0.00005, 0.00005)
        longitude += random.uniform(-0.00005, 0.00005)

        # Simulate other values
        altitude = 30.0 + random.uniform(-2.0, 2.0)
        speed = 5.0 + random.uniform(-1.0, 1.0)
        heading = (heading + random.uniform(-5.0, 5.0)) % 360
        battery_percentage = max(10, battery_percentage - random.randint(0, 1))
        spray_level = max(0, spray_level - random.randint(0, 1))
        mission_progress = min(100, mission_progress + random.randint(0, 1))

        telemetry = {
            "latitude": float(latitude),
            "longitude": float(longitude),
            "altitude": float(altitude),
            "speed": float(speed),
            "heading": float(heading),
            "batteryPercentage": int(battery_percentage),
            "sprayLevel": int(spray_level),
            "missionProgress": int(mission_progress),
            "timestamp": datetime.utcnow().isoformat()
        }

        await websocket.send_json(telemetry)
        await asyncio.sleep(1)
