from fastapi import FastAPI, WebSocket, WebSocketDisconnect
import asyncio
import random
import math
import json
from datetime import datetime
from typing import List, Dict, Any

app = FastAPI()

# Mission state
is_mission_active = False
mission_waypoints = []
current_waypoint_index = 0
mission_progress = 0

# Drone position and telemetry
drone_latitude = 0.0
drone_longitude = 0.0
drone_altitude = 30.0
drone_speed = 5.0
drone_heading = 0.0
drone_battery = 100
drone_spray = 100

# Connected clients
connected_clients: List[WebSocket] = []

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
            "message": "Successfully connected to Agron GCS Server"
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
    global drone_latitude, drone_longitude
    
    msg_type = message.get("type")
    
    if msg_type == "start_mission":
        print("Starting mission with data:", json.dumps(message, indent=2))
        
        if "waypoints" in message:
            mission_waypoints = message["waypoints"]
            if mission_waypoints:
                first_waypoint = mission_waypoints[0]
                print(f"First waypoint: {json.dumps(first_waypoint, indent=2)}")
                
                # Handle different waypoint formats
                if "position" in first_waypoint:
                    drone_latitude = first_waypoint["position"]["latitude"]
                    drone_longitude = first_waypoint["position"]["longitude"]
                elif "latitude" in first_waypoint and "longitude" in first_waypoint:
                    drone_latitude = first_waypoint["latitude"]
                    drone_longitude = first_waypoint["longitude"]
                else:
                    print("Error: Waypoint format not recognized")
                    return
                
                current_waypoint_index = 0
                mission_progress = 0
                print(f"Starting at position: {drone_latitude}, {drone_longitude}")
        
        is_mission_active = True
        await broadcast_message({
            "type": "mission_status",
            "status": "started"
        })
        print("Mission started, telemetry will begin emitting")
        
    elif msg_type == "pause_mission":
        is_mission_active = False
        await broadcast_message({
            "type": "mission_status",
            "status": "paused"
        })
        
    elif msg_type == "resume_mission":
        is_mission_active = True
        await broadcast_message({
            "type": "mission_status",
            "status": "resumed"
        })
        
    elif msg_type == "stop_mission":
        is_mission_active = False
        mission_progress = 0
        current_waypoint_index = 0
        await broadcast_message({
            "type": "mission_status",
            "status": "stopped"
        })
        
    elif msg_type == "emergency_return":
        is_mission_active = False
        mission_progress = 0
        current_waypoint_index = 0
        await broadcast_message({
            "type": "mission_status",
            "status": "emergency_return"
        })

async def broadcast_message(message: Dict[str, Any]):
    """Send message to all connected clients"""
    if not connected_clients:
        return
    
    # Remove disconnected clients
    disconnected = []
    for client in connected_clients:
        try:
            await client.send_json(message)
        except Exception:
            disconnected.append(client)
    
    for client in disconnected:
        if client in connected_clients:
            connected_clients.remove(client)

async def generate_telemetry():
    """Generate and broadcast telemetry data"""
    global drone_latitude, drone_longitude, drone_altitude, drone_speed, drone_heading
    global drone_battery, drone_spray, mission_progress, is_mission_active, current_waypoint_index
    
    while True:
        if is_mission_active and mission_waypoints:
            # Calculate progress based on waypoints
            total_waypoints = len(mission_waypoints)
            if total_waypoints > 0:
                # Move towards current waypoint
                current_waypoint = mission_waypoints[current_waypoint_index]
                
                # Get target coordinates
                if "position" in current_waypoint:
                    target_lat = current_waypoint["position"]["latitude"]
                    target_lng = current_waypoint["position"]["longitude"]
                elif "latitude" in current_waypoint and "longitude" in current_waypoint:
                    target_lat = current_waypoint["latitude"]
                    target_lng = current_waypoint["longitude"]
                else:
                    continue
                
                # Calculate distance to target
                lat_diff = target_lat - drone_latitude
                lng_diff = target_lng - drone_longitude
                distance = (lat_diff**2 + lng_diff**2)**0.5
                
                # Move towards target (1% of remaining distance)
                if distance > 0.00001:  # If not close enough to waypoint
                    drone_latitude += lat_diff * 0.01
                    drone_longitude += lng_diff * 0.01
                    
                    # Calculate heading based on movement direction
                    drone_heading = (math.atan2(lng_diff, lat_diff) * 180 / math.pi) % 360
                else:
                    # Reached current waypoint, move to next
                    current_waypoint_index = min(current_waypoint_index + 1, total_waypoints - 1)
                
                # Update mission progress
                mission_progress = int((current_waypoint_index / total_waypoints) * 100)
                
                # If reached last waypoint, complete mission
                if current_waypoint_index >= total_waypoints - 1 and distance <= 0.00001:
                    is_mission_active = False
                    mission_progress = 100
                    print("Mission completed!")
                    await broadcast_message({
                        "type": "mission_status",
                        "status": "completed"
                    })
        
        # Update other telemetry values
        drone_altitude = 30 + random.uniform(-2, 2)
        drone_speed = 5 + random.uniform(-1, 1)
        drone_battery = max(0, drone_battery - random.uniform(0, 0.1))
        drone_spray = max(0, drone_spray - random.uniform(0, 0.05))
        
        # Create telemetry data
        telemetry = {
            "type": "telemetry",
            "latitude": drone_latitude,
            "longitude": drone_longitude,
            "altitude": drone_altitude,
            "speed": drone_speed,
            "heading": drone_heading,
            "batteryPercentage": int(drone_battery),
            "sprayLevel": int(drone_spray),
            "missionProgress": int(mission_progress),
            "timestamp": datetime.now().isoformat()
        }
        
        # Only emit telemetry if a mission is active
        if is_mission_active:
            print(f"telem: {telemetry}")
            await broadcast_message(telemetry)
        
        # Wait for 1 second
        await asyncio.sleep(1)

@app.on_event("startup")
async def startup_event():
    """Start telemetry generation on startup"""
    asyncio.create_task(generate_telemetry())

@app.get("/status")
def status():
    """Health check endpoint"""
    return {"status": "running", "clients": len(connected_clients)}
