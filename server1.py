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

# Shared MAVLink connection
mavlink_master = None  # type: ignore
mavlink_lock = threading.Lock()
mavlink_rx_pause = threading.Event()
mavlink_pause_since = 0.0

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
        
        # Guided takeoff, then AUTO: set GUIDED, arm, take off to 20 m, then AUTO + MISSION_START
        if mavutil is not None:
            with mavlink_lock:
                m = globals().get("mavlink_master")
            if m:
                print("[MISSION] Arming and setting AUTO mode...")
                _arm_vehicle(m, force=True)
                armed = _wait_heartbeat_armed(m, timeout_s=8.0)
                print(f"[MISSION] Armed: {armed}")
                if not armed:
                    raise RuntimeError("Failed to arm vehicle")
                print("[MISSION] Setting AUTO mode and ground speed 10 km/h...")
                _set_mode_auto(m)
                _set_ground_speed(m, speed_mps=10.0/3.6)
                time.sleep(1.0)
                print("[MISSION] Sending MISSION_START")
                # Force mission to start at seq=0 (TAKEOFF)
                _mission_set_current(m, 0)

                # Start mission
                _mission_start(m, 0, 0)


        is_mission_active = True
        await broadcast_message({
            "type": "mission_status",
            "status": "started",
            "mode": "AUTO",
            "target_speed_kmh": 10,
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
        # Trigger RTL on the autopilot
        if mavutil is not None:
            with mavlink_lock:
                m = globals().get("mavlink_master")
            if m:
                try:
                    print("[MISSION] stop_mission: setting mode RTL")
                    m.set_mode_apm('RTL')
                except Exception:
                    try:
                        print("[MISSION] stop_mission: sending MAV_CMD_NAV_RETURN_TO_LAUNCH")
                        m.mav.command_long_send(
                            m.target_system,
                            m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1,
                            mavutil.mavlink.MAV_CMD_NAV_RETURN_TO_LAUNCH,
                            0,
                            0, 0, 0, 0, 0, 0, 0,
                        )
                    except Exception:
                        pass
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

    elif msg_type == "start_capture":
        print("[CAMERA] Received start_capture command")
        await broadcast_message({
            "type": "camera_status",
            "status": "capture_started"
        })

    elif msg_type == "stop_capture":
        print("[CAMERA] Received stop_capture command")
        await broadcast_message({
            "type": "camera_status",
            "status": "capture_stopped"
        })

    elif msg_type == "upload_mission":
        # Expected payload: { "type": "upload_mission", "waypoints": [ {"latitude": .., "longitude": ..}, ... ] }
        if mavutil is None:
            await websocket.send_json({"type": "mission_status", "status": "error", "message": "pymavlink not installed"})
            return
        with mavlink_lock:
            m = globals().get("mavlink_master")
        if not m:
            await websocket.send_json({"type": "mission_status", "status": "error", "message": "autopilot not connected"})
            return

        raw_wps = message.get("waypoints") or []
        if not isinstance(raw_wps, list) or len(raw_wps) == 0:
            await websocket.send_json({"type": "mission_status", "status": "error", "message": "no waypoints provided"})
            return

        # Build mission items: TAKEOFF (20m) -> WAYPOINTS (20m) -> RTL
        print(f"[MISSION] upload_mission received with {len(raw_wps)} waypoints")
        try:
            frame = mavutil.mavlink.MAV_FRAME_GLOBAL_RELATIVE_ALT
            cmds_int = []  # MISSION_ITEM_INT messages
            cmds_flt = []  # MISSION_ITEM (float) messages

            # Ensure TAKEOFF is not ignored by firmware (MIS_OPTIONS bit0 should be 0)
            try:
                print("[MISSION] Checking MIS_OPTIONS (should not ignore TAKEOFF)")
                m.mav.param_request_read_send(
                    m.target_system,
                    m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1,
                    b"MIS_OPTIONS",
                    -1,
                )
                pv = m.recv_match(type='PARAM_VALUE', blocking=True, timeout=2)
                if pv and getattr(pv, 'param_id', b'')[:11] == b"MIS_OPTIONS":
                    current = int(getattr(pv, 'param_value', 0.0))
                    if current & 1:
                        new_val = float(current & ~1)
                        print(f"[MISSION] Clearing MIS_OPTIONS bit0 (ignore_takeoff): {current} -> {int(new_val)}")
                        m.mav.param_set_send(
                            m.target_system,
                            m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1,
                            b"MIS_OPTIONS",
                            new_val,
                            mavutil.mavlink.MAV_PARAM_TYPE_REAL32,
                        )
                        # small wait to apply
                        time.sleep(0.2)
            except Exception:
                pass

            # Debug: print incoming parsed waypoints
            print("[MISSION] Incoming waypoints (parsed):")
            for i, wp in enumerate(raw_wps):
                lat_dbg, lon_dbg = _extract_lat_lon(wp)
                print(f"  idx={i} lat={lat_dbg} lon={lon_dbg}")

            # Dummy-first pattern: WP(0)=first, TAKEOFF(1)=first, WP(2)=first again, then remaining WPs, then RTL
            first_lat, first_lon = _extract_lat_lon(raw_wps[0]) if raw_wps else (0.0, 0.0)
            if first_lat is None or first_lon is None:
                first_lat, first_lon = 0.0, 0.0

            # Item 0: dummy loiter (time) at first coords for 3 seconds
            wp0_int = mavutil.mavlink.MAVLink_mission_item_int_message(
                m.target_system,
                m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1,
                0,
                frame,
                mavutil.mavlink.MAV_CMD_NAV_LOITER_TIME,
                0,
                1,
                3.0, 0, 0, 0,
                int(first_lat * 1e7),
                int(first_lon * 1e7),
                20.0,
            )
            wp0_flt = mavutil.mavlink.MAVLink_mission_item_message(
                m.target_system,
                m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1,
                0,
                frame,
                mavutil.mavlink.MAV_CMD_NAV_LOITER_TIME,
                0,
                1,
                3.0, 0, 0, 0,
                float(first_lat),
                float(first_lon),
                20.0,
            )
            cmds_int.append(wp0_int)
            cmds_flt.append(wp0_flt)
            print(f"[MISSION] Built item 0: {_cmd_name(wp0_int.command)} hold=3s lat={first_lat} lon={first_lon} alt=20")

            # Item 1: takeoff at first coords
            takeoff_int = mavutil.mavlink.MAVLink_mission_item_int_message(
                m.target_system,
                m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1,
                1,
                frame,
                mavutil.mavlink.MAV_CMD_NAV_TAKEOFF,
                0,
                1,
                0, 0, 0, 0,
                # int(first_lat * 1e7),
                # int(first_lon * 1e7),
                0,
                0,
                20.0,
            )
            takeoff_flt = mavutil.mavlink.MAVLink_mission_item_message(
                m.target_system,
                m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1,
                1,
                frame,
                mavutil.mavlink.MAV_CMD_NAV_TAKEOFF,
                0,
                1,
                0, 0, 0, 0,
                # float(first_lat),
                # float(first_lon),
                0,
                0,
                20.0,
            )
            cmds_int.append(takeoff_int)
            cmds_flt.append(takeoff_flt)
            print(f"[MISSION] Built item 1: {_cmd_name(takeoff_int.command)} alt={takeoff_int.z} lat={first_lat} lon={first_lon}")

            # Item 2: first waypoint again
            seq = 2
            prepared_wp = 0
            wp_first_int = mavutil.mavlink.MAVLink_mission_item_int_message(
                m.target_system,
                m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1,
                seq,
                frame,
                mavutil.mavlink.MAV_CMD_NAV_WAYPOINT,
                0,
                1,
                0, 0, 0, 0,
                int(first_lat * 1e7),
                int(first_lon * 1e7),
                20.0,
            )
            wp_first_flt = mavutil.mavlink.MAVLink_mission_item_message(
                m.target_system,
                m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1,
                seq,
                frame,
                mavutil.mavlink.MAV_CMD_NAV_WAYPOINT,
                0,
                1,
                0, 0, 0, 0,
                float(first_lat),
                float(first_lon),
                20.0,
            )
            cmds_int.append(wp_first_int)
            cmds_flt.append(wp_first_flt)
            print(f"[MISSION] Built item {seq}: {_cmd_name(wp_first_int.command)} lat={first_lat} lon={first_lon} alt=20")
            seq += 1
            prepared_wp += 1

            # Remaining waypoints (skip the first, already added twice)
            for wp in raw_wps[1:]:
                lat, lon = _extract_lat_lon(wp)
                if not isinstance(lat, (int, float)) or not isinstance(lon, (int, float)):
                    continue
                wp_int = mavutil.mavlink.MAVLink_mission_item_int_message(
                    m.target_system,
                    m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1,
                    seq,
                    frame,
                    mavutil.mavlink.MAV_CMD_NAV_WAYPOINT,
                    0,
                    1,
                    0, 0, 0, 0,
                    int(lat * 1e7),
                    int(lon * 1e7),
                    20.0,
                )
                wp_flt = mavutil.mavlink.MAVLink_mission_item_message(
                    m.target_system,
                    m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1,
                    seq,
                    frame,
                    mavutil.mavlink.MAV_CMD_NAV_WAYPOINT,
                    0,
                    1,
                    0, 0, 0, 0,
                    float(lat),
                    float(lon),
                    20.0,
                )
                cmds_int.append(wp_int)
                cmds_flt.append(wp_flt)
                print(f"[MISSION] Built item {seq}: {_cmd_name(wp_int.command)} lat={lat} lon={lon} alt=20")
                seq += 1
                prepared_wp += 1

            # Last: RTL
            rtl_int = mavutil.mavlink.MAVLink_mission_item_int_message(
                m.target_system,
                m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1,
                seq,
                frame,
                mavutil.mavlink.MAV_CMD_NAV_RETURN_TO_LAUNCH,
                0,
                1,
                0, 0, 0, 0,
                0,
                0,
                0,
            )
            rtl_flt = mavutil.mavlink.MAVLink_mission_item_message(
                m.target_system,
                m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1,
                seq,
                frame,
                mavutil.mavlink.MAV_CMD_NAV_RETURN_TO_LAUNCH,
                0,
                1,
                0, 0, 0, 0,
                0.0,
                0.0,
                0.0,
            )
            cmds_int.append(rtl_int)
            cmds_flt.append(rtl_flt)
            print(f"[MISSION] Built item {seq}: {_cmd_name(rtl_int.command)}")

            print(f"[MISSION] Prepared items: dummy=1, takeoff=1, waypoints={prepared_wp}, rtl=1 -> total={len(cmds_int)}")
            # Upload mission (clear, count, send items, wait ack)
            # Pause RX loop to avoid contention while we transact the mission protocol
            mavlink_rx_pause.set()
            globals()["mavlink_pause_since"] = time.monotonic()
            try:
                with mavlink_lock:
                    # Clear existing
                    m.mav.mission_clear_all_send(m.target_system, m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1)
                    # Drain any stale acks
                    m.recv_match(type=['MISSION_ACK'], blocking=False, timeout=0.2)
                    # Count (with mission_type=0: MAV_MISSION_TYPE_MISSION)
                    total = len(cmds_int)
                    print(f"[MISSION] Sending mission_count={total}")
                    try:
                        m.mav.mission_count_send(m.target_system, m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1, total, 0)
                    except TypeError:
                        # Older pymavlink signature without mission_type
                        m.mav.mission_count_send(m.target_system, m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1, total)

                    expected = total
                    sent = 0
                    while sent < expected:
                        msg_req = m.recv_match(type=['MISSION_REQUEST_INT','MISSION_REQUEST'], blocking=True, timeout=5)
                        if not msg_req:
                            raise RuntimeError("Timeout waiting for MISSION_REQUEST")
                        idx = getattr(msg_req, 'seq', None)
                        if idx is None or idx < 0 or idx >= expected:
                            print(f"[MISSION] Unexpected request: {msg_req}")
                            continue
                        # Prefer INT item; if FCU asked legacy, send float
                        # Always send INT items; some firmwares ask legacy but expect INT
                        print(f"[MISSION] -> sending INT item seq={idx} ({_cmd_name(cmds_int[idx].command)})")
                        m.mav.send(cmds_int[idx])
                        sent = idx + 1

                    ack = m.recv_match(type='MISSION_ACK', blocking=True, timeout=5)
                    print(f"[MISSION] ACK: {ack}")
                    if not ack:
                        raise RuntimeError("Mission upload failed: no ack")
                    ack_type = getattr(ack, 'type', None)
                    if ack_type == mavutil.mavlink.MAV_MISSION_ACCEPTED:
                        pass
                    elif ack_type == mavutil.mavlink.MAV_MISSION_INVALID_PARAM:
                        raise RuntimeError("Mission invalid param")
                    elif ack_type == mavutil.mavlink.MAV_MISSION_INVALID_SEQUENCE:
                        raise RuntimeError("Mission invalid sequence")
                    elif ack_type == mavutil.mavlink.MAV_MISSION_DENIED:
                        raise RuntimeError("Mission denied")
                    else:
                        raise RuntimeError(f"Mission upload failed: ack type {ack_type}")
                    # Readback verification: list and print FCU-stored mission items
                    try:
                        print("[MISSION] Verifying mission on FCU (readback)...")
                        m.mav.mission_request_list_send(m.target_system, m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1)
                        cnt_msg = m.recv_match(type='MISSION_COUNT', blocking=True, timeout=3)
                        if cnt_msg:
                            total_rb = int(getattr(cnt_msg, 'count', 0) or 0)
                            print(f"[MISSION] FCU reports count={total_rb}")
                            first_cmd = None
                            for i_rb in range(total_rb):
                                # Prefer INT
                                m.mav.mission_request_int_send(m.target_system, m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1, i_rb)
                                it = m.recv_match(type=['MISSION_ITEM_INT','MISSION_ITEM'], blocking=True, timeout=2)
                                if not it:
                                    print(f"[MISSION] Missing item {i_rb}")
                                    continue
                                cmd_id = getattr(it, 'command', None)
                                print(f"[MISSION] FCU item {i_rb}: {_cmd_name(cmd_id)}")
                                if i_rb == 0:
                                    first_cmd = cmd_id
                            # If item 0 is not TAKEOFF, force-fix it via partial write
                            if first_cmd is not None and first_cmd != mavutil.mavlink.MAV_CMD_NAV_TAKEOFF:
                                print("[MISSION] FCU item 0 is not TAKEOFF; fixing via MISSION_WRITE_PARTIAL_LIST")
                                # Build a TAKEOFF item at index 0 using current or first wp coords
                                fix_lat, fix_lon = _extract_lat_lon(raw_wps[0])
                                fix_int = mavutil.mavlink.MAVLink_mission_item_int_message(
                                    m.target_system,
                                    m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1,
                                    0,
                                    frame,
                                    mavutil.mavlink.MAV_CMD_NAV_TAKEOFF,
                                    0,
                                    1,
                                    0, 0, 0, 0,
                                    int((fix_lat or 0.0) * 1e7),
                                    int((fix_lon or 0.0) * 1e7),
                                    20.0,
                                )
                                # Request partial write for index 0 only
                                m.mav.mission_write_partial_list_send(
                                    m.target_system,
                                    m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1,
                                    0, 0,
                                )
                                # Respond to request(s) for seq 0
                                while True:
                                    req = m.recv_match(type=['MISSION_REQUEST_INT','MISSION_REQUEST'], blocking=True, timeout=3)
                                    if not req:
                                        break
                                    rseq = getattr(req, 'seq', -1)
                                    if rseq != 0:
                                        print(f"[MISSION] Unexpected partial req seq={rseq}")
                                        continue
                                    print("[MISSION] -> sending INT item seq=0 (TAKEOFF) [partial]")
                                    m.mav.send(fix_int)
                                    break
                                ack2 = m.recv_match(type='MISSION_ACK', blocking=True, timeout=5)
                                print(f"[MISSION] Partial ACK: {ack2}")
                    except Exception:
                        pass
                    except Exception:
                        pass
            finally:
                mavlink_rx_pause.clear()

            await websocket.send_json({"type": "mission_status", "status": "uploaded", "count": len(cmds_int)})
        except Exception as exc:
            await websocket.send_json({"type": "mission_status", "status": "error", "message": str(exc)})

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


def _coerce_float(value):
    try:
        if isinstance(value, (int, float)):
            return float(value)
        if isinstance(value, str) and value.strip() != "":
            return float(value)
    except Exception:
        return None
    return None


def _extract_lat_lon(obj: Dict[str, Any]):
    if not isinstance(obj, dict):
        return None, None
    cand = obj.get("position") if isinstance(obj.get("position"), dict) else obj
    lat = _coerce_float(cand.get("latitude")) if isinstance(cand, dict) else None
    lon = _coerce_float(cand.get("longitude")) if isinstance(cand, dict) else None
    if lat is None or lon is None:
        return None, None
    if not (-90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0):
        return None, None
    return lat, lon


def _wait_heartbeat_armed(m: "mavutil.mavfile", timeout_s: float = 8.0) -> bool:
    deadline = time.time() + timeout_s
    flag = mavutil.mavlink.MAV_MODE_FLAG_SAFETY_ARMED
    while time.time() < deadline:
        hb = m.recv_match(type='HEARTBEAT', blocking=True, timeout=1)
        if not hb:
            continue
        if getattr(hb, 'base_mode', 0) & flag:
            return True
    return False


def _set_mode_auto(m: "mavutil.mavfile") -> None:
    try:
        # Prefer helper on ArduPilot
        m.set_mode_apm('AUTO')
    except Exception:
        # Fallback: DO_SET_MODE is not consistently supported on AP, so ignore if fails
        pass


def _set_mode_guided(m: "mavutil.mavfile") -> None:
    try:
        m.set_mode_apm('GUIDED')
    except Exception:
        try:
            m.mav.command_long_send(
                m.target_system,
                m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1,
                mavutil.mavlink.MAV_CMD_DO_SET_MODE,
                0,
                mavutil.mavlink.MAV_MODE_GUIDED_ARMED,
                0, 0, 0, 0, 0,
            )
        except Exception:
            pass


def _arm_vehicle(m: "mavutil.mavfile", force: bool = False) -> None:
    m.mav.command_long_send(
        m.target_system,
        m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1,
        mavutil.mavlink.MAV_CMD_COMPONENT_ARM_DISARM,
        0,
        1,  # arm
        21196 if force else 0,  # ArduPilot magic for force arm
        0, 0, 0, 0, 0,
    )


def _mission_start(m: "mavutil.mavfile", first_seq: int = 0, last_seq: int = 0) -> None:
    # ArduPilot honors MAV_CMD_MISSION_START
    m.mav.command_long_send(
        m.target_system,
        m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1,
        mavutil.mavlink.MAV_CMD_MISSION_START,
        0,
        first_seq,
        last_seq,
        0, 0, 0, 0, 0,
    )


def _set_ground_speed(m: "mavutil.mavfile", speed_mps: float) -> None:
    # Best-effort change via DO_CHANGE_SPEED (type=1: groundspeed, param2 speed in m/s)
    try:
        m.mav.command_long_send(
            m.target_system,
            m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1,
            mavutil.mavlink.MAV_CMD_DO_CHANGE_SPEED,
            0,
            1,  # speed type: groundspeed
            float(speed_mps),
            -1, 0, 0, 0, 0,
        )
    except Exception:
        pass


def _guided_takeoff(m: "mavutil.mavfile", alt_m: float) -> None:
    # ArduCopter guided takeoff via command_long
    try:
        m.mav.command_long_send(
            m.target_system,
            m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1,
            mavutil.mavlink.MAV_CMD_NAV_TAKEOFF,
            0,
            0, 0, 0, 0,
            0, 0,
            float(alt_m),
        )
    except Exception:
        pass


def _wait_altitude_reached(m: "mavutil.mavfile", target_alt_m: float, timeout_s: float = 20.0) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        msg = m.recv_match(type=['VFR_HUD', 'GLOBAL_POSITION_INT'], blocking=True, timeout=1)
        if not msg:
            continue
        try:
            if msg.get_type() == 'VFR_HUD' and getattr(msg, 'alt', None) is not None:
                if float(msg.alt) >= target_alt_m * 0.9:
                    return True
            if msg.get_type() == 'GLOBAL_POSITION_INT' and getattr(msg, 'relative_alt', None) is not None:
                if (msg.relative_alt / 1000.0) >= target_alt_m * 0.9:
                    return True
        except Exception:
            continue
    return False


def _mission_set_current(m: "mavutil.mavfile", seq: int) -> None:
    try:
        m.mav.mission_set_current_send(
            m.target_system,
            m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1,
            int(seq),
        )
    except Exception:
        pass
    # Also update ArduCopter parameter WPNAV_SPEED (cm/s)
    try:
        m.mav.param_set_send(
            m.target_system,
            m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1,
            b"WPNAV_SPEED",
            float(max(0.0, speed_mps) * 100.0),  # m/s -> cm/s
            mavutil.mavlink.MAV_PARAM_TYPE_REAL32,
        )
    except Exception:
        pass


def _cmd_name(cmd_id: int) -> str:
    try:
        for k, v in vars(mavutil.mavlink).items():
            if k.startswith('MAV_CMD_') and isinstance(v, int) and v == cmd_id:
                return k
    except Exception:
        pass
    return str(cmd_id)


def _mavlink_reader_loop():
    global drone_latitude, drone_longitude, drone_altitude
    global drone_speed, drone_heading, drone_battery

    if mavutil is None:
        print("pymavlink not installed; telemetry will remain static")
        return

    while True:
        try:
            print(f"[MAVLINK] Connecting {MAVLINK_PORT} @ {MAVLINK_BAUD}...")
            m = mavutil.mavlink_connection(MAVLINK_PORT, baud=MAVLINK_BAUD, force_mavlink2=True)
            m.wait_heartbeat(timeout=10)
            print(f"[MAVLINK] Heartbeat from system {m.target_system} comp {m.target_component}")
            # Expose the connection for other operations (mission upload, etc.)
            globals()["mavlink_master"] = m

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

            last_alive_log = 0.0
            while True:
                # Allow exclusive sections (e.g., mission upload) to pause RX
                if mavlink_rx_pause.is_set():
                    # Auto-unstick safeguard: clear pause if held too long
                    if time.monotonic() - mavlink_pause_since > 10.0:
                        print("[MAVLINK] Pause held >10s; auto-clearing")
                        mavlink_rx_pause.clear()
                    time.sleep(0.05)
                    continue
                msg = m.recv_match(blocking=True, timeout=0.5)
                if not msg:
                    now = time.monotonic()
                    if now - last_alive_log > 5.0:
                        print("[MAVLINK] RX alive (no msg)")
                        last_alive_log = now
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
            try:
                m.close()
            except Exception:
                pass
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

        if is_mission_active:
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
