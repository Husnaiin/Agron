from fastapi import FastAPI, WebSocket, WebSocketDisconnect
import asyncio
import json
import math
import random
import time
from datetime import datetime
from typing import List, Dict, Any
import pathlib

app = FastAPI()

# Mission state
is_mission_active = False
mission_waypoints = []
current_waypoint_index = 0
mission_progress = 0

# Artificial drone position and telemetry
drone_latitude = 40.7128  # Default to New York
drone_longitude = -74.0060
drone_altitude = 20.0
drone_speed = 0.0
drone_heading = 0.0
drone_battery = 100
drone_spray = 100

# Connected clients
connected_clients: List[WebSocket] = []

# Waypoint logging
WAYPOINT_LOG_DIR = pathlib.Path("./waypoint_logs")
WAYPOINT_LOG_DIR.mkdir(exist_ok=True)

def log_waypoints_to_file(waypoints: List[Dict], filename: str, description: str):
    """Log waypoints to a text file for comparison"""
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    filepath = WAYPOINT_LOG_DIR / f"{filename}_{timestamp}.txt"
    
    with open(filepath, 'w') as f:
        f.write(f"{description}\n")
        f.write(f"Timestamp: {datetime.now().isoformat()}\n")
        f.write(f"Total waypoints: {len(waypoints)}\n")
        f.write("=" * 50 + "\n\n")
        
        for i, wp in enumerate(waypoints):
            f.write(f"Waypoint {i + 1}:\n")
            if "position" in wp:
                f.write(f"  Latitude: {wp['position']['latitude']}\n")
                f.write(f"  Longitude: {wp['position']['longitude']}\n")
            elif "latitude" in wp and "longitude" in wp:
                f.write(f"  Latitude: {wp['latitude']}\n")
                f.write(f"  Longitude: {wp['longitude']}\n")
            
            if "altitude" in wp:
                f.write(f"  Altitude: {wp['altitude']}\n")
            if "sprayRate" in wp:
                f.write(f"  Spray Rate: {wp['sprayRate']}\n")
            if "sprayEnabled" in wp:
                f.write(f"  Spray Enabled: {wp['sprayEnabled']}\n")
            f.write("\n")
        
        f.write("=" * 50 + "\n")
        f.write("Raw JSON:\n")
        f.write(json.dumps(waypoints, indent=2))
    
    print(f"Waypoints logged to: {filepath}")

async def broadcast_message(message: Dict[str, Any]):
    """Broadcast message to all connected clients"""
    if connected_clients:
        disconnected = []
        for client in connected_clients:
            try:
                await client.send_json(message)
            except Exception:
                disconnected.append(client)
        
        # Remove disconnected clients
        for client in disconnected:
            if client in connected_clients:
                connected_clients.remove(client)

@app.websocket("/ws/telemetry")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    connected_clients.append(websocket)
    print(f"Client connected. Total clients: {len(connected_clients)}")
    
    try:
        # Send initial connection status
        await websocket.send_json({
            "type": "connection_status",
            "status": "connected",
            "message": "Successfully connected to Agron Artificial GCS Server"
        })
        
        # Listen for client messages
        while True:
            data = await websocket.receive_text()
            try:
                message = json.loads(data)
                await handle_client_message(websocket, message)
            except json.JSONDecodeError:
                print(f"Invalid JSON received: {data}")
            except Exception as e:
                print(f"Error handling message: {e}")
                
    except WebSocketDisconnect:
        print("Client disconnected")
    except Exception as e:
        print(f"WebSocket error: {e}")
    finally:
        if websocket in connected_clients:
            connected_clients.remove(websocket)
        print(f"Client removed. Total clients: {len(connected_clients)}")

async def handle_client_message(websocket: WebSocket, message: Dict[str, Any]):
    global is_mission_active, mission_waypoints, current_waypoint_index, mission_progress
    global drone_latitude, drone_longitude, drone_altitude
    
    msg_type = message.get("type")
    
    if msg_type == "start_mission":
        print("Starting mission with data:", json.dumps(message, indent=2))
        
        if "waypoints" in message:
            mission_waypoints = message["waypoints"]
            
            # Log received waypoints from frontend
            log_waypoints_to_file(
                mission_waypoints, 
                "frontend_waypoints", 
                "Waypoints received from frontend"
            )
            
            if mission_waypoints:
                first_waypoint = mission_waypoints[0]
                print(f"First waypoint: {json.dumps(first_waypoint, indent=2)}")
                
                # Handle different waypoint formats
                if "position" in first_waypoint:
                    drone_latitude = first_waypoint["position"]["latitude"]
                    drone_longitude = first_waypoint["position"]["longitude"]
                    if "altitude" in first_waypoint:
                        drone_altitude = first_waypoint["altitude"]
                elif "latitude" in first_waypoint and "longitude" in first_waypoint:
                    drone_latitude = first_waypoint["latitude"]
                    drone_longitude = first_waypoint["longitude"]
                    if "altitude" in first_waypoint:
                        drone_altitude = first_waypoint["altitude"]
                else:
                    print("Error: Waypoint format not recognized")
                    return
                
                current_waypoint_index = 0
                mission_progress = 0
                print(f"Starting at position: {drone_latitude}, {drone_longitude}")
        
        is_mission_active = True
        await broadcast_message({
            "type": "mission_status",
            "status": "started",
            "mode": "AUTO",
            "target_speed_kmh": 10,
        })
        print("Mission started, artificial telemetry will begin emitting")
        
    elif msg_type == "pause_mission":
        is_mission_active = False
        await broadcast_message({
            "type": "mission_status",
            "status": "paused"
        })
        print("Mission paused")
        
    elif msg_type == "resume_mission":
        is_mission_active = True
        await broadcast_message({
            "type": "mission_status",
            "status": "resumed"
        })
        print("Mission resumed")
        
    elif msg_type == "stop_mission":
        is_mission_active = False
        mission_progress = 0
        current_waypoint_index = 0
        await broadcast_message({
            "type": "mission_status",
            "status": "stopped"
        })
        print("Mission stopped")
        
    elif msg_type == "emergency_return":
        is_mission_active = False
        mission_progress = 0
        current_waypoint_index = 0
        await broadcast_message({
            "type": "mission_status",
            "status": "emergency_return"
        })
        print("Emergency return triggered")
        
    elif msg_type == "upload_mission":
        print("Mission upload received:", json.dumps(message, indent=2))
        
        if "waypoints" in message:
            # Log uploaded waypoints
            log_waypoints_to_file(
                message["waypoints"], 
                "uploaded_waypoints", 
                "Waypoints uploaded to server"
            )
            
            mission_waypoints = message["waypoints"]
            print(f"Mission uploaded with {len(mission_waypoints)} waypoints")
        
        await broadcast_message({
            "type": "mission_status",
            "status": "uploaded",
            "waypoint_count": len(mission_waypoints) if mission_waypoints else 0
        })
        
    elif msg_type == "capture_rgb":
        print("RGB capture command received")
        await broadcast_message({
            "type": "capture_status",
            "status": "rgb_captured",
            "timestamp": datetime.now().isoformat()
        })
        
    elif msg_type == "capture_noir":
        print("NoIR capture command received")
        await broadcast_message({
            "type": "capture_status",
            "status": "noir_captured",
            "timestamp": datetime.now().isoformat()
        })
        
    elif msg_type == "ping":
        # Respond to ping with pong
        await websocket.send_json({
            "type": "pong",
            "timestamp": datetime.now().isoformat()
        })

def simulate_drone_movement():
    """Simulate drone movement along waypoints"""
    global drone_latitude, drone_longitude, drone_altitude, drone_speed, drone_heading
    global current_waypoint_index, mission_progress
    
    if not is_mission_active or not mission_waypoints:
        return
    
    if current_waypoint_index >= len(mission_waypoints):
        # Mission completed
        is_mission_active = False
        mission_progress = 100
        return
    
    current_wp = mission_waypoints[current_waypoint_index]
    
    # Extract waypoint position
    if "position" in current_wp:
        target_lat = current_wp["position"]["latitude"]
        target_lon = current_wp["position"]["longitude"]
        target_alt = current_wp.get("altitude", drone_altitude)
    else:
        target_lat = current_wp["latitude"]
        target_lon = current_wp["longitude"]
        target_alt = current_wp.get("altitude", drone_altitude)
    
    # Calculate distance to waypoint
    lat_diff = target_lat - drone_latitude
    lon_diff = target_lon - drone_longitude
    distance = math.sqrt(lat_diff**2 + lon_diff**2)
    
    # Move towards waypoint (simplified movement)
    if distance > 0.0001:  # ~11 meters
        # Move 1% of the distance each update
        move_factor = 0.01
        drone_latitude += lat_diff * move_factor
        drone_longitude += lon_diff * move_factor
        
        # Calculate heading
        drone_heading = math.degrees(math.atan2(lon_diff, lat_diff))
        if drone_heading < 0:
            drone_heading += 360
        
        # Set speed based on distance
        drone_speed = min(distance * 1000, 10.0)  # Max 10 m/s
    else:
        # Reached waypoint
        drone_latitude = target_lat
        drone_longitude = target_lon
        drone_altitude = target_alt
        drone_speed = 0.0
        current_waypoint_index += 1
        
        # Update mission progress
        mission_progress = int((current_waypoint_index / len(mission_waypoints)) * 100)
        print(f"Reached waypoint {current_waypoint_index}/{len(mission_waypoints)}")

async def generate_artificial_telemetry():
    """Generate artificial telemetry data"""
    global drone_battery, drone_spray
    
    while True:
        if is_mission_active:
            # Simulate drone movement
            simulate_drone_movement()
            
            # Simulate battery drain
            drone_battery = max(0, drone_battery - random.uniform(0.1, 0.3))
            
            # Simulate spray level changes
            if random.random() < 0.1:  # 10% chance to change spray level
                drone_spray = max(0, drone_spray - random.uniform(0.5, 2.0))
        
        # Add some random noise to telemetry
        lat_noise = random.uniform(-0.00001, 0.00001)
        lon_noise = random.uniform(-0.00001, 0.00001)
        alt_noise = random.uniform(-0.5, 0.5)
        heading_noise = random.uniform(-2, 2)
        
        telemetry = {
            "type": "telemetry",
            "latitude": drone_latitude + lat_noise,
            "longitude": drone_longitude + lon_noise,
            "altitude": drone_altitude + alt_noise,
            "speed": drone_speed,
            "heading": (drone_heading + heading_noise) % 360,
            "batteryPercentage": int(drone_battery),
            "sprayLevel": int(drone_spray),
            "missionProgress": mission_progress,
            "timestamp": datetime.now().isoformat()
        }
        
        if is_mission_active:
            print(f"Artificial telemetry: {telemetry}")
        
        await broadcast_message(telemetry)
        await asyncio.sleep(1)  # Send telemetry every second

@app.on_event("startup")
async def startup_event():
    """Start artificial telemetry generation on startup"""
    print("Starting Agron Artificial GCS Server...")
    print(f"Waypoint logs will be saved to: {WAYPOINT_LOG_DIR.absolute()}")
    asyncio.create_task(generate_artificial_telemetry())

@app.get("/status")
def status():
    """Health check endpoint"""
    return {
        "status": "running", 
        "clients": len(connected_clients),
        "server_type": "artificial",
        "mission_active": is_mission_active,
        "waypoint_count": len(mission_waypoints),
        "current_position": {
            "latitude": drone_latitude,
            "longitude": drone_longitude,
            "altitude": drone_altitude
        }
    }

@app.get("/waypoints")
def get_waypoints():
    """Get current mission waypoints"""
    return {
        "waypoints": mission_waypoints,
        "current_index": current_waypoint_index,
        "progress": mission_progress
    }

if __name__ == "__main__":
    import uvicorn
    print("Starting Agron Artificial GCS Server on http://localhost:5001")
    print("WebSocket endpoint: ws://localhost:5001/ws/telemetry")
    print("Waypoint logs directory: ./waypoint_logs/")
    uvicorn.run(app, host="0.0.0.0", port=5001)
