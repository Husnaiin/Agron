from fastapi import FastAPI, WebSocket, WebSocketDisconnect
import asyncio
import json
import math
import threading
import time
from datetime import datetime
from typing import List, Dict, Any

try:
    from pymavlink import mavutil
except Exception:
    mavutil = None  # allows app to load even if pymavlink missing

app = FastAPI()

# Mission state
is_mission_active = False
mission_waypoints = []
current_waypoint_index = 0
mission_progress = 0

# Drone position and telemetry
drone_latitude = 0.0
drone_longitude = 0.0
drone_altitude = 0.0
drone_speed = 0.0
drone_heading = 0.0
drone_battery = 0
drone_spray = 100

# Track last known good coordinates (even if GPS has no current fix)
last_good_latitude = None  # type: float | None
last_good_longitude = None  # type: float | None

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

    elif msg_type == "upload_mission":
        try:
            waypoints = message.get("waypoints", [])
            default_alt = message.get("defaultAltitude", 30)
            print(f"[UPLOAD] Received {len(waypoints)} waypoints for upload")
            if mavutil is None:
                await websocket.send_json({"type": "upload_result", "ok": False, "error": "pymavlink not installed"})
                return

            # Convert waypoints to MAVLink mission items (GLOBAL_INT)
            mission_items = []
            seq = 0
            for wp in waypoints:
                # Accept both {position:{lat,lng}} and {latitude,longitude}
                if "position" in wp:
                    lat = float(wp["position"]["latitude"]) if wp["position"].get("latitude") is not None else 0.0
                    lon = float(wp["position"]["longitude"]) if wp["position"].get("longitude") is not None else 0.0
                    alt = float(wp.get("altitude", default_alt))
                else:
                    lat = float(wp.get("latitude", 0.0))
                    lon = float(wp.get("longitude", 0.0))
                    alt = float(wp.get("altitude", default_alt))

                mission_items.append({
                    "seq": seq,
                    "frame": mavutil.mavlink.MAV_FRAME_GLOBAL_RELATIVE_ALT_INT,
                    "command": mavutil.mavlink.MAV_CMD_NAV_WAYPOINT,
                    "current": 1 if seq == 0 else 0,
                    "autocontinue": 1,
                    "param1": 0,  # hold time
                    "param2": 0,  # acceptance radius
                    "param3": 0,  # pass radius
                    "param4": float('nan'),  # yaw
                    "x": int(lat * 1e7),
                    "y": int(lon * 1e7),
                    "z": alt,
                })
                seq += 1

            # Perform upload in a background thread to avoid blocking WS loop
            def _do_upload(items):
                try:
                    m = mavutil.mavlink_connection(MAVLINK_PORT, baud=MAVLINK_BAUD)
                    m.wait_heartbeat(timeout=10)
                    print("[UPLOAD] Connected, clearing and sending mission...")
                    m.mav.mission_clear_all_send(m.target_system, m.target_component)
                    m.mav.mission_count_send(m.target_system, m.target_component, len(items))

                    recv_seq = 0
                    while True:
                        msg = m.recv_match(type=['MISSION_REQUEST_INT', 'MISSION_ACK'], blocking=True, timeout=10)
                        if not msg:
                            raise TimeoutError('MISSION_REQUEST timeout')
                        if msg.get_type() == 'MISSION_ACK':
                            print('[UPLOAD] ACK received')
                            break
                        if msg.get_type() == 'MISSION_REQUEST_INT':
                            i = msg.seq
                            it = items[i]
                            m.mav.mission_item_int_send(
                                m.target_system,
                                m.target_component,
                                it['seq'],
                                it['frame'],
                                it['command'],
                                it['current'],
                                it['autocontinue'],
                                it['param1'], it['param2'], it['param3'], it['param4'],
                                it['x'], it['y'], int(it['z'])
                            )
                            recv_seq += 1
                            if recv_seq >= len(items):
                                # wait for final ACK
                                ack = m.recv_match(type='MISSION_ACK', blocking=True, timeout=10)
                                if not ack:
                                    raise TimeoutError('MISSION_ACK timeout')
                                break
                    print('[UPLOAD] Mission upload complete')
                    return True, None
                except Exception as e:
                    return False, str(e)

            loop = asyncio.get_event_loop()
            ok, err = await loop.run_in_executor(None, _do_upload, mission_items)
            await websocket.send_json({"type": "upload_result", "ok": ok, "error": err})
        except Exception as e:
            await websocket.send_json({"type": "upload_result", "ok": False, "error": str(e)})

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


# ====== MAVLink integration ======
MAVLINK_PORT = "/dev/ttyACM0"
MAVLINK_BAUD = 115200


def _request_message_interval(m: "mavutil.mavfile", msg_id: int, hz: float, target_comp: int) -> None:
    try:
        interval_us = int(1_000_000 / hz) if hz > 0 else 0
        m.mav.command_long_send(
            m.target_system,
            target_comp,
            mavutil.mavlink.MAV_CMD_SET_MESSAGE_INTERVAL,
            0,
            msg_id,
            interval_us,
            0, 0, 0, 0, 0,
        )
    except Exception:
        pass


def _mavlink_reader_loop():
    global drone_latitude, drone_longitude, drone_altitude
    global drone_speed, drone_heading, drone_battery

    if mavutil is None:
        print("pymavlink not installed; telemetry will remain static")
        return

    while True:
        try:
            print(f"[MAVLINK] Connecting {MAVLINK_PORT} @ {MAVLINK_BAUD}...")
            m = mavutil.mavlink_connection(MAVLINK_PORT, baud=MAVLINK_BAUD)
            m.wait_heartbeat(timeout=10)
            print(f"[MAVLINK] Heartbeat from system {m.target_system} comp {m.target_component}")

            autopilot_comp = m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1

            for msg_id, hz in [
                (mavutil.mavlink.MAVLINK_MSG_ID_GLOBAL_POSITION_INT, 10),
                (mavutil.mavlink.MAVLINK_MSG_ID_VFR_HUD, 5),
                (mavutil.mavlink.MAVLINK_MSG_ID_SYS_STATUS, 1),
                (mavutil.mavlink.MAVLINK_MSG_ID_ATTITUDE, 10),
                (mavutil.mavlink.MAVLINK_MSG_ID_GPS_RAW_INT, 2),
            ]:
                _request_message_interval(m, msg_id, hz, autopilot_comp)

            # Legacy ArduPilot stream requests (best-effort)
            try:
                def req(ds_id: int, hz: int):
                    m.mav.request_data_stream_send(m.target_system, autopilot_comp, ds_id, hz, 1)

                req(mavutil.mavlink.MAV_DATA_STREAM_POSITION, 10)
                req(mavutil.mavlink.MAV_DATA_STREAM_EXTRA1, 10)
                req(mavutil.mavlink.MAV_DATA_STREAM_EXTRA2, 5)
                req(mavutil.mavlink.MAV_DATA_STREAM_EXTENDED_STATUS, 1)
            except Exception:
                pass

            # One-shot requests for static/origin info
            try:
                # HOME_POSITION
                m.mav.command_long_send(
                    m.target_system,
                    autopilot_comp,
                    mavutil.mavlink.MAV_CMD_REQUEST_MESSAGE,
                    0,
                    mavutil.mavlink.MAVLINK_MSG_ID_HOME_POSITION,
                    0, 0, 0, 0, 0, 0,
                )
                # GPS_GLOBAL_ORIGIN (EKF origin)
                m.mav.command_long_send(
                    m.target_system,
                    autopilot_comp,
                    mavutil.mavlink.MAV_CMD_REQUEST_MESSAGE,
                    0,
                    mavutil.mavlink.MAVLINK_MSG_ID_GPS_GLOBAL_ORIGIN,
                    0, 0, 0, 0, 0, 0,
                )
            except Exception:
                pass

            while True:
                msg = m.recv_match(blocking=True, timeout=1)
                if not msg:
                    continue
                t = msg.get_type()

                if t == "GLOBAL_POSITION_INT":
                    # lat/lon degE7, relative_alt in mm, heading hdg/100 deg
                    try:
                        if getattr(msg, "lat", None) is not None and getattr(msg, "lon", None) is not None:
                            lat = msg.lat / 1e7
                            lon = msg.lon / 1e7
                            # Accept only valid range; some boards send 0 until EKF origin set
                            if -90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0 and not (lat == 0.0 and lon == 0.0):
                                drone_latitude = lat
                                drone_longitude = lon
                                globals()["last_good_latitude"] = lat
                                globals()["last_good_longitude"] = lon
                        if getattr(msg, "relative_alt", None) is not None:
                            drone_altitude = msg.relative_alt / 1000.0
                        if getattr(msg, "hdg", None) not in (None, 65535):
                            drone_heading = (msg.hdg / 100.0) % 360.0
                    except Exception:
                        pass

                elif t == "VFR_HUD":
                    try:
                        if getattr(msg, "groundspeed", None) is not None:
                            drone_speed = float(msg.groundspeed)
                        if getattr(msg, "heading", None) is not None:
                            drone_heading = float(msg.heading) % 360.0
                        if getattr(msg, "alt", None) is not None and not drone_altitude:
                            drone_altitude = float(msg.alt)
                    except Exception:
                        pass

                elif t == "ATTITUDE":
                    try:
                        # fallback heading from yaw (rad)
                        if getattr(msg, "yaw", None) is not None and not drone_heading:
                            drone_heading = (math.degrees(float(msg.yaw)) + 360.0) % 360.0
                    except Exception:
                        pass

                elif t == "SYS_STATUS":
                    try:
                        br = getattr(msg, "battery_remaining", -1)
                        if br is not None and br >= 0:
                            drone_battery = int(br)
                    except Exception:
                        pass

                elif t == "GPS_RAW_INT":
                    # Even without a fix, many stacks report last lat/lon here; use as a fallback
                    try:
                        if getattr(msg, "lat", None) is not None and getattr(msg, "lon", None) is not None:
                            lat = msg.lat / 1e7
                            lon = msg.lon / 1e7
                            if -90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0 and not (lat == 0.0 and lon == 0.0):
                                # Do not overwrite a valid GLOBAL_POSITION_INT, but keep as last-known
                                globals()["last_good_latitude"] = lat
                                globals()["last_good_longitude"] = lon
                                if (drone_latitude == 0.0 and drone_longitude == 0.0):
                                    drone_latitude = lat
                                    drone_longitude = lon
                    except Exception:
                        pass

                elif t == "HOME_POSITION":
                    try:
                        if getattr(msg, "latitude", None) is not None and getattr(msg, "longitude", None) is not None:
                            lat = msg.latitude / 1e7
                            lon = msg.longitude / 1e7
                            if -90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0:
                                globals()["last_good_latitude"] = lat
                                globals()["last_good_longitude"] = lon
                                if (drone_latitude == 0.0 and drone_longitude == 0.0):
                                    drone_latitude = lat
                                    drone_longitude = lon
                    except Exception:
                        pass

        except Exception as e:
            print(f"[MAVLINK] Error: {e}; reconnecting in 2s")
            time.sleep(2)
            continue

async def generate_telemetry():
    """Broadcast telemetry data as received from Pixhawk (no simulation)."""
    global mission_progress, is_mission_active

    while True:
        # Use last known good coordinates if current are zero/empty
        lat_out = drone_latitude if drone_latitude not in (None, 0.0) else last_good_latitude
        lon_out = drone_longitude if drone_longitude not in (None, 0.0) else last_good_longitude

        telemetry = {
            "type": "telemetry",
            "latitude": lat_out,
            "longitude": lon_out,
            "altitude": drone_altitude,
            "speed": drone_speed,
            "heading": drone_heading,
            "batteryPercentage": int(drone_battery) if isinstance(drone_battery, (int, float)) else None,
            "sprayLevel": int(drone_spray),
            "missionProgress": int(mission_progress),
            "timestamp": datetime.now().isoformat()
        }

        #if is_mission_active:
        print(f"telem: {telemetry}")
        await broadcast_message(telemetry)

        await asyncio.sleep(1)

@app.on_event("startup")
async def startup_event():
    """Start telemetry generation on startup"""
    # Start MAVLink reader background thread
    threading.Thread(target=_mavlink_reader_loop, daemon=True).start()
    # Periodic broadcast task
    asyncio.create_task(generate_telemetry())

@app.get("/status")
def status():
    """Health check endpoint"""
    return {"status": "running", "clients": len(connected_clients)}
#source /home/agron/gcs-server/venv/bin/activate
#uvicorn server1:app --host 0.0.0.0 --port 5001 --reload
